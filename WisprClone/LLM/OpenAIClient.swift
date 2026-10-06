import Foundation

/// OpenAI Chat Completions client.
struct OpenAIClient: TextFormatter {
    var apiKey: String
    var model: String
    var temperature: Double
    var timeout: TimeInterval

    private let endpoint = URL(string: "https://api.openai.com/v1/chat/completions")!

    init(
        apiKey: String,
        model: String = Constants.LLM.defaultOpenAIModel,
        temperature: Double = 0.2,
        timeout: TimeInterval = Constants.LLM.chatTimeoutSeconds
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
            providerName: "OpenAI",
            systemPrompt: systemPrompt,
            userMessage: userMessage,
            usesReasoningParameters: Self.isReasoningFamily(model)
        )
    }

    private static func isReasoningFamily(_ model: String) -> Bool {
        let id = model.lowercased()
        return id.hasPrefix("gpt-5") || id.hasPrefix("o1") || id.hasPrefix("o3") || id.hasPrefix("o4")
    }
}
