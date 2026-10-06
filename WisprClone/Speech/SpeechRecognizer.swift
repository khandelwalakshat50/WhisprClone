import Foundation

/// ASR output with optional confidence for confidence-based LLM routing.
/// Named distinctly from WhisperKit's `TranscriptionResult`.
struct SpeechTranscription: Sendable {
    var text: String
    /// 0...1 when the engine provides it (Deepgram).
    var confidence: Double?

    init(text: String, confidence: Double? = nil) {
        self.text = text
        self.confidence = confidence
    }
}

/// Abstraction over local / system / cloud speech engines.
protocol SpeechRecognizing: Sendable {
    func transcribe(audioURL: URL) async throws -> SpeechTranscription
}

/// Engines that can decode live 16 kHz mono float chunks while recording.
protocol LiveChunkASREngine: Sendable {
    func transcribe(samples: [Float], promptContext: String?) async throws -> SpeechTranscription
}

/// Factory that picks an engine from `Configuration`.
enum SpeechRecognizerFactory {
    static func make(
        engine: SpeechEngine,
        deepgramAPIKey: String? = nil,
        deepgramModel: String = Constants.Speech.defaultDeepgramModel,
        whisperModel: String = "openai_whisper-base",
        vocabularyBias: String = ""
    ) -> any SpeechRecognizing {
        switch engine {
        case .deepgram:
            return DeepgramRecognizer(
                apiKey: deepgramAPIKey ?? "",
                model: deepgramModel,
                vocabularyBias: vocabularyBias
            )
        case .whisperKit:
            return WhisperKitRecognizer(modelName: whisperModel, vocabularyBias: vocabularyBias)
        case .appleSpeech:
            return AppleSpeechRecognizer()
        }
    }
}
