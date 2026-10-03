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

@MainActor
final class RecordingViewModel: ObservableObject {
    
    // MARK: - Published
    @Published var recordingState: RecordingState = .idle
    @Published var currentSession: Session?
    @Published var sessions: [Session] = []
    @Published var elapsedTime: TimeInterval = 0
    @Published private(set) var retentionClock = Date()
    @Published var clipCount: Int = 0
    @Published var bufferLengthSeconds: Int = 10
    @Published var postRollSeconds: Int = 0
    @Published var shouldNavigateToClips: Bool = false
    @Published var localStoreSize: String = "Calculating…"
    @Published var isProcessingWatermark: Bool = false
    @Published var justFinishedSessionClips: [URL] = []
    @Published var isImportingSecondary: Bool = false
    @Published private(set) var latestTriggeredClip: Clip?
    
    @Published var selectedVideoQuality: CameraManager.VideoQuality = .hd1080p
    
    // Variables for highlight extraction progress bar
    @Published var currentExtractionProgress: Int = 0
    @Published var totalExtractionCount: Int = 0
    @Published var isExtractingHighlights: Bool = false
    @Published var showAutomaticImportPrompt: Bool = false
    
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
            
            self.validateLoadedSessions()
            self.applyOriginalVideoRetention(days: UserDefaults.standard.integer(forKey: "originalVideoRetentionDays"))
            
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
        
        let highlightsToProcess = session.highlights
        
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
                                self.sessions[sessionIndex].clips = [fullClip] + processedHighlights
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
            if self.sessions.first(where: { $0.id == sessionID })?.fullVideoURL != nil {
                self.showAutomaticImportPrompt = true
            } else {
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
            beforeSeconds: Double(bufferLengthSeconds),
            afterSeconds: Double(postRollSeconds)
        )
        
        pendingHighlightClips.append(newClip)
        latestTriggeredClip = newClip
        currentSession?.clips = pendingHighlightClips
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
        self.recordingState = .active
        self.pendingHighlightClips = []
        
        self.justFinishedSessionClips = []
        
        bufferManager.bufferSeconds = bufferLengthSeconds
        bufferManager.postRollSeconds = postRollSeconds
        
        bufferManager.startBuffering(mode: .fullSession, cameraManager: cameraManager)
        
        let url = fullSessionURL(for: session)
        pendingFullSessionID = session.id
        cameraManager.startMovieRecording(to: url)
    }

    private func scheduleOriginalVideoDeletionIfNeeded(for session: inout Session) {
        let days = UserDefaults.standard.integer(forKey: "originalVideoRetentionDays")
        guard days > 0, session.originalVideoDeletionDate == nil else { return }
        session.originalVideoDeletionDate = Date().addingTimeInterval(Double(days) * 24 * 60 * 60)
    }
    
    func requestStartSession(multipeerManager: MultipeerManager) {
        var session = Session(mode: .fullSession)
        session.name = Date().defaultSessionName
        
        multipeerManager.sendCommand(.startRecordingWithID(sessionID: session.id))
        beginRecordingSession(session: session)
    }
    
    func startRecordingRemotely(withID id: UUID) {
        var session = Session(id: id, mode: .fullSession)
        session.name = Date().defaultSessionName
        beginRecordingSession(session: session)
    }
    
    func endSession(navigateToClips: Bool = false) {
        guard var session = currentSession else { return }
        session.endedAt = Date()
        session.isProcessing = true
        session.clips = pendingHighlightClips
        
        currentSession = session
        recordingState = .idle
        RecordingOrientationController.unlock()
        stopTimer()
        
        cameraManager.stopMovieRecording()
        
        if navigateToClips {
            shouldNavigateToClips = true
        }
    }
    
    func createNewSession(withID id: UUID) {
        var newSession = Session(id: id, mode: .fullSession)
        newSession.name = Date().defaultSessionName
        self.currentSession = newSession
        self.sessions.insert(newSession, at: 0)
    }
    
    func toggleRecording(with multipeerManager: MultipeerManager) {
        if recordingState == .active {
            endSession(navigateToClips: false)
        } else {
            requestStartSession(multipeerManager: multipeerManager)
        }
    }
    
    func discardSession() {
        stopTimer()
        cameraManager.stopMovieRecording()
        currentSession = nil
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
        
        Task.detached(priority: .utility) {
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
            return
        }

        let now = Date()
        let newDeletionDate = now.addingTimeInterval(Double(days) * 24 * 60 * 60)
        var deletedURLs: [URL] = []
        var needsResave = false

        for index in sessions.indices {
            guard sessions[index].fullVideoURL != nil else { continue }

            if sessions[index].originalVideoDeletionDate == nil {
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
    }
    
    // MARK: - Multipeer Network Actions
    
    func attachImportedHighlight(fileURL: URL) {
        guard !sessions.isEmpty else { return }
        
        let latestSessionIndex = 0
        let sessionID = sessions[latestSessionIndex].id
        let existingSecondaryCount = sessions[latestSessionIndex].clips.filter { $0.isSecondaryAngle }.count
        let newHighlightIndex = existingSecondaryCount + 1
        
        let matchingPrimaryClip = sessions[latestSessionIndex].clips.first { !$0.isSecondaryAngle && $0.highlightIndex == newHighlightIndex }
        
        let correctOffset = matchingPrimaryClip?.offsetInSession ?? 0
        let correctDuration = matchingPrimaryClip?.duration ?? TimeInterval(bufferLengthSeconds + postRollSeconds)
        let correctStartTime = matchingPrimaryClip?.sourceStartTime
        let correctEndTime = matchingPrimaryClip?.sourceEndTime
        let correctTriggerTime = matchingPrimaryClip?.triggeredAt ?? Date()
        
        let newClip = Clip(
            id: UUID(),
            sessionID: sessionID,
            triggeredAt: correctTriggerTime,
            offsetInSession: correctOffset,
            duration: correctDuration,
            highlightIndex: newHighlightIndex,
            sourceStartTime: correctStartTime,
            sourceEndTime: correctEndTime,
            beforeSeconds: Double(bufferLengthSeconds),
            afterSeconds: Double(postRollSeconds)
        )
        
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
    }
    
    func configureSecondaryVideoProvider(with multipeerManager: MultipeerManager) {
        multipeerManager.onFullVideoRequested = { [weak self] in
            guard let self = self else { return nil }
            return self.sessions.first?.fullVideoURL
        }
    }
    
    func attachImportedFullSecondaryVideo(fileURL: URL, targetSessionID: UUID? = nil) {
        guard !sessions.isEmpty else { return }
        
        let targetIndex: Int
        if let targetID = targetSessionID, let foundIndex = sessions.firstIndex(where: { $0.id == targetID }) {
            targetIndex = foundIndex
        } else {
            targetIndex = 0
        }
        
        let sessionID = sessions[targetIndex].id
        
        for index in sessions[targetIndex].clips.indices {
            if sessions[targetIndex].clips[index].isSecondaryAngle {
                sessions[targetIndex].clips[index].sourceVideoURL = fileURL
            }
        }
        
        if currentSession?.id == sessionID {
            currentSession = sessions[targetIndex]
        }
        
        saveSessionsToDisk()
        updateStorageSize()
    }
    
    func attachSecondaryMasterVideo(fileURL: URL, targetSessionID: UUID? = nil) {
        guard !sessions.isEmpty else { return }
        
        let targetIndex: Int
        if let targetID = targetSessionID, let foundIndex = sessions.firstIndex(where: { $0.id == targetID }) {
            targetIndex = foundIndex
        } else {
            targetIndex = 0
        }
        
        let targetSession = sessions[targetIndex]
        let ext = fileURL.pathExtension.isEmpty ? "mov" : fileURL.pathExtension
        
        let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let destinationURL = documentsURL.appendingPathComponent("secondary_master_\(targetSession.id.uuidString).\(ext)")
        
        do {
            if FileManager.default.fileExists(atPath: destinationURL.path) {
                try FileManager.default.removeItem(at: destinationURL)
            }
            
            try FileManager.default.moveItem(at: fileURL, to: destinationURL)
            
            self.sessions[targetIndex].clips = self.sessions[targetIndex].clips.map { clip in
                if clip.isSecondaryAngle {
                    var updatedClip = clip
                    updatedClip.sourceVideoURL = destinationURL
                    return updatedClip
                }
                return clip
            }
            
            if currentSession?.id == targetSession.id {
                currentSession = self.sessions[targetIndex]
            }
            
            self.saveSessionsToDisk()
            self.updateStorageSize()
            self.objectWillChange.send()
        } catch {
            print("❌ Failed to save and bind incoming master video asset: \(error)")
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
