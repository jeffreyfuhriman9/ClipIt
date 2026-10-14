import Foundation

struct Clip: Identifiable, Codable, Equatable {
    let id: UUID
    let sessionID: UUID
    let triggeredAt: Date
    let offsetInSession: TimeInterval
    var fileURL: URL?
    var duration: TimeInterval
    var isUploaded: Bool
    var highlightIndex: Int?   // nil = full recording, 1+ = Highlight N
    var customTitle: String?
    var sourceVideoURL: URL?
    var sourceStartTime: TimeInterval?
    var sourceEndTime: TimeInterval?
    var customName: String?
    var isSecondaryAngle: Bool = false
    var isReel: Bool = false
    var isFavorite: Bool = false
    
    var beforeSeconds: Double?
    var afterSeconds: Double?
    
    var createdAt: Date = Date()
    
    var isProcessing: Bool {
        return fileURL == nil
    }
    
    /// Determines if the clip has its full underlying source video available locally for advanced trimming.
    var hasSourceVideoAvailable: Bool {
        if highlightIndex == nil { return true }
        
        if let sourceURL = sourceVideoURL {
            return FileManager.default.fileExists(atPath: sourceURL.path)
        }
        
        return false
    }

    init(
        id: UUID = UUID(),
        sessionID: UUID,
        triggeredAt: Date = Date(),
        offsetInSession: TimeInterval,
        fileURL: URL? = nil,
        duration: TimeInterval = 20,
        isUploaded: Bool = false,
        highlightIndex: Int? = nil,
        customTitle: String? = nil,
        sourceVideoURL: URL? = nil,
        sourceStartTime: TimeInterval? = nil,
        sourceEndTime: TimeInterval? = nil,
        customName: String? = nil,
        isSecondaryAngle: Bool = false,
        isFavorite: Bool = false,
        beforeSeconds: Double? = nil,
        afterSeconds: Double? = nil
    ) {
        self.id = id
        self.sessionID = sessionID
        self.triggeredAt = triggeredAt
        self.offsetInSession = offsetInSession
        self.fileURL = fileURL
        self.duration = duration
        self.isUploaded = isUploaded
        self.highlightIndex = highlightIndex
        self.customTitle = customTitle
        self.sourceVideoURL = sourceVideoURL
        self.sourceStartTime = sourceStartTime
        self.sourceEndTime = sourceEndTime
        self.customName = customName
        self.isSecondaryAngle = isSecondaryAngle
        self.isFavorite = isFavorite
        self.beforeSeconds = beforeSeconds
        self.afterSeconds = afterSeconds
    }

    // EXPLICIT CODING KEYS
    enum CodingKeys: String, CodingKey {
        case id, sessionID, triggeredAt, offsetInSession, isReel, fileURL, duration, isUploaded, highlightIndex, customTitle, sourceVideoURL, sourceStartTime, sourceEndTime, customName, isSecondaryAngle, isFavorite
    }

    // UPGRADED CUSTOM DECODER
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        sessionID = try container.decode(UUID.self, forKey: .sessionID)
        triggeredAt = try container.decode(Date.self, forKey: .triggeredAt)
        offsetInSession = try container.decode(TimeInterval.self, forKey: .offsetInSession)
        duration = try container.decode(TimeInterval.self, forKey: .duration)
        isUploaded = try container.decode(Bool.self, forKey: .isUploaded)
        highlightIndex = try container.decodeIfPresent(Int.self, forKey: .highlightIndex)
        customTitle = try container.decodeIfPresent(String.self, forKey: .customTitle)
        isReel = try container.decodeIfPresent(Bool.self, forKey: .isReel) ?? false
        
        let isHighlight = (highlightIndex != nil)
        
        if let oldURL = try container.decodeIfPresent(URL.self, forKey: .fileURL) {
            fileURL = Clip.resolveFileURL(from: oldURL, isHighlight: isHighlight, isReel: isReel)
        } else {
            fileURL = nil
        }
        
        if let oldSource = try container.decodeIfPresent(URL.self, forKey: .sourceVideoURL) {
            sourceVideoURL = Clip.resolveFileURL(from: oldSource, isHighlight: false, isReel: false)
        } else {
            sourceVideoURL = nil
        }
        
        sourceStartTime = try container.decodeIfPresent(TimeInterval.self, forKey: .sourceStartTime)
        sourceEndTime = try container.decodeIfPresent(TimeInterval.self, forKey: .sourceEndTime)
        customName = try container.decodeIfPresent(String.self, forKey: .customName)
        isSecondaryAngle = try container.decodeIfPresent(Bool.self, forKey: .isSecondaryAngle) ?? false
        isFavorite = try container.decodeIfPresent(Bool.self, forKey: .isFavorite) ?? false
    }
    
    // UPDATE: Encoder
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(sessionID, forKey: .sessionID)
        try container.encode(triggeredAt, forKey: .triggeredAt)
        try container.encode(offsetInSession, forKey: .offsetInSession)
        try container.encodeIfPresent(fileURL, forKey: .fileURL)
        try container.encode(duration, forKey: .duration)
        try container.encode(isUploaded, forKey: .isUploaded)
        try container.encodeIfPresent(highlightIndex, forKey: .highlightIndex)
        try container.encodeIfPresent(customTitle, forKey: .customTitle)
        try container.encodeIfPresent(sourceVideoURL, forKey: .sourceVideoURL)
        try container.encodeIfPresent(sourceStartTime, forKey: .sourceStartTime)
        try container.encodeIfPresent(sourceEndTime, forKey: .sourceEndTime)
        try container.encodeIfPresent(customName, forKey: .customName)
        try container.encode(isSecondaryAngle, forKey: .isSecondaryAngle)
        try container.encode(isReel, forKey: .isReel)
        try container.encode(isFavorite, forKey: .isFavorite) 
    }

    // UPDATE: SMART PATH RESOLVER
    static func resolveFileURL(from oldURL: URL, isHighlight: Bool, isReel: Bool = false) -> URL {
        let docsDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let filename = oldURL.lastPathComponent
        
        // 1. Try path components relative to "Documents" (New Build format)
        let pathComponents = oldURL.pathComponents
        if let docsIndex = pathComponents.lastIndex(of: "Documents") {
            var rebuiltURL = docsDir
            for component in pathComponents[(docsIndex + 1)...] {
                rebuiltURL = rebuiltURL.appendingPathComponent(component)
            }
            if FileManager.default.fileExists(atPath: rebuiltURL.path) {
                return rebuiltURL
            }
        }
        
        // 2. Check if file physically exists in Documents/HighlightReels/
        let reelsFolderURL = docsDir.appendingPathComponent("HighlightReels", isDirectory: true).appendingPathComponent(filename)
        if FileManager.default.fileExists(atPath: reelsFolderURL.path) {
            return reelsFolderURL
        }
        
        // 3. Backward Compatibility: Check if file physically exists in Documents/Clips/
        let clipsFolderURL = docsDir.appendingPathComponent("Clips", isDirectory: true).appendingPathComponent(filename)
        if FileManager.default.fileExists(atPath: clipsFolderURL.path) {
            return clipsFolderURL
        }
        
        // 4. Backward Compatibility: Check if file physically exists in root Documents/
        let rootDocsURL = docsDir.appendingPathComponent(filename)
        if FileManager.default.fileExists(atPath: rootDocsURL.path) {
            return rootDocsURL
        }
        
        // 5. Fallback if file doesn't exist yet on disk
        if isReel {
            return reelsFolderURL
        }
        return isHighlight ? clipsFolderURL : rootDocsURL
    }

    var displayName: String {
        if let customName = customName { return customName }
        if let customTitle = customTitle { return customTitle }
        if isSecondaryAngle, let index = highlightIndex { return "Highlight #\(index) - Camera 2" }
        if let index = highlightIndex {
            return "Clip #\(index)"
        }
        return "Original Video"
    }

    var durationLabel: String {
        let total = Int(max(0, duration))
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        
        if h > 0 {
            return String(format: "%d:%02d:%02d", h, m, s)
        } else {
            return String(format: "%d:%02d", m, s)
        }
    }
}

// MARK: - Session Struct

struct Session: Identifiable, Codable {
    let id: UUID
    var name: String
    var sessionNumber: Int
    let mode: RecordingMode
    let startedAt: Date
    // Camera-confirmed start, used to position taps buffered by the button.
    var videoStartedAt: Date?
    var endedAt: Date?
    var clips: [Clip]
    var fullVideoURL: URL?
    var originalVideoDeletionDate: Date?
    var originalVideoAutoDeleteDisabled: Bool
    var isSaved: Bool
    var isProcessing: Bool = false
    var processingProgress: Double = 0.0

    static func generateDefaultName(startedAt: Date, sessionNumber: Int) -> String {
        return "SESSION \(sessionNumber)"
    }

    init(
        id: UUID = UUID(),
        name: String = "",
        sessionNumber: Int = 1,
        mode: RecordingMode,
        startedAt: Date = Date(),
        clips: [Clip] = [],
        isSaved: Bool = false
    ) {
        self.id = id
        self.sessionNumber = sessionNumber
        self.name = name.isEmpty ? Session.generateDefaultName(startedAt: startedAt, sessionNumber: sessionNumber) : name
        self.mode = mode
        self.startedAt = startedAt
        self.videoStartedAt = nil
        self.clips = clips
        self.isSaved = isSaved
        self.originalVideoDeletionDate = nil
        self.originalVideoAutoDeleteDisabled = false
    }
    
    enum CodingKeys: String, CodingKey {
        case id, name, sessionNumber, mode, startedAt, videoStartedAt, endedAt, clips, fullVideoURL, originalVideoDeletionDate, originalVideoAutoDeleteDisabled, isSaved, isProcessing, processingProgress
    }
    
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        sessionNumber = try container.decode(Int.self, forKey: .sessionNumber)
        mode = try container.decode(RecordingMode.self, forKey: .mode)
        startedAt = try container.decode(Date.self, forKey: .startedAt)
        videoStartedAt = try container.decodeIfPresent(Date.self, forKey: .videoStartedAt)
        endedAt = try container.decodeIfPresent(Date.self, forKey: .endedAt)
        clips = try container.decode([Clip].self, forKey: .clips)
        
        if let oldURL = try container.decodeIfPresent(URL.self, forKey: .fullVideoURL) {
            fullVideoURL = Clip.resolveFileURL(from: oldURL, isHighlight: false)
        } else {
            fullVideoURL = nil
        }

        originalVideoDeletionDate = try container.decodeIfPresent(Date.self, forKey: .originalVideoDeletionDate)
        originalVideoAutoDeleteDisabled = try container.decodeIfPresent(Bool.self, forKey: .originalVideoAutoDeleteDisabled) ?? false
        
        isSaved = try container.decode(Bool.self, forKey: .isSaved)
        isProcessing = try container.decodeIfPresent(Bool.self, forKey: .isProcessing) ?? false
        processingProgress = try container.decodeIfPresent(Double.self, forKey: .processingProgress) ?? 0.0
    }
    
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(sessionNumber, forKey: .sessionNumber)
        try container.encode(mode, forKey: .mode)
        try container.encode(startedAt, forKey: .startedAt)
        try container.encodeIfPresent(videoStartedAt, forKey: .videoStartedAt)
        try container.encodeIfPresent(endedAt, forKey: .endedAt)
        try container.encode(clips, forKey: .clips)
        try container.encodeIfPresent(fullVideoURL, forKey: .fullVideoURL)
        try container.encodeIfPresent(originalVideoDeletionDate, forKey: .originalVideoDeletionDate)
        try container.encode(originalVideoAutoDeleteDisabled, forKey: .originalVideoAutoDeleteDisabled)
        try container.encode(isSaved, forKey: .isSaved)
        try container.encode(isProcessing, forKey: .isProcessing)
        try container.encode(processingProgress, forKey: .processingProgress)
    }

    var duration: TimeInterval {
        guard let end = endedAt else { return Date().timeIntervalSince(startedAt) }
        return end.timeIntervalSince(startedAt)
    }

    var durationLabel: String {
        let total = Int(max(0, duration))
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        
        if h > 0 {
            return String(format: "%d:%02d:%02d", h, m, s)
        } else {
            return String(format: "%d:%02d", m, s)
        }
    }

    var formattedDate: String {
        let f = DateFormatter()
        f.dateFormat = "MMM d"
        return f.string(from: startedAt).uppercased()
    }

    // 🌟 Helper accessors
    var highlights: [Clip] { clips.filter { $0.highlightIndex != nil && !$0.isReel } }
    var reels: [Clip] { clips.filter { $0.isReel } }
    var fullRecordingClip: Clip? { clips.first { $0.highlightIndex == nil && !$0.isReel } }
}
