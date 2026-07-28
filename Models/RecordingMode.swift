import Foundation

enum RecordingMode: String, CaseIterable, Identifiable, Codable {
    case highlightsOnly = "Highlights only"
    case fullSession    = "Full session"

    var id: String { rawValue }

    var description: String {
        switch self {
        case .highlightsOnly:
            return "Saves clips around each button press. No full video stored."
        case .fullSession:
            return "Records everything + marks highlights for easy export."
        }
    }

    var systemImage: String {
        switch self {
        case .highlightsOnly: return "scissors"
        case .fullSession:    return "video.fill"
        }
    }

    var isPro: Bool {
        switch self {
        case .highlightsOnly: return false
        case .fullSession:    return true
        }
    }

    var estimatedSizePerHour: String {
        switch self {
        case .highlightsOnly: return "~300 MB/hr"
        case .fullSession:    return "~7.5 GB/hr"
        }
    }
}
