import Foundation

/// Single application-wide recording / pipeline state.
/// Every UI surface (menu bar, overlay) should react to this value.
enum RecordingState: Equatable, Sendable {
    case idle
    case listening
    case detectingSpeech
    case transcribing
    case formatting
    case injecting
    case success
    case failure(String)

    static func == (lhs: RecordingState, rhs: RecordingState) -> Bool {
        switch (lhs, rhs) {
        case (.idle, .idle),
             (.listening, .listening),
             (.detectingSpeech, .detectingSpeech),
             (.transcribing, .transcribing),
             (.formatting, .formatting),
             (.injecting, .injecting),
             (.success, .success):
            return true
        case let (.failure(l), .failure(r)):
            return l == r
        default:
            return false
        }
    }

    /// Short status copy suitable for overlay / accessibility labels.
    var statusText: String {
        switch self {
        case .idle:
            return ""
        case .listening:
            return "Listening…"
        case .detectingSpeech:
            return "Listening…"
        case .transcribing:
            return "Transcribing…"
        case .formatting:
            return "Formatting…"
        case .injecting:
            return "Inserting…"
        case .success:
            return "Done"
        case .failure(let message):
            return message
        }
    }
}
