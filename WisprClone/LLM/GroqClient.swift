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
        timeout: TimeInterval = Constants.LLM.chatTimeoutSeconds
    ) {
        self.apiKey = apiKey
        self.model = model
        self.temperature = temperature
        self.timeout = timeout
    }

    func format(text: String) async throws -> String {
        try await OpenAICompatibleChat.complete(
            endpoint: endpoint,
            apiKey: apiKey,
            model: model,
            temperature: temperature,
            timeout: timeout,
            userText: text,
            providerName: "Groq"
        )
    }
}
