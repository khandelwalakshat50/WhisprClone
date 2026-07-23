import Foundation

/// Google Gemini generateContent API (AI Studio / Generative Language).
/// Tuned for dictation latency: minimal thinking, short prompt, capped output.
struct GeminiClient: TextFormatter {
    var apiKey: String
    var model: String
    var temperature: Double
    var timeout: TimeInterval
    /// Used when the preferred model is overloaded / unavailable (503).
    var fallbackModel: String

    /// Reused session keeps TLS warm across dictations.
    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = Constants.LLM.geminiTimeoutSeconds
        config.timeoutIntervalForResource = Constants.LLM.geminiTimeoutSeconds + 2
        config.waitsForConnectivity = false
        config.httpMaximumConnectionsPerHost = 2
        return URLSession(configuration: config)
    }()

    init(
        apiKey: String,
        model: String = Constants.LLM.defaultGeminiModel,
        temperature: Double = 0.2,
        timeout: TimeInterval = Constants.LLM.geminiTimeoutSeconds,
        fallbackModel: String = Constants.LLM.fallbackGeminiModel
    ) {
        self.apiKey = apiKey
        self.model = model
        self.temperature = temperature
        self.timeout = timeout
        self.fallbackModel = fallbackModel
    }

    func format(text: String) async throws -> String {
        guard !apiKey.isEmpty else {
            throw AppError.notConfigured("Gemini API Key Missing")
        }

        do {
            return try await generate(text: text, model: model)
        } catch let error as AppError where Self.shouldRetryWithFallback(error)
            && fallbackModel != model
            && !fallbackModel.isEmpty {
            DiagnosticLog.write("gemini \(model) failed (\(Self.short(error))); retry \(fallbackModel)")
            AppLogger.llm.warning(
                "Gemini \(self.model, privacy: .public) unavailable; retrying \(self.fallbackModel, privacy: .public)"
            )
            return try await generate(text: text, model: fallbackModel)
        }
    }

    // MARK: - Private

    private func generate(text: String, model: String) async throws -> String {
        let encodedModel = model.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? model
        guard let endpoint = URL(
            string: "https://generativelanguage.googleapis.com/v1beta/models/\(encodedModel):generateContent"
        ) else {
            throw AppError.llmFailed("Invalid Gemini endpoint")
        }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        request.timeoutInterval = timeout

        // Minimal thinking is the main latency win on Gemini 3.x Flash.
        let body: [String: Any] = [
            "system_instruction": [
                "parts": [["text": LLMPrompt.geminiSystem]]
            ],
            "contents": [
                [
                    "role": "user",
                    "parts": [["text": LLMPrompt.userMessage(for: text)]]
                ]
            ],
            "generationConfig": [
                "temperature": temperature,
                "maxOutputTokens": Constants.LLM.geminiMaxOutputTokens,
                "thinkingConfig": [
                    "thinkingLevel": "minimal"
                ]
            ]
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        DiagnosticLog.write("gemini request model=\(model)")

        return try await AppLogger.measure("Gemini.generateContent", logger: AppLogger.llm) {
            let data: Data
            let response: URLResponse
            do {
                (data, response) = try await Self.session.data(for: request)
            } catch let urlError as URLError where urlError.code == .timedOut {
                DiagnosticLog.write("gemini timeout model=\(model)")
                throw AppError.llmTimeout
            } catch {
                DiagnosticLog.write("gemini offline model=\(model)")
                throw AppError.llmOffline
            }

            guard let http = response as? HTTPURLResponse else {
                throw AppError.llmFailed("Invalid Gemini response")
            }
            guard (200..<300).contains(http.statusCode) else {
                let detail = String(data: data, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                DiagnosticLog.write("gemini HTTP \(http.statusCode) model=\(model)")
                let clipped = String(detail.prefix(160))
                let suffix = clipped.isEmpty ? "" : ": \(clipped)"
                throw AppError.llmFailed("Gemini HTTP \(http.statusCode)\(suffix)")
            }

            guard
                let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                let candidates = json["candidates"] as? [[String: Any]],
                let content = candidates.first?["content"] as? [String: Any],
                let parts = content["parts"] as? [[String: Any]]
            else {
                throw AppError.llmFailed("Malformed Gemini payload")
            }

            let texts = parts.compactMap { part -> String? in
                if let thought = part["thought"] as? Bool, thought { return nil }
                return part["text"] as? String
            }
            let trimmed = texts
                .joined()
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { throw AppError.llmFailed("Empty Gemini response") }
            DiagnosticLog.write("gemini ok model=\(model) chars=\(trimmed.count)")
            return trimmed
        }
    }

    private static func shouldRetryWithFallback(_ error: AppError) -> Bool {
        switch error {
        case .llmTimeout, .llmOffline:
            return true
        case .llmFailed(let message):
            let lower = message.lowercased()
            return lower.contains("http 503")
                || lower.contains("http 429")
                || lower.contains("http 500")
                || lower.contains("unavailable")
                || lower.contains("high demand")
                || lower.contains("quota")
        default:
            return false
        }
    }

    private static func short(_ error: AppError) -> String {
        switch error {
        case .llmTimeout: return "timeout"
        case .llmOffline: return "offline"
        case .llmFailed(let msg): return String(msg.prefix(80))
        default: return error.localizedDescription
        }
    }
}
