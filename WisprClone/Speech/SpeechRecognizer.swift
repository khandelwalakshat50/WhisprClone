import Foundation

/// Abstraction over local / system speech engines.
protocol SpeechRecognizing: Sendable {
    func transcribe(audioURL: URL) async throws -> String
}

/// Factory that picks an engine from `Configuration`.
enum SpeechRecognizerFactory {
    static func make(engine: SpeechEngine) -> any SpeechRecognizing {
        switch engine {
        case .whisperKit:
            return WhisperKitRecognizer()
        case .appleSpeech:
            return AppleSpeechRecognizer()
        }
    }
}
