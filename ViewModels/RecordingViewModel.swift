import Foundation
import Combine
import AVFoundation
import UIKit
import UserNotifications

enum RecordingState {
    case idle
    case active
    case paused
}

@MainActor
final class RecordingViewModel: ObservableObject {
    
    // MARK: - Published
    @Published var recordingState: RecordingState = .idle
    @Published var currentSession: Session?
    @Published var sessions: [Session] = []
    @Published var elapsedTime: TimeInterval = 0
    @Published var clipCount: Int = 0
    @Published var bufferLengthSeconds: Int = 10
    @Published var postRollSeconds: Int = 10
    @Published var shouldNavigateToClips: Bool = false
    @Published var localStoreSize: String = "Calculating…"
    @Published var isProcessingWatermark: Bool = false
    @Published var justFinishedSessionClips: [URL] = []
    @Published var isImportingSecondary: Bool = false
    
    //ADD THIS TOP-LEVEL UI PROPERTY
    @Published var selectedVideoQuality: CameraManager.VideoQuality = .hd1080p
    
    // Variables for highlight extraction progress bar
    @Published var currentExtractionProgress: Int = 0
    @Published var totalExtractionCount: Int = 0
    @Published var isExtractingHighlights: Bool = false
    @Published var showAutomaticImportPrompt: Bool = false
    
    // To delete full recording or not after finishing
    @Published var showStorageChoicePrompt: Bool = false
    private var sessionURLToDeleteLater: URL?
    
    // ADD THIS FUNCTION TO UPDATE BOTH PLACES RESPONSIBLY
    func updateVideoQuality(to newQuality: CameraManager.VideoQuality) {
        self.selectedVideoQuality = newQuality
        self.cameraManager.setVideoQuality(newQuality)
    }
    
    // MARK: - Computed Properties
    var elapsedLabel: String {
        let hours = Int(elapsedTime) / 3600
        let minutes = (Int(elapsedTime) % 3600) / 60
        let seconds = Int(elapsedTime) % 60
        
        if hours > 0 {
            // Formats as H:MM:SS when it hits an hour (e.g., 1:00:01)
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        } else {
            // Keeps your clean format for under an hour (e.g., 05:42)
            return String(format: "%02d:%02d", minutes, seconds)
        }
    }

    
    // MARK: - Services
    
    let cameraManager = CameraManager()
    private let bufferManager = BufferManager()
    private var sessionTimer: AnyCancellable?
    private var sessionStart: Date?
    var cancellables = Set<AnyCancellable>()
    private var pendingFullSessionID: UUID?
    private var pendingHighlightClips: [Clip] = []
    
    // MARK: - Persistence
    
    private var sessionsMetadataURL: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent("sessions.json")
    }
    
    // MARK: - Init
    
    init() {
        // Sync the UI video quality property to the camera hardware setting at boot
        self.selectedVideoQuality = cameraManager.videoQuality
        
        Task { @MainActor [weak self] in
            guard let self = self else { return }
            
            // 1. Fully load data from disk and map filenames onto the active container directory path
            let loaded = await self.performDiskLoadingSequence()
            self.sessions = loaded
            
            // 2. ONLY check file integrity after the correct sandbox prefix is applied
            self.validateLoadedSessions()
            
            // 3. Connect downstream app subscribers and clean processing flags
            self.setupSubscribers()
            self.retryIncompleteHighlightExtractions()
            self.saveSessionsToDisk()
        }
        updateStorageSize()
    }
    
    private func setupSubscribers() {
        cancellables.removeAll()
        
        cameraManager.movieFileReady
            .receive(on: DispatchQueue.main)
            .sink { [weak self] url in
                self?.handleIncomingMovieFile(url: url)
            }
            .store(in: &cancellables)
        
        cameraManager.recordingStarted
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in
                guard let self = self else { return }
                self.sessionStart = Date()
                self.startTimer()
                
                // 🛑 KEEP SCREEN AWAKE: Prevent the screen from dimming/sleeping during active filming
                UIApplication.shared.isIdleTimerDisabled = true
                print("📱 Screen idle timer disabled. Device will stay awake.")
            }
            .store(in: &cancellables)
    }
    
    // MARK: - File Management Pipeline
    
    private func handleIncomingMovieFile(url: URL) {
        guard var session = currentSession else { return }
                
        if self.recordingState == .active {
            self.recordingState = .idle
            self.stopTimer()
            
            // 🔋 RESTORE AUTO-SLEEP if stopped unexpectedly
            UIApplication.shared.isIdleTimerDisabled = false
        }
        
        var backgroundTaskID: UIBackgroundTaskIdentifier = .invalid
        backgroundTaskID = UIApplication.shared.beginBackgroundTask(withName: "ClipIt.SavePipeline") {
            if backgroundTaskID != .invalid {
                UIApplication.shared.endBackgroundTask(backgroundTaskID)
                backgroundTaskID = .invalid
            }
        }
        
        session.fullVideoURL = url
        
        let fullClip = Clip(
            sessionID: session.id,
            offsetInSession: 0,
            fileURL: url,
            duration: session.duration,
            highlightIndex: nil
        )
        
        session.clips = [fullClip] + pendingHighlightClips
        session.isProcessing = true
        
        self.sessions.insert(session, at: 0)
        self.currentSession = nil
        
        let highlightsToProcess = session.highlights
        
        if highlightsToProcess.isEmpty {
            self.finishProcessing(sessionID: session.id, finalClips: session.clips, bgTask: backgroundTaskID)
        } else {
            // 🌟 Set extraction layout progress tracking states
            self.currentExtractionProgress = 0
            self.totalExtractionCount = highlightsToProcess.count
            self.isExtractingHighlights = true
            
            var processedHighlights: [Clip] = []
            
            // ⏱️ Recursive internal worker to process clips sequentially with their individual settings
            func extractNext(index: Int) {
                guard index < highlightsToProcess.count else {
                    // 🌟 Sequential pipeline complete! Clean up state flags and wrap up
                    self.isExtractingHighlights = false
                    let finalClips = [fullClip] + processedHighlights
                    self.finishProcessing(sessionID: session.id, finalClips: finalClips, bgTask: backgroundTaskID)
                    return
                }
                
                let currentClip = highlightsToProcess[index]
                // Fall back to current VM slider parameters if individual settings aren't caught
                let clipBefore = currentClip.beforeSeconds ?? Double(self.bufferLengthSeconds)
                let clipAfter = currentClip.afterSeconds ?? Double(self.postRollSeconds)
                
                ClipExtractor.extractHighlights(
                    from: url,
                    highlights: [currentClip],
                    beforeSeconds: clipBefore,
                    afterSeconds: clipAfter,
                    progress: { _, _ in }, // Individual clip status is managed via item index
                    completion: { singleProcessedArray in
                        Task { @MainActor in
                            processedHighlights.append(contentsOf: singleProcessedArray)
                            // Update progress on MainActor to advance the ClipsView overlay cleanly
                            self.currentExtractionProgress = index + 1
                            extractNext(index: index + 1)
                        }
                    }
                )
            }
            
            // Kick off the extraction train starting at index 0
            extractNext(index: 0)
        }
    }
    
    private func finishProcessing(sessionID: UUID, finalClips: [Clip], bgTask: UIBackgroundTaskIdentifier) {
        if let index = self.sessions.firstIndex(where: { $0.id == sessionID }) {
            self.sessions[index].clips = finalClips
            self.sessions[index].isProcessing = false
        }
        
        self.saveSessionsToDisk()
        self.updateStorageSize()
        
        let highlightURLs = finalClips.compactMap { $0.highlightIndex != nil ? $0.fileURL : nil }
        if !highlightURLs.isEmpty {
            self.justFinishedSessionClips = highlightURLs
        }
        
        if bgTask != .invalid {
            UIApplication.shared.endBackgroundTask(bgTask)
        }
        
        DispatchQueue.main.async {
            // ✅ FIX 1: Replaced unused conditional assignment with a simple boolean type test
            if UIApplication.shared.delegate is NSObject {
                print("🎉 Primary processing complete.")
            }
            
            // ✅ FIX 2: Removed the unused 'hasActivePeers' variable allocation
            
            // 🚀 Gate check: Only toggle true if this device is NOT a remote secondary buffer writer.
            // If your app uses a flag like `isSecondaryCamera`, use that, otherwise check peer status:
            if self.sessions.first(where: { $0.id == sessionID })?.fullVideoURL != nil {
                print("📱 Confirmed: This is the Primary device. Arming import prompt.")
                self.showAutomaticImportPrompt = true
            } else {
                print("📱 Confirmed: This is the Secondary device. Suppressing import prompt.")
                self.showAutomaticImportPrompt = false
            }
        }
    }
    
    // MARK: - Action Interface
    
    func triggerClip() {
        guard recordingState == .active, let session = currentSession else { return }
        
        clipCount += 1
        
        let availablePastBuffer = min(Double(bufferLengthSeconds), elapsedTime)
        let actualDuration = availablePastBuffer + Double(postRollSeconds)
        
        let startTime = max(0, elapsedTime - Double(bufferLengthSeconds))
        let endTime = elapsedTime + Double(postRollSeconds)
        
        let newClip = Clip(
            id: UUID(),
            sessionID: session.id,
            triggeredAt: Date(),
            offsetInSession: elapsedTime,
            duration: actualDuration,
            highlightIndex: clipCount,
            sourceStartTime: startTime,
            sourceEndTime: endTime,
            beforeSeconds: Double(bufferLengthSeconds), // 👈 NEW: Lock snapshot config in permanently!
            afterSeconds: Double(postRollSeconds)       // 👈 NEW: Lock snapshot config in permanently!
        )
        
        pendingHighlightClips.append(newClip)
        currentSession?.clips = pendingHighlightClips
    }
    
    // MARK: - Session Lifecycle
        
        /// Core pipeline responsible for setting up local recording hardware and state containers.
        /// This avoids duplicating resetting logic across Primary and Secondary paths.
        private func beginRecordingSession(session: Session) {
            self.currentSession = session
            self.clipCount = 0
            self.elapsedTime = 0
            self.recordingState = .active
            self.pendingHighlightClips = []
            
            // 🧼 FIX: Clear any leftover highlight URLs from a previous session to start fresh
            self.justFinishedSessionClips = []
            
            bufferManager.bufferSeconds = bufferLengthSeconds
            bufferManager.postRollSeconds = postRollSeconds
            
            bufferManager.startBuffering(mode: .fullSession, cameraManager: cameraManager)
            
            let url = fullSessionURL(for: session)
            pendingFullSessionID = session.id
            cameraManager.startMovieRecording(to: url)
        }
        
        /// Triggered exclusively on the Master/Primary device when hitting the record switch.
        func requestStartSession(multipeerManager: MultipeerManager) {
            // 1. Calculate the next session number sequence (e.g., 1, 2, 3...)
            let currentNumber = nextSessionNumber()
            
            // 2. Initialize your session
            var session = Session(mode: .fullSession)
            
            // 3. ✅ Explicitly set the name so it increments dynamically!
            session.name = "Session \(currentNumber)"
            
            // 🚀 Broadcast the locked session ID to the secondary camera system immediately!
            multipeerManager.sendCommand(.startRecordingWithID(sessionID: session.id))
            
            // Kick off local engine sequence
            beginRecordingSession(session: session)
        }
        
        /// Triggered exclusively on the Follower/Secondary device when receiving the network sync packet.
        func startRecordingRemotely(withID id: UUID) {
            let session = Session(id: id, mode: .fullSession)
            
            // Kick off local engine sequence with the forced matching UUID
            beginRecordingSession(session: session)
        }
        
    func endSession(navigateToClips: Bool = true) {
        guard var session = currentSession else { return }
        session.endedAt = Date()
        session.isProcessing = true
        session.clips = pendingHighlightClips
        
        currentSession = session
        recordingState = .idle
        stopTimer()
        
        cameraManager.stopMovieRecording()
        
        // 🔋 RESTORE AUTO-SLEEP: Allow the phone to sleep normally again
        UIApplication.shared.isIdleTimerDisabled = false
        print("📱 Screen idle timer re-enabled.")
        
        // 🛑 Only switch tabs if we weren't interrupted by a phone call!
//        if navigateToClips {
//            shouldNavigateToClips = true
//        }
    }
        
    func createNewSession(withID id: UUID) {
        let newSession = Session(id: id, mode: .fullSession)
        self.currentSession = newSession
        self.sessions.insert(newSession, at: 0)
    }
    
    func toggleRecording(with multipeerManager: MultipeerManager) {
        if recordingState == .active {
            endSession()
        } else {
            // ✅ FIX: Correctly passes the manager instance to prevent compiler mismatch errors
            requestStartSession(multipeerManager: multipeerManager)
        }
    }
    
    func discardSession() {
        stopTimer()
        cameraManager.stopMovieRecording()
        currentSession = nil
        recordingState = .idle
        
        // 🔋 RESTORE AUTO-SLEEP if session is canceled
        UIApplication.shared.isIdleTimerDisabled = false
    }
    
    // MARK: - Helpers
    
    private func startTimer() {
        sessionTimer = Timer.publish(every: 1.0, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                guard let self = self, let start = self.sessionStart else { return }
                self.elapsedTime = Date().timeIntervalSince(start)
            }
    }
    
    private func stopTimer() {
        sessionTimer?.cancel()
        sessionTimer = nil
    }
    
    func updateStorageSize() {
        Task.detached(priority: .background) { [weak self] in
            let paths = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)
            guard let docsURL = paths.first else { return }
            
            var totalBytes: Int64 = 0
            if let enumerator = FileManager.default.enumerator(at: docsURL, includingPropertiesForKeys: [.fileSizeKey], options: []) {
                while let fileURL = enumerator.nextObject() as? URL {
                    if let resources = try? fileURL.resourceValues(forKeys: [.fileSizeKey]),
                       let fileSize = resources.fileSize {
                        totalBytes += Int64(fileSize)
                    }
                }
            }
            
            let formatter = ByteCountFormatter()
            formatter.allowedUnits = [.useGB, .useMB]
            formatter.countStyle = .file
            let sizeString = formatter.string(fromByteCount: totalBytes)
            
            await MainActor.run { [weak self] in
                self?.localStoreSize = sizeString
            }
        }
    }
    
    private func nextSessionNumber() -> Int { sessions.count + 1 }
    private func fullSessionURL(for session: Session) -> URL {
        let paths = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)
        let documentsDirectory = paths[0]
        let uniqueFilename = "session_\(session.id.uuidString).mov"
        return documentsDirectory.appendingPathComponent(uniqueFilename)
    }
    
    private func saveSessionsToDisk() {
        let sanitizedSessions = self.sessions.map { originalSession -> Session in
            var session = originalSession
            
            if let fullURL = session.fullVideoURL {
                session.fullVideoURL = URL(fileURLWithPath: fullURL.lastPathComponent)
            }
            
            for j in session.clips.indices {
                // Anchor the highlight files
                if let clipURL = session.clips[j].fileURL {
                    session.clips[j].fileURL = URL(fileURLWithPath: clipURL.lastPathComponent)
                }
                
                // Strip absolute path off the Camera 2 Master track!
                if let sourceURL = session.clips[j].sourceVideoURL {
                    session.clips[j].sourceVideoURL = URL(fileURLWithPath: sourceURL.lastPathComponent)
                }
            }
            return session
        }
        
        let url = self.sessionsMetadataURL
        
        Task.detached(priority: .utility) {
            do {
                let data = try JSONEncoder().encode(sanitizedSessions)
                try data.write(to: url, options: .atomic)
                print("💾 Saved \(sanitizedSessions.count) sanitized relative sessions to disk.")
            } catch {
                print("❌ Failed to save sessions metadata: \(error.localizedDescription)")
            }
        }
    }
    
    private func performDiskLoadingSequence() async -> [Session] {
        let url = self.sessionsMetadataURL
        
        return await Task.detached(priority: .userInitiated) {
            guard FileManager.default.fileExists(atPath: url.path) else { return [] }
            do {
                let data = try Data(contentsOf: url)
                var decodedSessions = try JSONDecoder().decode([Session].self, from: data)
                
                let currentDocsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                let clipsDirURL = currentDocsURL.appendingPathComponent("Clips", isDirectory: true)
                
                for i in decodedSessions.indices {
                    // 1. Re-anchor the parent full video URL
                    if let oldFullURL = decodedSessions[i].fullVideoURL {
                        let filename = oldFullURL.lastPathComponent
                        decodedSessions[i].fullVideoURL = currentDocsURL.appendingPathComponent(filename)
                    }
                    
                    // 2. Re-anchor the clips based on their type
                    for j in decodedSessions[i].clips.indices {
                        // 1. Re-anchor the highlight clips
                        if let oldClipURL = decodedSessions[i].clips[j].fileURL {
                            let filename = oldClipURL.lastPathComponent
                            
                            if decodedSessions[i].clips[j].highlightIndex == nil {
                                decodedSessions[i].clips[j].fileURL = currentDocsURL.appendingPathComponent(filename)
                            } else if decodedSessions[i].clips[j].isSecondaryAngle {
                                decodedSessions[i].clips[j].fileURL = currentDocsURL.appendingPathComponent(filename)
                            } else {
                                decodedSessions[i].clips[j].fileURL = clipsDirURL.appendingPathComponent(filename)
                            }
                        }
                        
                        // 🌟 THE FIX: Re-anchor the Camera 2 Master track so AVPlayer can play it and unlock the editor!
                        if let oldSourceURL = decodedSessions[i].clips[j].sourceVideoURL {
                            let filename = oldSourceURL.lastPathComponent
                            decodedSessions[i].clips[j].sourceVideoURL = currentDocsURL.appendingPathComponent(filename)
                        }
                    }
                }
                return decodedSessions
            } catch {
                print("❌ Failed to load sessions metadata: \(error.localizedDescription)")
                return []
            }
        }.value
    }
    
    func deleteSession(id: UUID) {
        guard let index = sessions.firstIndex(where: { $0.id == id }) else { return }
        let session = sessions[index]
        
        sessions.remove(at: index)
        
        Task.detached(priority: .background) {
            if let fullURL = session.fullVideoURL {
                try? FileManager.default.removeItem(at: fullURL)
            }
            for clip in session.clips {
                if let fileURL = clip.fileURL {
                    try? FileManager.default.removeItem(at: fileURL)
                }
            }
        }
        
        saveSessionsToDisk()
        updateStorageSize()
    }
    
    func deleteFullRecording(sessionID: UUID) {
        guard let index = sessions.firstIndex(where: { $0.id == sessionID }) else { return }
        let targetURL = sessions[index].fullVideoURL
        
        sessions[index].fullVideoURL = nil
        sessions[index].clips.removeAll(where: { $0.highlightIndex == nil })
        
        if let url = targetURL {
            Task.detached(priority: .background) {
                try? FileManager.default.removeItem(at: url)
            }
        }
        
        saveSessionsToDisk()
        updateStorageSize()
    }
    
    func deleteSecondaryFullRecording(sessionID: UUID) {
        guard let index = sessions.firstIndex(where: { $0.id == sessionID }) else { return }
        
        // Grab the local file url path from the first secondary clip before clearing it
        let targetURL = sessions[index].clips.first(where: { $0.isSecondaryAngle })?.sourceVideoURL
        
        // Unlink the source video background reference path across all secondary angle items
        for j in sessions[index].clips.indices {
            if sessions[index].clips[j].isSecondaryAngle {
                sessions[index].clips[j].sourceVideoURL = nil
            }
        }
        
        // Safely remove the massive continuous file from disk storage on a background thread
        if let url = targetURL {
            Task.detached(priority: .background) {
                try? FileManager.default.removeItem(at: url)
                print("🗑️ Cleaned up multi-gigabyte secondary master continuous video file.")
            }
        }
        
        // Refresh database tracking configurations
        saveSessionsToDisk()
        updateStorageSize()
        
        self.objectWillChange.send()
    }
    
    func deleteClip(sessionID: UUID, clipID: UUID) {
        guard let sessionIndex = sessions.firstIndex(where: { $0.id == sessionID }),
              let clipIndex = sessions[sessionIndex].clips.firstIndex(where: { $0.id == clipID }) else { return }
        
        let clip = sessions[sessionIndex].clips[clipIndex]
        
        if let url = clip.fileURL {
            try? FileManager.default.removeItem(at: url)
        }
        
        sessions[sessionIndex].clips.remove(at: clipIndex)
        saveSessionsToDisk()
        updateStorageSize()
    }
    
    func renameSession(id: UUID, newName: String) {
        if let index = sessions.firstIndex(where: { $0.id == id }) {
            sessions[index].name = newName
            saveSessionsToDisk()
        }
    }
    
    func updateClip(_ clip: Clip) {
        guard let sessionIndex = sessions.firstIndex(where: { $0.id == clip.sessionID }),
              let clipIndex = sessions[sessionIndex].clips.firstIndex(where: { $0.id == clip.id }) else { return }
        
        var finalizedClip = clip
        
        // 🌟 THE FIX: Force the incoming trimmed clip to remember which camera it belongs to!
        finalizedClip.isSecondaryAngle = sessions[sessionIndex].clips[clipIndex].isSecondaryAngle
        
        sessions[sessionIndex].clips[clipIndex] = finalizedClip
        
        if currentSession?.id == clip.sessionID {
            currentSession = sessions[sessionIndex]
        }
        
        saveSessionsToDisk()
        updateStorageSize()
    }
    
    private func validateLoadedSessions() {
        var needsResave = false
        
        for i in 0..<sessions.count {
            // Check full recording files
            if let fullURL = sessions[i].fullVideoURL {
                if !FileManager.default.fileExists(atPath: fullURL.path) {
                    print("⚠️ File missing for Full Session \(sessions[i].id). Cleared.")
                    sessions[i].fullVideoURL = nil
                    sessions[i].clips.removeAll(where: { $0.highlightIndex == nil })
                    needsResave = true
                }
            }
            
            // Check individual highlight clip files
            for j in (0..<sessions[i].clips.count).reversed() {
                if let url = sessions[i].clips[j].fileURL {
                    let exists = FileManager.default.fileExists(atPath: url.path)
                    
                    if !exists {
                        print("❌ Highlight missing at: \(url.path). Safely removed clip index \(j).")
                        sessions[i].clips.remove(at: j)
                        needsResave = true
                    } else {
                        print("✅ Highlight verified at: \(url.path)")
                    }
                }
            }
        }
        
        if needsResave { saveSessionsToDisk() }
    }
    
    private func retryIncompleteHighlightExtractions() {
        var needsResave = false
        for i in 0..<sessions.count {
            if sessions[i].isProcessing {
                sessions[i].isProcessing = false
                needsResave = true
            }
        }
        if needsResave { saveSessionsToDisk() }
    }
    
    // MARK: - Multipeer Network Actions
    
    /// Ingests a raw highlight file delivered over the local network from a secondary camera
    func attachImportedHighlight(fileURL: URL) {
        guard !sessions.isEmpty else {
            print("❌ No session exists to attach this highlight to.")
            return
        }
        
        let latestSessionIndex = 0
        let sessionID = sessions[latestSessionIndex].id
        
        // Count existing secondary clips to assign it a proper number
        let existingSecondaryCount = sessions[latestSessionIndex].clips.filter { $0.isSecondaryAngle }.count
        let newHighlightIndex = existingSecondaryCount + 1
        
        // 🎯 THE FIX: Steal ALL the exact metadata from the primary camera's matching clip!
        let matchingPrimaryClip = sessions[latestSessionIndex].clips.first { !$0.isSecondaryAngle && $0.highlightIndex == newHighlightIndex }
        
        let correctOffset = matchingPrimaryClip?.offsetInSession ?? 0
        let correctDuration = matchingPrimaryClip?.duration ?? TimeInterval(bufferLengthSeconds + postRollSeconds)
        let correctStartTime = matchingPrimaryClip?.sourceStartTime
        let correctEndTime = matchingPrimaryClip?.sourceEndTime
        let correctTriggerTime = matchingPrimaryClip?.triggeredAt ?? Date()
        
        // 🛠️ FIXED INITIALIZATION TO EXACTLY MATCH THE STRUCT MEMBERWISE INIT USED IN TRIGGERCLIP()
        let newClip = Clip(
            id: UUID(),
            sessionID: sessionID,
            triggeredAt: correctTriggerTime,
            offsetInSession: correctOffset,
            duration: correctDuration, // 👈 Perfectly matches the primary clip now!
            highlightIndex: newHighlightIndex,
            sourceStartTime: correctStartTime,
            sourceEndTime: correctEndTime,
            beforeSeconds: Double(bufferLengthSeconds),
            afterSeconds: Double(postRollSeconds)
        )
        
        // Ensure properties not in the designated initializer but needed for your secondary workflow are assigned afterwards
        var updatedClip = newClip
        updatedClip.fileURL = fileURL
        updatedClip.isSecondaryAngle = true
        updatedClip.isUploaded = false
        
        sessions[latestSessionIndex].clips.append(updatedClip)
        
        if currentSession?.id == sessionID {
            currentSession?.clips.append(updatedClip)
        }
        
        saveSessionsToDisk()
        updateStorageSize()
        print("✅ Successfully ingested secondary camera highlight #\(newHighlightIndex) with exact duration of \(correctDuration)s!")
    }
    
    /// 📡 PHASE 2 (Follower/Secondary Role): Serves the continuous master video recording
    /// if the primary coaching phone requests it for trimming.
    func configureSecondaryVideoProvider(with multipeerManager: MultipeerManager) {
        multipeerManager.onFullVideoRequested = { [weak self] in
            guard let self = self else { return nil }
            // Grabs the full continuous master recording path of the most recent session
            return self.sessions.first?.fullVideoURL
        }
    }
    
    /// 📡 PHASE 4 (Master/Primary Role): Ingests the complete full-length master video file
    /// from the secondary camera and pairs it to the highlights to unlock editing.
    /// 📡 PHASE 4 (Master/Primary Role): Ingests the complete full-length master video file
    /// from the secondary camera and pairs it to the highlights to unlock editing.
    func attachImportedFullSecondaryVideo(fileURL: URL, targetSessionID: UUID? = nil) {
        guard !sessions.isEmpty else {
            print("❌ No session exists to attach this master recording to.")
            return
        }
        
        // 🌟 FIX: Find the exact session index matching the ID, or fallback to the newest (0)
        let targetIndex: Int
        if let targetID = targetSessionID, let foundIndex = sessions.firstIndex(where: { $0.id == targetID }) {
            targetIndex = foundIndex
        } else {
            targetIndex = 0 // Fallback
        }
        
        let sessionID = sessions[targetIndex].id
        
        // Loop through all clips in the target session and update the secondary views
        for index in sessions[targetIndex].clips.indices {
            if sessions[targetIndex].clips[index].isSecondaryAngle {
                // 🔗 Link the clip's source editing track to this new local mirror file!
                sessions[targetIndex].clips[index].sourceVideoURL = fileURL
            }
        }
        
        // Keep your active running session layout state synchronized if it's currently open
        if currentSession?.id == sessionID {
            currentSession = sessions[targetIndex]
        }
        
        // Commit changes permanently to sessions.json metadata database container
        saveSessionsToDisk()
        updateStorageSize()
        print("💾 Success! Linked full secondary master video track to all secondary views in session \(sessionID).")
    }
    
    func attachSecondaryMasterVideo(fileURL: URL, targetSessionID: UUID? = nil) {
        guard !sessions.isEmpty else {
            print("❌ No active session found to attach the secondary master video to.")
            return
        }
        
        // 🌟 FIX: Find the exact session matching the ID, or fallback to the newest session
        let targetIndex: Int
        if let targetID = targetSessionID, let foundIndex = sessions.firstIndex(where: { $0.id == targetID }) {
            targetIndex = foundIndex
        } else {
            targetIndex = 0 // Fallback
        }
        
        let targetSession = sessions[targetIndex]
        
        // 🌟 Dynamically grab the real file extension from the incoming network transfer
        let ext = fileURL.pathExtension.isEmpty ? "mov" : fileURL.pathExtension
        
        let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let destinationURL = documentsURL.appendingPathComponent("secondary_master_\(targetSession.id.uuidString).\(ext)")
        
        do {
            // Clean up old file if it exists from a previous failed transfer attempt
            if FileManager.default.fileExists(atPath: destinationURL.path) {
                try FileManager.default.removeItem(at: destinationURL)
            }
            
            // Move the file out of the multipeer temp sandbox into your permanent session storage
            try FileManager.default.moveItem(at: fileURL, to: destinationURL)
            
            // Update your data model array on the Main Thread
            self.sessions[targetIndex].clips = self.sessions[targetIndex].clips.map { clip in
                if clip.isSecondaryAngle {
                    var updatedClip = clip
                    // 🔗 Link the background source editing track to this new local mirror file!
                    updatedClip.sourceVideoURL = destinationURL // 🌟 Unlocks the slider/trim editor tracking track!
                    return updatedClip
                }
                return clip
            }
            
            // Keep your active running session layout state synchronized if it's currently open
            if currentSession?.id == targetSession.id {
                currentSession = self.sessions[targetIndex]
            }
            
            // Commit changes permanently to sessions.json metadata database container
            self.saveSessionsToDisk()
            self.updateStorageSize()
            
            // Trigger an object update to redraw the SwiftUI lists instantly
            self.objectWillChange.send()
            print("🎉 Successfully bound secondary master video path to older session (\(targetSession.id)) clips: \(destinationURL.lastPathComponent)")
            
        } catch {
            print("❌ Failed to save and bind incoming master video asset: \(error)")
        }
    }
}
