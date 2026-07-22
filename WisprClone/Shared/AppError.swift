import Foundation

/// User-facing errors mapped into overlay copy via `RecordingState.failure`.
enum AppError: Error, LocalizedError, Equatable {
    case microphoneUnavailable
    case microphonePermissionDenied
    case speechPermissionDenied
    case accessibilityPermissionDenied
    case inputMonitoringPermissionDenied
    case recordingFailed(String)
    case transcriptionFailed(String)
    case llmOffline
    case llmTimeout
    case llmFailed(String)
    case injectionFailed(String)
    case emptyTranscript
    case cancelled
    case notConfigured(String)

    var errorDescription: String? {
        switch self {
        case .microphoneUnavailable:
            return "Microphone Unavailable"
        case .microphonePermissionDenied:
            return "Microphone Access Denied"
        case .speechPermissionDenied:
            return "Speech Access Denied"
        case .accessibilityPermissionDenied:
            return "Accessibility Access Denied"
        case .inputMonitoringPermissionDenied:
            return "Input Monitoring Denied"
        case .recordingFailed(let detail):
            return detail.isEmpty ? "Recording Failed" : detail
        case .transcriptionFailed(let detail):
            return detail.isEmpty ? "Transcription Failed" : detail
        case .llmOffline:
            return "LLM Offline"
        case .llmTimeout:
            return "LLM Timeout"
        case .llmFailed(let detail):
            return detail.isEmpty ? "Formatting Failed" : detail
        case .injectionFailed(let detail):
            return detail.isEmpty ? "Insert Failed" : detail
        case .emptyTranscript:
            return "No Speech Detected"
        case .cancelled:
            return "Cancelled"
        case .notConfigured(let detail):
            return detail
        }
    }
}
