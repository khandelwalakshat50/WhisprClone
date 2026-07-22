import Foundation

/// Routes formatting across Local / Groq / OpenAI / Auto Fallback.
struct LLMFormattingService: TextFormatter {
    var mode: FormattingMode
    var ollama: OllamaClient
    var groq: GroqClient?
    var openAI: OpenAIClient?
    var recordUsage: (@Sendable (LLMProvider) async -> Void)?

    func format(text: String) async throws -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw AppError.emptyTranscript }

        let result: String
        let provider: LLMProvider
        switch mode {
        case .localOnly:
            result = try await ollama.format(text: trimmed)
            provider = .ollama
        case .groqOnly:
            guard let groq else { throw AppError.notConfigured("Groq API Key Missing") }
            result = try await groq.format(text: trimmed)
            provider = .groq
        case .openAIOnly:
            guard let openAI else { throw AppError.notConfigured("OpenAI API Key Missing") }
            result = try await openAI.format(text: trimmed)
            provider = .openAI
        case .autoFallback:
            (result, provider) = try await autoFormat(trimmed)
        }
        await recordUsage?(provider)
        return Self.sanitize(result)
    }

    /// Strips artifacts a model may add despite instructions:
    /// echoed <transcript> tags or quotes wrapped around the whole output.
    static func sanitize(_ text: String) -> String {
        var output = text
            .replacingOccurrences(of: "<transcript>", with: "")
            .replacingOccurrences(of: "</transcript>", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        for (open, close) in [("\"", "\""), ("“", "”")] {
            if output.hasPrefix(open), output.hasSuffix(close), output.count > 2 {
                output = String(output.dropFirst().dropLast())
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return output
    }

    /// Ollama → Groq → OpenAI
    private func autoFormat(_ text: String) async throws -> (String, LLMProvider) {
        do {
            return (try await ollama.format(text: text), .ollama)
        } catch let error where Self.shouldFallback(error) {
            AppLogger.llm.warning("Ollama unavailable; trying Groq — \(error.localizedDescription, privacy: .public)")
        }

        if let groq {
            do {
                return (try await groq.format(text: text), .groq)
            } catch let error where Self.shouldFallback(error) {
                AppLogger.llm.warning("Groq unavailable; trying OpenAI — \(error.localizedDescription, privacy: .public)")
            }
        }

        if let openAI {
            return (try await openAI.format(text: text), .openAI)
        }

        throw AppError.llmOffline
    }

    private static func shouldFallback(_ error: Error) -> Bool {
        if let app = error as? AppError {
            switch app {
            case .llmOffline, .llmTimeout, .llmFailed, .notConfigured:
                return true
            default:
                return false
            }
        }
        if let urlError = error as? URLError {
            switch urlError.code {
            case .timedOut, .cannotConnectToHost, .networkConnectionLost, .notConnectedToInternet, .dnsLookupFailed:
                return true
            default:
                return false
            }
        }
        return false
    }
}
