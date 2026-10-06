import Foundation

/// Abstraction over local / cloud transcript cleaners.
protocol TextFormatter: Sendable {
    func format(text: String) async throws -> String
}

/// Request context for intelligent, latency-aware formatting.
struct FormattingRequest: Sendable {
    var text: String
    var utteranceDurationSeconds: TimeInterval = 0
    var asrConfidence: Double? = nil
    var targetBundleID: String? = nil
    var targetAppName: String? = nil
    var targetWindowTitle: String? = nil
    var siteHint: String? = nil
    /// Vocabulary-only hint for the LLM (never prior transcript prose).
    var sessionSummary: String? = nil
    var personalTerms: [String] = []
}

enum LLMPrompt {
    /// Legacy shared prompt — prefer `LLMPromptLibrary` for new paths.
    static let system = LLMPromptLibrary.systemPrompt(
        level: .preserve,
        intent: .plain,
        app: AppFormattingProfile.resolve(bundleID: nil, appName: nil)
    )

    static func userMessage(for transcript: String) -> String {
        LLMPromptLibrary.userMessage(
            transcript: transcript,
            appName: nil,
            level: .preserve,
            intent: .plain,
            sessionSummary: nil,
            personalTerms: []
        )
    }
}
