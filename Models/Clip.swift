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
    
    var beforeSeconds: Double?
    var afterSeconds: Double?
    
    var isProcessing: Bool {
        return fileURL == nil
    }
    
    /// Determines if the clip has its full underlying source video available locally for advanced trimming.
    var hasSourceVideoAvailable: Bool {
        // If it's a full session recording itself, it doesn't need a source video.
        if highlightIndex == nil { return true }
        
        // Check if the source video URL exists and actually points to a file that exists on disk.
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
        self.beforeSeconds = beforeSeconds
        self.afterSeconds = afterSeconds
    }

    // 👇 1. EXPLICIT CODING KEYS
    enum CodingKeys: String, CodingKey {
        case id, sessionID, triggeredAt, offsetInSession, fileURL, duration, isUploaded, highlightIndex, customTitle, sourceVideoURL, sourceStartTime, sourceEndTime, customName, isSecondaryAngle
    }

    // 👇 2. UPGRADED CUSTOM DECODER (100% Immune to Sandbox & Subdirectory changes)
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        sessionID = try container.decode(UUID.self, forKey: .sessionID)
        triggeredAt = try container.decode(Date.self, forKey: .triggeredAt)
        offsetInSession = try container.decode(TimeInterval.self, forKey: .offsetInSession)
        
        let docsDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        
        // 🛟 FLAWLESS SANDBOX FIX: Rebuilds paths dynamically keeping any subdirectories intact
        if let oldURL = try container.decodeIfPresent(URL.self, forKey: .fileURL) {
            let pathComponents = oldURL.pathComponents
            if let docsIndex = pathComponents.lastIndex(of: "Documents") {
                let relativePath = pathComponents[(docsIndex + 1)...].joined(separator: "/")
                fileURL = docsDir.appendingPathComponent(relativePath)
            } else {
                fileURL = docsDir.appendingPathComponent(oldURL.lastPathComponent)
            }
        } else {
            fileURL = nil
        }
        
        duration = try container.decode(TimeInterval.self, forKey: .duration)
        isUploaded = try container.decode(Bool.self, forKey: .isUploaded)
        highlightIndex = try container.decodeIfPresent(Int.self, forKey: .highlightIndex)
        customTitle = try container.decodeIfPresent(String.self, forKey: .customTitle)
        
        if let oldSource = try container.decodeIfPresent(URL.self, forKey: .sourceVideoURL) {
            sourceVideoURL = docsDir.appendingPathComponent(oldSource.lastPathComponent)
        } else {
            sourceVideoURL = nil
        }
        
        sourceStartTime = try container.decodeIfPresent(TimeInterval.self, forKey: .sourceStartTime)
        sourceEndTime = try container.decodeIfPresent(TimeInterval.self, forKey: .sourceEndTime)
        customName = try container.decodeIfPresent(String.self, forKey: .customName)
        isSecondaryAngle = try container.decodeIfPresent(Bool.self, forKey: .isSecondaryAngle) ?? false
    }
    
    // 👇 3. CUSTOM ENCODER
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
    }

    var displayName: String {
        if let customName = customName { return customName }
        if isSecondaryAngle, let index = highlightIndex { return "Highlight #\(index) - Camera 2" }
        if let index = highlightIndex {
            // 🌟 Matches the format of the 2nd camera when organizing multi-view clips
            return "Highlight #\(index)"
        }
        return "Full Recording"
    }

    // 🔥 DYNAMIC FORMAT: 0:45 -> 9:21 -> 59:59 -> 1:25:23
    var durationLabel: String {
        let total = Int(max(0, duration)) // Safely prevents negative time
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        
        if h > 0 {
            // 1+ hours (ex: 1:25:23)
            return String(format: "%d:%02d:%02d", h, m, s)
        } else {
            // Under 1 hour (ex: 9:21 or 59:59)
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
    var endedAt: Date?
    var clips: [Clip]
    var fullVideoURL: URL?
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
        self.clips = clips
        self.isSaved = isSaved
    }
    
    // 👇 1. EXPLICIT CODING KEYS FOR SESSION
    enum CodingKeys: String, CodingKey {
        case id, name, sessionNumber, mode, startedAt, endedAt, clips, fullVideoURL, isSaved, isProcessing, processingProgress
    }
    
    // 👇 2. CUSTOM DECODER (Protects your "Full Recording" videos from being deleted)
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        sessionNumber = try container.decode(Int.self, forKey: .sessionNumber)
        mode = try container.decode(RecordingMode.self, forKey: .mode)
        startedAt = try container.decode(Date.self, forKey: .startedAt)
        endedAt = try container.decodeIfPresent(Date.self, forKey: .endedAt)
        clips = try container.decode([Clip].self, forKey: .clips)
        
        let docsDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        
        if let oldURL = try container.decodeIfPresent(URL.self, forKey: .fullVideoURL) {
            let pathComponents = oldURL.pathComponents
            if let docsIndex = pathComponents.lastIndex(of: "Documents") {
                let relativePath = pathComponents[(docsIndex + 1)...].joined(separator: "/")
                fullVideoURL = docsDir.appendingPathComponent(relativePath)
            } else {
                fullVideoURL = docsDir.appendingPathComponent(oldURL.lastPathComponent)
            }
        } else {
            fullVideoURL = nil
        }
        
        isSaved = try container.decode(Bool.self, forKey: .isSaved)
        isProcessing = try container.decodeIfPresent(Bool.self, forKey: .isProcessing) ?? false
        processingProgress = try container.decodeIfPresent(Double.self, forKey: .processingProgress) ?? 0.0
    }
    
    // 👇 3. CUSTOM ENCODER
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(sessionNumber, forKey: .sessionNumber)
        try container.encode(mode, forKey: .mode)
        try container.encode(startedAt, forKey: .startedAt)
        try container.encodeIfPresent(endedAt, forKey: .endedAt)
        try container.encode(clips, forKey: .clips)
        try container.encodeIfPresent(fullVideoURL, forKey: .fullVideoURL)
        try container.encode(isSaved, forKey: .isSaved)
        try container.encode(isProcessing, forKey: .isProcessing)
        try container.encode(processingProgress, forKey: .processingProgress)
    }

    var duration: TimeInterval {
        guard let end = endedAt else { return Date().timeIntervalSince(startedAt) }
        return end.timeIntervalSince(startedAt)
    }

    // 🔥 DYNAMIC FORMAT: 0:45 -> 9:21 -> 59:59 -> 1:25:23
    var durationLabel: String {
        let total = Int(max(0, duration))
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        
        if h > 0 {
            // 1+ hours (ex: 1:25:23)
            return String(format: "%d:%02d:%02d", h, m, s)
        } else {
            // Under 1 hour (ex: 9:21 or 59:59)
            return String(format: "%d:%02d", m, s)
        }
    }

    var formattedDate: String {
        let f = DateFormatter()
        f.dateFormat = "MMM d"
        return f.string(from: startedAt).uppercased()
    }

    var highlights: [Clip] { clips.filter { $0.highlightIndex != nil } }
    var fullRecordingClip: Clip? { clips.first { $0.highlightIndex == nil } }
}
