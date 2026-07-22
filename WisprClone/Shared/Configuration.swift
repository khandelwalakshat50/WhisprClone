import Foundation

enum SpeechEngine: String, CaseIterable, Sendable {
    case whisperKit
    case appleSpeech
}

enum FormattingMode: String, CaseIterable, Sendable {
    case localOnly
    case groqOnly
    case openAIOnly
    case autoFallback
}

enum AppTheme: String, CaseIterable, Sendable {
    case system
    case light
    case dark

    var title: String {
        switch self {
        case .system: return "System"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }
}

/// App configuration snapshot. Persisted by `ConfigurationStore` (UserDefaults + Keychain / `.env`).
struct Configuration: Equatable, Sendable {
    var speechEngine: SpeechEngine
    var formattingMode: FormattingMode
    var ollamaModel: String
    var openAIModel: String
    var groqModel: String
    var whisperModel: String
    var temperature: Double
    var ollamaTimeout: TimeInterval
    var theme: AppTheme

    static let `default` = Configuration(
        speechEngine: .whisperKit,
        formattingMode: .autoFallback,
        ollamaModel: Constants.LLM.defaultOllamaModel,
        openAIModel: "gpt-4o-mini",
        groqModel: Constants.LLM.defaultGroqModel,
        whisperModel: "base",
        temperature: 0.2,
        ollamaTimeout: Constants.LLM.ollamaTimeoutSeconds,
        theme: .system
    )
}
