import Foundation

/// Shared OpenAI-compatible Chat Completions request (OpenAI + Groq).
enum OpenAICompatibleChat {
    static func complete(
        endpoint: URL,
        apiKey: String,
        model: String,
        temperature: Double,
        timeout: TimeInterval,
        userText: String,
        providerName: String
    ) async throws -> String {
        guard !apiKey.isEmpty else {
            throw AppError.notConfigured("\(providerName) API Key Missing")
        }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = timeout

        let body: [String: Any] = [
            "model": model,
            "temperature": temperature,
            "messages": [
                ["role": "system", "content": LLMPrompt.system],
                ["role": "user", "content": LLMPrompt.userMessage(for: userText)]
            ]
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        return try await AppLogger.measure("\(providerName).chat", logger: AppLogger.llm) {
            let data: Data
            let response: URLResponse
            do {
                (data, response) = try await URLSession.shared.data(for: request)
            } catch let urlError as URLError where urlError.code == .timedOut {
                throw AppError.llmTimeout
            } catch {
                throw AppError.llmOffline
            }

            guard let http = response as? HTTPURLResponse else {
                throw AppError.llmFailed("Invalid response")
            }
            guard (200..<300).contains(http.statusCode) else {
                throw AppError.llmFailed("\(providerName) HTTP \(http.statusCode)")
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
