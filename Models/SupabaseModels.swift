import Foundation

struct SupabaseSessionRecord: Codable, Sendable {
    let id: UUID
    let userId: UUID
    let name: String
    let sessionNumber: Int
    let mode: String
    let startedAt: Date
    let endedAt: Date?
    let isSaved: Bool

    enum CodingKeys: String, CodingKey {
        case id
        case userId = "user_id"
        case name
        case sessionNumber = "session_number"
        case mode
        case startedAt = "started_at"
        case endedAt = "ended_at"
        case isSaved = "is_saved"
    }
}

struct SupabaseClipRecord: Codable, Sendable {
    let id: UUID
    let sessionId: UUID
    let userId: UUID
    let triggeredAt: Date
    let offsetInSession: Double
    let duration: Double
    let highlightIndex: Int?
    let customTitle: String?
    let customName: String?
    let isSecondaryAngle: Bool
    let storagePath: String?
    let isUploaded: Bool

    enum CodingKeys: String, CodingKey {
        case id
        case sessionId = "session_id"
        case userId = "user_id"
        case triggeredAt = "triggered_at"
        case offsetInSession = "offset_in_session"
        case duration
        case highlightIndex = "highlight_index"
        case customTitle = "custom_title"
        case customName = "custom_name"
        case isSecondaryAngle = "is_secondary_angle"
        case storagePath = "storage_path"
        case isUploaded = "is_uploaded"
    }
}
