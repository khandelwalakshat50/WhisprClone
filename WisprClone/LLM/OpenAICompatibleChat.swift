import Foundation

/// Shared OpenAI-compatible Chat Completions request (OpenAI + Groq).
enum OpenAICompatibleChat {
    /// Reused session keeps TLS warm across dictations (matches GeminiClient).
    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = Constants.LLM.chatTimeoutSeconds
        config.timeoutIntervalForResource = Constants.LLM.chatTimeoutSeconds + 2
        config.waitsForConnectivity = false
        config.httpMaximumConnectionsPerHost = 4
        return URLSession(configuration: config)
    }()

    static func complete(
        endpoint: URL,
        apiKey: String,
        model: String,
        temperature: Double,
        timeout: TimeInterval,
        userText: String,
        providerName: String,
        systemPrompt: String = LLMPrompt.system,
        userMessage: String? = nil,
        usesReasoningParameters: Bool = false,
        extraFields: [String: any Sendable] = [:]
    ) async throws -> String {
        guard !apiKey.isEmpty else {
            throw AppError.notConfigured("\(providerName) API Key Missing")
        }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("WisprClone/1.0", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = timeout

        var body: [String: Any] = [
            "model": model,
            "temperature": temperature,
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": userMessage ?? LLMPrompt.userMessage(for: userText)]
            ]
        ]
        // GPT-5 / o-series reject `max_tokens`; reasoning "none" avoids thinking latency.
        if usesReasoningParameters {
            body["max_completion_tokens"] = Constants.LLM.chatMaxOutputTokens
            body["reasoning_effort"] = "none"
        } else {
            body["max_tokens"] = Constants.LLM.chatMaxOutputTokens
        }
        for (key, value) in extraFields {
            body[key] = value
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        return try await AppLogger.measure("\(providerName).chat", logger: AppLogger.llm) {
            let data: Data
            let response: URLResponse
            do {
                (data, response) = try await Self.session.data(for: request)
            } catch let urlError as URLError where urlError.code == .timedOut {
                throw AppError.llmTimeout
            } catch {
                throw AppError.llmOffline
            }

            guard let http = response as? HTTPURLResponse else {
                throw AppError.llmFailed("Invalid response")
            }
            guard (200..<300).contains(http.statusCode) else {
                let detail = String(data: data, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .prefix(140) ?? ""
                throw AppError.llmFailed("\(providerName) HTTP \(http.statusCode)\(detail.isEmpty ? "" : ": \(detail)")")
            }

            guard
                let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                let choices = json["choices"] as? [[String: Any]],
                let message = choices.first?["message"] as? [String: Any],
                let content = message["content"] as? String
            else {
                throw AppError.llmFailed("Malformed \(providerName) payload")
            }

            let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { throw AppError.llmFailed("Empty \(providerName) response") }
            return trimmed
        }
    }
}
