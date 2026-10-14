//
//  RecordingViewModel.swift
//  Clipit
//

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

enum RecoveredClipResult {
    case saved
    case retryLater
    case noRecording
}

@MainActor
final class RecordingViewModel: ObservableObject {
    
    // MARK: - Published
    @Published var recordingState: RecordingState = .idle
    @Published private(set) var cameraConfirmedRecording = false
    @Published var currentSession: Session?
    @Published var sessions: [Session] = []
    @Published private(set) var hasLoadedSessions = false
    @Published var elapsedTime: TimeInterval = 0
    @Published private(set) var retentionClock = Date()
    @Published var clipCount: Int = 0
    @Published var bufferLengthSeconds: Int = 10
    @Published var postRollSeconds: Int = 0
    @Published var shouldNavigateToClips: Bool = false
    @Published var localStoreSize: String = "Calculating…"
    @Published var isProcessingWatermark: Bool = false
    @Published private(set) var latestTriggeredClip: Clip?
    
    @Published var selectedVideoQuality: CameraManager.VideoQuality = .hd1080p
    
    // Variables for highlight extraction progress bar
    @Published var currentExtractionProgress: Int = 0
    @Published var totalExtractionCount: Int = 0
    @Published var isExtractingHighlights: Bool = false
    
    @Published var showCallEndedOverlay: Bool = false
    
    @Published var pendingHighlightToOpen: Clip?
    
    func updateVideoQuality(to newQuality: CameraManager.VideoQuality) {
        self.selectedVideoQuality = newQuality
        self.cameraManager.setVideoQuality(newQuality)
    }
    
    // MARK: - Computed Properties
    var elapsedLabel: String {
        let minutes = Int(elapsedTime) / 60
        let seconds = Int(elapsedTime) % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }

    // MARK: - Services
    
    let cameraManager = CameraManager()
    private let bufferManager = BufferManager()
    private var sessionTimer: AnyCancellable?
    private var originalVideoRetentionTimer: AnyCancellable?
    private var sessionStart: Date?
    var cancellables = Set<AnyCancellable>()
    private var pendingFullSessionID: UUID?
    private var pendingHighlightClips: [Clip] = []
    private var recoveredExtractionSessions = Set<UUID>()
    private let metadataWriteQueue = DispatchQueue(label: "com.clipit.sessions-metadata-write")
    
    // MARK: - Persistence
    
    private var sessionsMetadataURL: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent("sessions.json")
    }
    
    // MARK: - Init
    
    init() {
        self.selectedVideoQuality = cameraManager.videoQuality
        
        Task { @MainActor [weak self] in
            guard let self = self else { return }
            
            let loaded = await self.performDiskLoadingSequence()
            self.sessions = loaded
            self.hasLoadedSessions = true
            
            self.validateLoadedSessions()
            self.applyOriginalVideoRetention(days: UserDefaults.standard.integer(forKey: "originalVideoRetentionDays"))
            self.refreshOriginalVideoDeletionReminders()
            
            self.setupSubscribers()
            self.retryIncompleteHighlightExtractions()
            self.saveSessionsToDisk()
        }
        updateStorageSize()
    }
    
    private func setupSubscribers() {
        cancellables.removeAll()

        cameraManager.$videoQuality
            .receive(on: DispatchQueue.main)
            .sink { [weak self] quality in
                self?.selectedVideoQuality = quality
            }
            .store(in: &cancellables)
        
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
                guard self.recordingState == .active else { return }
                self.cameraConfirmedRecording = true
                self.sessionStart = Date()
                self.currentSession?.videoStartedAt = self.sessionStart
                self.startTimer()
            }
            .store(in: &cancellables)
            
        // 🌟 FIX: Hardware interruption listener.
        // Triggers ONLY when hardware resources are actually revoked (i.e. user ACCEPTED a call).
        NotificationCenter.default.publisher(for: .AVCaptureSessionWasInterrupted)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] notification in
                self?.handleCameraInterruption(notification)
            }
            .store(in: &cancellables)

        originalVideoRetentionTimer?.cancel()
        originalVideoRetentionTimer = Timer.publish(every: 60, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                let days = UserDefaults.standard.integer(forKey: "originalVideoRetentionDays")
                self?.retentionClock = Date()
                self?.applyOriginalVideoRetention(days: days)
            }
    }
    
    private func handleCameraInterruption(_ notification: Notification) {
        guard currentSession != nil else { return }
        
        guard let userInfo = notification.userInfo,
              let reasonValue = userInfo[AVCaptureSessionInterruptionReasonKey] as? Int,
              let reason = AVCaptureSession.InterruptionReason(rawValue: reasonValue) else {
            return
        }
        
        print("🎥 AVCaptureSession interrupted. Reason code: \(reason.rawValue)")
        
        switch reason {
        case .videoDeviceInUseByAnotherClient, .audioDeviceInUseByAnotherClient:
            print("📞 Phone call ACCEPTED (hardware revoked). Safely ending recording session...")
            if recordingState == .active {
                endSession(navigateToClips: false)
            }
            showCallEndedOverlay = true
            
        case .videoDeviceNotAvailableInBackground:
            guard recordingState == .active else { return }
            print("📱 App backgrounded during active recording. Safely ending recording session...")
            endSession(navigateToClips: false)
            
        default:
            break
        }
    }
    // MARK: - File Management Pipeline
    
    private func handleIncomingMovieFile(url: URL) {
        guard var session = currentSession else { return }
        cameraConfirmedRecording = false
        
        if self.recordingState == .active {
            self.recordingState = .idle
            self.stopTimer()
            RecordingOrientationController.unlock()
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
        self.saveSessionsToDisk()
        
        let highlightsToProcess = session.highlights
        let initialHighlightIDs = Set(highlightsToProcess.map(\.id))
        
        if highlightsToProcess.isEmpty {
            self.finishProcessing(sessionID: session.id, finalClips: session.clips, bgTask: backgroundTaskID)
        } else {
            self.currentExtractionProgress = 0
            self.totalExtractionCount = highlightsToProcess.count
            self.isExtractingHighlights = true
            
            var processedHighlights: [Clip] = []
            
            func extractNext(index: Int) {
                guard index < highlightsToProcess.count else {
                    self.isExtractingHighlights = false
                    let finalClips = [fullClip] + processedHighlights
                    self.finishProcessing(sessionID: session.id, finalClips: finalClips, bgTask: backgroundTaskID)
                    return
                }
                
                let currentClip = highlightsToProcess[index]
                let clipBefore = currentClip.beforeSeconds ?? Double(self.bufferLengthSeconds)
                let clipAfter = currentClip.afterSeconds ?? Double(self.postRollSeconds)
                
                ClipExtractor.extractHighlights(
                    from: url,
                    highlights: [currentClip],
                    beforeSeconds: clipBefore,
                    afterSeconds: clipAfter,
                    progress: { _, _ in },
                    completion: { singleProcessedArray in
                        Task { @MainActor in
                            processedHighlights.append(contentsOf: singleProcessedArray)
                            
                            if let sessionIndex = self.sessions.firstIndex(where: { $0.id == session.id }) {
                                let recovered = self.sessions[sessionIndex].clips.filter {
                                    $0.highlightIndex != nil && !initialHighlightIDs.contains($0.id)
                                }
                                self.sessions[sessionIndex].clips = [fullClip] + processedHighlights + recovered
                            }
                            
                            self.currentExtractionProgress = index + 1
                            self.objectWillChange.send()
                            extractNext(index: index + 1)
                        }
                    }
                )
            }
            
            extractNext(index: 0)
        }
    }
    
    private func finishProcessing(sessionID: UUID, finalClips: [Clip], bgTask: UIBackgroundTaskIdentifier) {
        if let index = self.sessions.firstIndex(where: { $0.id == sessionID }) {
            // A button can reconnect while the ordinary highlights are still
            // exporting. Don't overwrite markers added during that interval.
            let processedIDs = Set(finalClips.map(\.id))
            let recovered = self.sessions[index].clips.filter {
                $0.highlightIndex != nil && !processedIDs.contains($0.id)
            }
            self.sessions[index].clips = finalClips + recovered
            self.sessions[index].isProcessing = false
        }
        
        self.saveSessionsToDisk()
        self.updateStorageSize()
        self.refreshOriginalVideoDeletionReminders()
        self.extractRecoveredHighlights(sessionID: sessionID)
        
        if bgTask != .invalid {
            UIApplication.shared.endBackgroundTask(bgTask)
        }
        
    }
    
    // MARK: - Action Interface
    
    func triggerClip() {
        _ = triggerClip(at: Date())
    }

    /// A transient gap while restoring the library or finishing a movie must
    /// not make the phone permanently reject a buffered button tap.
    func registerRecoveredButtonClip(at pressedAt: Date) -> RecoveredClipResult {
        guard hasLoadedSessions else { return .retryLater }
        if triggerClip(at: pressedAt) { return .saved }

        let matches: (Session) -> Bool = { session in
            let start = session.videoStartedAt ?? session.startedAt
            return pressedAt >= start.addingTimeInterval(-0.5) &&
                pressedAt <= (session.endedAt ?? Date()).addingTimeInterval(0.5)
        }
        if let currentSession, matches(currentSession) {
            return .retryLater
        }
        if sessions.contains(where: { matches($0) && $0.isProcessing }) {
            return .retryLater
        }
        return .noRecording
    }

    /// Place a button tap at its original time, including after the recording
    /// has ended. Returns false if there is no retained video for that time.
    @discardableResult
    func triggerClip(at pressedAt: Date) -> Bool {
        let now = Date()
        guard pressedAt <= now.addingTimeInterval(0.5),
              pressedAt >= now.addingTimeInterval(-48 * 60 * 60) else { return false }

        if let session = currentSession,
           let start = session.videoStartedAt ?? sessionStart,
           pressedAt >= start.addingTimeInterval(-0.5),
           pressedAt <= (session.endedAt ?? now).addingTimeInterval(0.5),
           (recordingState == .active ? cameraConfirmedRecording : session.endedAt != nil) {
            let offset = max(0, pressedAt.timeIntervalSince(start))
            let nextIndex = (pendingHighlightClips.compactMap(\.highlightIndex).max() ?? 0) + 1
            let clip = makeHighlight(sessionID: session.id, at: pressedAt,
                                     offset: offset, index: nextIndex)
            pendingHighlightClips.append(clip)
            currentSession?.clips = pendingHighlightClips
            if recordingState == .active {
                clipCount = nextIndex
                latestTriggeredClip = clip
            }
            return true
        }

        guard let index = sessions.firstIndex(where: { session in
            let start = session.videoStartedAt ?? session.startedAt
            return pressedAt >= start.addingTimeInterval(-0.5) &&
                pressedAt <= (session.endedAt ?? start).addingTimeInterval(0.5)
        }), let source = sessions[index].fullVideoURL,
              FileManager.default.fileExists(atPath: source.path) else { return false }

        let session = sessions[index]
        let start = session.videoStartedAt ?? session.startedAt
        let nextIndex = (session.clips.compactMap(\.highlightIndex).max() ?? 0) + 1
        let clip = makeHighlight(sessionID: session.id, at: pressedAt,
                                 offset: max(0, pressedAt.timeIntervalSince(start)),
                                 index: nextIndex)
        sessions[index].clips.append(clip)
        saveSessionsToDisk()
        if !session.isProcessing { extractRecoveredHighlights(sessionID: session.id) }
        return true
    }

    private func makeHighlight(sessionID: UUID, at date: Date,
                               offset: TimeInterval, index: Int) -> Clip {
        let before = Double(bufferLengthSeconds)
        let after = Double(postRollSeconds)
        return Clip(sessionID: sessionID, triggeredAt: date,
                    offsetInSession: offset,
                    duration: min(before, offset) + after,
                    highlightIndex: index,
                    sourceStartTime: max(0, offset - before),
                    sourceEndTime: offset + after,
                    beforeSeconds: before, afterSeconds: after)
    }

    private func extractRecoveredHighlights(sessionID: UUID) {
        guard !recoveredExtractionSessions.contains(sessionID),
              let session = sessions.first(where: { $0.id == sessionID }),
              !session.isProcessing,
              let source = session.fullVideoURL,
              FileManager.default.fileExists(atPath: source.path),
              let clip = session.clips.first(where: {
                  $0.highlightIndex != nil && $0.fileURL == nil
              }) else { return }

        recoveredExtractionSessions.insert(sessionID)
        ClipExtractor.extractHighlights(
            from: source, highlights: [clip],
            beforeSeconds: clip.beforeSeconds ?? Double(bufferLengthSeconds),
            afterSeconds: clip.afterSeconds ?? Double(postRollSeconds),
            progress: { _, _ in },
            completion: { [weak self] extracted in
                guard let self else { return }
                self.recoveredExtractionSessions.remove(sessionID)
                guard let result = extracted.first, result.fileURL != nil,
                      let sessionIndex = self.sessions.firstIndex(where: { $0.id == sessionID }),
                      let clipIndex = self.sessions[sessionIndex].clips.firstIndex(where: {
                          $0.id == clip.id
                      }) else { return }
                self.sessions[sessionIndex].clips[clipIndex] = result
                self.saveSessionsToDisk()
                self.updateStorageSize()
                self.extractRecoveredHighlights(sessionID: sessionID)
            }
        )
    }

    func favoriteLatestTriggeredClip() {
        guard let latest = latestTriggeredClip,
              let pendingIndex = pendingHighlightClips.firstIndex(where: { $0.id == latest.id }) else { return }

        pendingHighlightClips[pendingIndex].isFavorite = true
        latestTriggeredClip = pendingHighlightClips[pendingIndex]
        currentSession?.clips = pendingHighlightClips

        if let sessionIndex = sessions.firstIndex(where: { $0.id == latest.sessionID }),
           let clipIndex = sessions[sessionIndex].clips.firstIndex(where: { $0.id == latest.id }) {
            sessions[sessionIndex].clips[clipIndex].isFavorite = true
        }
        saveSessionsToDisk()
    }
    
    // MARK: - Session Lifecycle
        
    private func beginRecordingSession(session: Session) {
        RecordingOrientationController.lockToCurrentInterfaceOrientation()
        var session = session
        scheduleOriginalVideoDeletionIfNeeded(for: &session)
        self.shouldNavigateToClips = false
        self.currentSession = session
        self.clipCount = 0
        self.elapsedTime = 0
        self.cameraConfirmedRecording = false
        self.recordingState = .active
        self.pendingHighlightClips = []
        
        bufferManager.bufferSeconds = bufferLengthSeconds
        bufferManager.postRollSeconds = postRollSeconds
        
        bufferManager.startBuffering(mode: .fullSession, cameraManager: cameraManager)
        
        let url = fullSessionURL(for: session)
        pendingFullSessionID = session.id
        cameraManager.startMovieRecording(to: url)
    }

    private func scheduleOriginalVideoDeletionIfNeeded(for session: inout Session) {
        let days = UserDefaults.standard.integer(forKey: "originalVideoRetentionDays")
        guard days > 0,
              !session.originalVideoAutoDeleteDisabled,
              session.originalVideoDeletionDate == nil else { return }
        session.originalVideoDeletionDate = Date().addingTimeInterval(Double(days) * 24 * 60 * 60)
    }

    func disableOriginalVideoAutoDelete(sessionID: UUID) {
        if let index = sessions.firstIndex(where: { $0.id == sessionID }) {
            sessions[index].originalVideoAutoDeleteDisabled = true
            sessions[index].originalVideoDeletionDate = nil
        }
        if currentSession?.id == sessionID {
            currentSession?.originalVideoAutoDeleteDisabled = true
            currentSession?.originalVideoDeletionDate = nil
        }
        retentionClock = Date()
        saveSessionsToDisk()
        refreshOriginalVideoDeletionReminders()
    }
    
    func requestStartSession() {
        var session = Session(mode: .fullSession)
        session.name = Date().defaultSessionName
        
        beginRecordingSession(session: session)
    }
    
    func endSession(navigateToClips: Bool = false) {
        guard var session = currentSession else { return }
        session.endedAt = Date()
        session.isProcessing = true
        session.clips = pendingHighlightClips
        
        currentSession = session
        cameraConfirmedRecording = false
        recordingState = .idle
        RecordingOrientationController.unlock()
        stopTimer()
        
        cameraManager.stopMovieRecording()
        
        if navigateToClips {
            shouldNavigateToClips = true
        }
    }
    
    
    func discardSession() {
        stopTimer()
        cameraManager.stopMovieRecording()
        currentSession = nil
        cameraConfirmedRecording = false
        pendingFullSessionID = nil
        pendingHighlightClips.removeAll()
        latestTriggeredClip = nil
        recordingState = .idle
        RecordingOrientationController.unlock()
        shouldNavigateToClips = false
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
    
    private func fullSessionURL(for session: Session) -> URL {
        let paths = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)
        let documentsDirectory = paths[0]
        let uniqueFilename = "session_\(session.id.uuidString).mov"
        return documentsDirectory.appendingPathComponent(uniqueFilename)
    }
    
    func saveSessionsToDisk() {
        let url = self.sessionsMetadataURL
        let sessionsToSave = self.sessions
        
        // Calls originate on the main actor. A serial queue preserves that
        // ordering; detached writes could finish out of order and restore an
        // older library snapshot over newly recovered clip markers.
        metadataWriteQueue.async {
            do {
                let data = try JSONEncoder().encode(sessionsToSave)
                try data.write(to: url, options: .atomic)
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
                let decodedSessions = try JSONDecoder().decode([Session].self, from: data)
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
        refreshOriginalVideoDeletionReminders()
    }
    
    func deleteFullRecording(sessionID: UUID) {
        guard let index = sessions.firstIndex(where: { $0.id == sessionID }) else { return }
        let targetURL = sessions[index].fullVideoURL
        
        sessions[index].fullVideoURL = nil
        sessions[index].clips.removeAll(where: { $0.highlightIndex == nil })

        let removedEmptySession = removeEmptySessions()
        if !removedEmptySession, currentSession?.id == sessionID {
            currentSession = sessions.first(where: { $0.id == sessionID })
        }
        
        if let url = targetURL {
            Task.detached(priority: .background) {
                try? FileManager.default.removeItem(at: url)
            }
        }
        
        saveSessionsToDisk()
        updateStorageSize()
        refreshOriginalVideoDeletionReminders()
    }
    
    func deleteSecondaryFullRecording(sessionID: UUID) {
        guard let index = sessions.firstIndex(where: { $0.id == sessionID }) else { return }
        
        let targetURL = sessions[index].clips.first(where: { $0.isSecondaryAngle })?.sourceVideoURL
        
        for j in sessions[index].clips.indices {
            if sessions[index].clips[j].isSecondaryAngle {
                sessions[index].clips[j].sourceVideoURL = nil
            }
        }
        
        if let url = targetURL {
            Task.detached(priority: .background) {
                try? FileManager.default.removeItem(at: url)
            }
        }
        
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
        let removedEmptySession = removeEmptySessions()
        if !removedEmptySession, currentSession?.id == sessionID {
            currentSession = sessions.first(where: { $0.id == sessionID })
        }
        saveSessionsToDisk()
        updateStorageSize()
    }
    
    func renameSession(id: UUID, newName: String) {
        if let index = sessions.firstIndex(where: { $0.id == id }) {
            sessions[index].name = newName
            saveSessionsToDisk()
            refreshOriginalVideoDeletionReminders()
        }
    }
    
    func updateClip(_ clip: Clip) {
        guard let sessionIndex = sessions.firstIndex(where: { $0.id == clip.sessionID }) else { return }
        
        if let clipIndex = sessions[sessionIndex].clips.firstIndex(where: { $0.id == clip.id }) {
            var finalizedClip = clip
            finalizedClip.isSecondaryAngle = sessions[sessionIndex].clips[clipIndex].isSecondaryAngle
            sessions[sessionIndex].clips[clipIndex] = finalizedClip
            
            if clip.highlightIndex == nil {
                sessions[sessionIndex].fullVideoURL = clip.fileURL
            }
        } else {
            var newClip = clip
            let existingHighlightNumbers = sessions[sessionIndex].clips.compactMap { $0.highlightIndex }
            let nextHighlightIndex = (existingHighlightNumbers.max() ?? 0) + 1
            newClip.highlightIndex = nextHighlightIndex
            sessions[sessionIndex].clips.append(newClip)
        }
        
        if currentSession?.id == clip.sessionID {
            currentSession = sessions[sessionIndex]
        }
        
        saveSessionsToDisk()
        updateStorageSize()
    }
    
    private func validateLoadedSessions() {
        var needsResave = false
        
        for i in 0..<sessions.count {
            if let fullURL = sessions[i].fullVideoURL {
                if !FileManager.default.fileExists(atPath: fullURL.path) {
                    sessions[i].fullVideoURL = nil
                    sessions[i].clips.removeAll(where: { $0.highlightIndex == nil })
                    needsResave = true
                }
            }
            
            for j in (0..<sessions[i].clips.count).reversed() {
                if let url = sessions[i].clips[j].fileURL {
                    let exists = FileManager.default.fileExists(atPath: url.path)
                    if !exists {
                        sessions[i].clips.remove(at: j)
                        needsResave = true
                    }
                }
            }
        }

        if removeEmptySessions() {
            needsResave = true
        }
        
        if needsResave { saveSessionsToDisk() }
    }

    @discardableResult
    private func removeEmptySessions() -> Bool {
        let emptySessionIDs = Set(sessions.filter { $0.clips.isEmpty }.map { $0.id })
        guard !emptySessionIDs.isEmpty else { return false }

        sessions.removeAll { emptySessionIDs.contains($0.id) }
        if let currentSession, emptySessionIDs.contains(currentSession.id) {
            self.currentSession = nil
        }
        return true
    }

    func applyOriginalVideoRetention(days: Int) {
        if days == 0 {
            var needsResave = false
            for index in sessions.indices where sessions[index].originalVideoDeletionDate != nil {
                sessions[index].originalVideoDeletionDate = nil
                needsResave = true
            }
            if currentSession?.originalVideoDeletionDate != nil {
                currentSession?.originalVideoDeletionDate = nil
            }
            if removeEmptySessions() {
                needsResave = true
            }
            if needsResave {
                saveSessionsToDisk()
                updateStorageSize()
            }
            refreshOriginalVideoDeletionReminders()
            return
        }

        let now = Date()
        let newDeletionDate = now.addingTimeInterval(Double(days) * 24 * 60 * 60)
        var deletedURLs: [URL] = []
        var needsResave = false

        for index in sessions.indices {
            guard sessions[index].fullVideoURL != nil else { continue }

            if !sessions[index].originalVideoAutoDeleteDisabled,
               sessions[index].originalVideoDeletionDate == nil {
                sessions[index].originalVideoDeletionDate = newDeletionDate
                needsResave = true
            }

            if let deletionDate = sessions[index].originalVideoDeletionDate,
               deletionDate <= now,
               let url = sessions[index].fullVideoURL {
                deletedURLs.append(url)
                sessions[index].fullVideoURL = nil
                sessions[index].originalVideoDeletionDate = nil
                sessions[index].clips.removeAll { $0.highlightIndex == nil && !$0.isSecondaryAngle }
                needsResave = true
            }
        }

        if removeEmptySessions() {
            needsResave = true
        }

        if !deletedURLs.isEmpty {
            Task.detached(priority: .background) {
                for url in deletedURLs { try? FileManager.default.removeItem(at: url) }
            }
        }
        if needsResave {
            saveSessionsToDisk()
            updateStorageSize()
            refreshOriginalVideoDeletionReminders()
        }
    }

    func refreshOriginalVideoDeletionReminders() {
        let enabled = NotificationManager.shared.notificationsEnabled
        let sessionsToSync = sessions
        Task {
            await NotificationManager.shared.syncOriginalVideoDeletionReminders(
                sessions: sessionsToSync,
                enabled: enabled
            )
        }
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
        for session in sessions where !session.isProcessing {
            extractRecoveredHighlights(sessionID: session.id)
        }
    }
    

}

// MARK: - Session Naming Helper

extension Date {
    var defaultSessionName: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "h:mm a"
        let timeString = formatter.string(from: self).lowercased()
        return "New Recording - \(timeString)"
    }
}
