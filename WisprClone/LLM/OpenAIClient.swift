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
        model: String = "gpt-4o-mini",
        temperature: Double = 0.2,
        timeout: TimeInterval = 30
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
            providerName: "OpenAI"
        )
    }
}
