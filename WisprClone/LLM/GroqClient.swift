import Foundation

/// Groq Chat Completions (OpenAI-compatible API).
struct GroqClient: TextFormatter {
    var apiKey: String
    var model: String
    var temperature: Double
    var timeout: TimeInterval

    private let endpoint = URL(string: "https://api.groq.com/openai/v1/chat/completions")!

    init(
        apiKey: String,
        model: String = Constants.LLM.defaultGroqModel,
        temperature: Double = 0.2,
        timeout: TimeInterval = Constants.LLM.groqTimeoutSeconds
    ) {
        self.apiKey = apiKey
        self.model = model
        self.temperature = temperature
        self.timeout = timeout
    }

    func format(text: String) async throws -> String {
        try await format(
            text: text,
            systemPrompt: LLMPrompt.system,
            userMessage: LLMPrompt.userMessage(for: text)
        )
    }

    func format(
        text: String,
        systemPrompt: String,
        userMessage: String
    ) async throws -> String {
        try await OpenAICompatibleChat.complete(
            endpoint: endpoint,
            apiKey: apiKey,
            model: model,
            temperature: temperature,
            timeout: timeout,
            userText: text,
            providerName: "Groq",
            systemPrompt: systemPrompt,
            userMessage: userMessage,
            extraFields: Self.reasoningFields(for: model)
        )
    }

    /// Groq's current chat models reason by default — thinking adds latency and tokens.
    private static func reasoningFields(for model: String) -> [String: any Sendable] {
        let id = model.lowercased()
        if id.contains("qwen3") {
            return ["reasoning_effort": "none"]
        }
        if id.contains("gpt-oss") {
            return ["reasoning_effort": "low", "include_reasoning": false]
        }
        return [:]
    }
}
