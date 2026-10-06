import Foundation

/// Local Ollama chat client (`http://localhost:11434/api/chat`).
struct OllamaClient: TextFormatter {
    var baseURL: URL
    var model: String
    var fallbackModel: String
    var timeout: TimeInterval

    init(
        baseURL: URL = Constants.LLM.ollamaBaseURL,
        model: String = Constants.LLM.defaultOllamaModel,
        fallbackModel: String = Constants.LLM.fallbackOllamaModel,
        timeout: TimeInterval = Constants.LLM.ollamaTimeoutSeconds
    ) {
        self.baseURL = baseURL
        self.model = model
        self.fallbackModel = fallbackModel
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
        do {
            return try await chat(
                model: model,
                text: text,
                systemPrompt: systemPrompt,
                userMessage: userMessage
            )
        } catch {
            guard model != fallbackModel else { throw error }
            AppLogger.llm.warning("Primary Ollama model failed; trying fallback \(self.fallbackModel, privacy: .public)")
            return try await chat(
                model: fallbackModel,
                text: text,
                systemPrompt: systemPrompt,
                userMessage: userMessage
            )
        }
    }

    private func chat(
        model: String,
        text: String,
        systemPrompt: String,
        userMessage: String
    ) async throws -> String {
        let url = baseURL.appendingPathComponent("api/chat")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = timeout
        _ = text

        let body: [String: Any] = [
            "model": model,
            "stream": false,
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": userMessage]
            ]
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        return try await AppLogger.measure("Ollama.chat", logger: AppLogger.llm) {
            let data: Data
            let response: URLResponse
            do {
                (data, response) = try await URLSession.shared.data(for: request)
            } catch let urlError as URLError {
                switch urlError.code {
                case .timedOut:
                    throw AppError.llmTimeout
                case .cannotConnectToHost, .networkConnectionLost, .notConnectedToInternet, .dnsLookupFailed:
                    throw AppError.llmOffline
                default:
                    throw AppError.llmOffline
                }
            } catch {
                throw AppError.llmOffline
            }

            guard let http = response as? HTTPURLResponse else {
                throw AppError.llmFailed("Invalid response")
            }
            guard (200..<300).contains(http.statusCode) else {
                throw AppError.llmFailed("HTTP \(http.statusCode)")
            }

            guard
                let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                let message = json["message"] as? [String: Any],
                let content = message["content"] as? String
            else {
                throw AppError.llmFailed("Malformed Ollama payload")
            }

            let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { throw AppError.llmFailed("Empty Ollama response") }
            return trimmed
        }
    }
}
