import Foundation

/// Result of an LLM formatting pass, including which provider won and any
/// fallback / network notes useful for History diagnostics.
struct FormatResult: Sendable {
    let text: String
    let provider: LLMProvider
    let notes: [String]
}

/// Routes formatting across Gemini / Groq / OpenAI / Local / Auto Fallback.
struct LLMFormattingService: TextFormatter {
    var mode: FormattingMode
    var ollama: OllamaClient
    var gemini: GeminiClient?
    var groq: GroqClient?
    var openAI: OpenAIClient?
    var recordUsage: (@Sendable (LLMProvider) async -> Void)?

    /// Capture-window length used by Auto mode to pick Gemini vs Groq first.
    var utteranceDurationSeconds: TimeInterval = 0

    func format(text: String) async throws -> String {
        try await formatDetailed(text: text).text
    }

    func formatDetailed(text: String) async throws -> FormatResult {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // Callers should skip empty input; never hit the network for blank text.
        guard !trimmed.isEmpty else {
            return FormatResult(text: "", provider: .ollama, notes: ["skipped: empty transcript"])
        }

        let pieces = Self.splitForFormatting(trimmed, maxCharacters: Constants.Formatting.maxChunkCharacters)
        if pieces.count == 1 {
            return try await formatSingle(pieces[0], fullTranscript: trimmed, extraNotes: [])
        }

        // Long dictation: format sentence-bounded chunks in parallel.
        var notes = ["LLM split into \(pieces.count) chunks for long dictation (parallel)"]
        let full = trimmed
        let results: [(Int, FormatResult)] = try await withThrowingTaskGroup(of: (Int, FormatResult).self) { group in
            for (i, piece) in pieces.enumerated() {
                group.addTask {
                    let part = try await self.formatSingle(piece, fullTranscript: full, extraNotes: [])
                    return (i, part)
                }
            }
            var collected: [(Int, FormatResult)] = []
            for try await item in group {
                collected.append(item)
            }
            return collected.sorted { $0.0 < $1.0 }
        }

        var formattedParts: [String] = []
        var provider: LLMProvider = .ollama
        for (i, part) in results {
            provider = part.provider
            notes.append(contentsOf: part.notes.map { "chunk \(i + 1): \($0)" })
            let cleaned = part.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !cleaned.isEmpty {
                formattedParts.append(cleaned)
            }
        }

        return FormatResult(
            text: formattedParts.joined(separator: "\n\n"),
            provider: provider,
            notes: notes
        )
    }

    private func formatSingle(
        _ trimmed: String,
        fullTranscript: String,
        extraNotes: [String]
    ) async throws -> FormatResult {
        var notes = extraNotes
        let result: String
        let provider: LLMProvider

        switch mode {
        case .localOnly:
            result = try await ollama.format(text: trimmed)
            provider = .ollama
        case .geminiOnly:
            guard let gemini else { throw AppError.notConfigured("Gemini API Key Missing") }
            result = try await gemini.format(text: trimmed)
            provider = .gemini
        case .groqOnly:
            guard let groq else { throw AppError.notConfigured("Groq API Key Missing") }
            result = try await groq.format(text: trimmed)
            provider = .groq
        case .openAIOnly:
            guard let openAI else { throw AppError.notConfigured("OpenAI API Key Missing") }
            result = try await openAI.format(text: trimmed)
            provider = .openAI
        case .autoFallback:
            let preferGemini = Self.isLongForm(
                transcript: fullTranscript,
                durationSeconds: utteranceDurationSeconds
            )
            (result, provider, notes) = try await autoFormat(trimmed, preferGeminiFirst: preferGemini)
            notes = extraNotes + notes
        }

        await recordUsage?(provider)
        return FormatResult(text: Self.sanitize(result), provider: provider, notes: notes)
    }

    /// Long form → Gemini first (accuracy). Short form → Groq first (speed).
    /// Prefer the mic-capture clock when available so a dense short phrase
    /// (many words in under 7s) does not get routed to slower Gemini.
    static func isLongForm(transcript: String, durationSeconds: TimeInterval) -> Bool {
        if durationSeconds > Constants.Formatting.longFormAudioSeconds {
            return true
        }
        if durationSeconds > 0 {
            return false
        }
        // Duration unknown — use text proxies.
        let words = transcript
            .split { $0.isWhitespace || $0.isNewline }
            .filter { !$0.isEmpty }
            .count
        let chars = transcript.count
        if words >= Constants.Formatting.longFormMinWords { return true }
        if chars >= Constants.Formatting.longFormMinCharacters { return true }
        return false
    }

    /// Prefer sentence boundaries; fall back to hard splits for run-on speech.
    static func splitForFormatting(_ text: String, maxCharacters: Int) -> [String] {
        guard text.count > maxCharacters else { return [text] }

        var chunks: [String] = []
        var current = ""

        for sentence in Self.sentences(in: text) {
            if current.isEmpty {
                current = sentence
            } else if current.count + 1 + sentence.count <= maxCharacters {
                current += " " + sentence
            } else {
                chunks.append(current)
                if sentence.count <= maxCharacters {
                    current = sentence
                } else {
                    var rest = sentence
                    while rest.count > maxCharacters {
                        let idx = rest.index(rest.startIndex, offsetBy: maxCharacters)
                        chunks.append(String(rest[..<idx]))
                        rest = String(rest[idx...])
                    }
                    current = rest
                }
            }
        }
        if !current.isEmpty {
            chunks.append(current)
        }
        return chunks.isEmpty ? [text] : chunks
    }

    /// Split on `.?!` followed by whitespace, keeping the terminator with the sentence.
    private static func sentences(in text: String) -> [String] {
        var result: [String] = []
        var start = text.startIndex
        var i = text.startIndex
        while i < text.endIndex {
            let ch = text[i]
            let next = text.index(after: i)
            if (ch == "." || ch == "!" || ch == "?"),
               next < text.endIndex,
               text[next].isWhitespace {
                let end = next
                let piece = text[start..<end].trimmingCharacters(in: .whitespacesAndNewlines)
                if !piece.isEmpty { result.append(piece) }
                // Skip whitespace after the terminator.
                var j = next
                while j < text.endIndex, text[j].isWhitespace {
                    j = text.index(after: j)
                }
                start = j
                i = j
                continue
            }
            i = next
        }
        let tail = text[start...].trimmingCharacters(in: .whitespacesAndNewlines)
        if !tail.isEmpty { result.append(tail) }
        return result.isEmpty ? [text] : result
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

        // Models sometimes reply with meta text instead of staying silent.
        let lower = output.lowercased()
        if lower.contains("no text to process")
            || lower == "no text"
            || lower.hasPrefix("there is no text")
            || lower.hasPrefix("nothing to process")
            || lower.hasPrefix("no speech") {
            return ""
        }
        return output
    }

    /// Auto order: Gemini-first (long) or Groq-first (short), then the other, OpenAI, Ollama.
    private func autoFormat(
        _ text: String,
        preferGeminiFirst: Bool
    ) async throws -> (String, LLMProvider, [String]) {
        var notes: [String] = []
        let words = text.split { $0.isWhitespace || $0.isNewline }.filter { !$0.isEmpty }.count
        if preferGeminiFirst {
            notes.append(
                String(
                    format: "Auto route: long-form (%.1fs / %d words) → Gemini first",
                    utteranceDurationSeconds,
                    words
                )
            )
            DiagnosticLog.write(
                String(format: "format route=gemini-first duration=%.1fs words=%d", utteranceDurationSeconds, words)
            )
        } else {
            notes.append(
                String(
                    format: "Auto route: short-form (%.1fs / %d words) → Groq first",
                    utteranceDurationSeconds,
                    words
                )
            )
            DiagnosticLog.write(
                String(format: "format route=groq-first duration=%.1fs words=%d", utteranceDurationSeconds, words)
            )
        }

        let cloudOrder: [LLMProvider] = preferGeminiFirst
            ? [.gemini, .groq, .openAI]
            : [.groq, .gemini, .openAI]

        for provider in cloudOrder {
            switch provider {
            case .gemini:
                if let gemini {
                    do {
                        return (try await gemini.format(text: text), .gemini, notes)
                    } catch let error where Self.shouldFallback(error) {
                        notes.append("Gemini unavailable (\(Self.shortReason(error))); tried next provider")
                        AppLogger.llm.warning(
                            "Gemini unavailable; trying next — \(error.localizedDescription, privacy: .public)"
                        )
                    }
                } else {
                    notes.append("Gemini not configured; tried next provider")
                }
            case .groq:
                if let groq {
                    do {
                        return (try await groq.format(text: text), .groq, notes)
                    } catch let error where Self.shouldFallback(error) {
                        notes.append("Groq unavailable (\(Self.shortReason(error))); tried next provider")
                        AppLogger.llm.warning(
                            "Groq unavailable; trying next — \(error.localizedDescription, privacy: .public)"
                        )
                    }
                } else {
                    notes.append("Groq not configured; tried next provider")
                }
            case .openAI:
                if let openAI {
                    do {
                        return (try await openAI.format(text: text), .openAI, notes)
                    } catch let error where Self.shouldFallback(error) {
                        notes.append("OpenAI unavailable (\(Self.shortReason(error))); tried Ollama")
                        AppLogger.llm.warning(
                            "OpenAI unavailable; trying Ollama — \(error.localizedDescription, privacy: .public)"
                        )
                    }
                } else {
                    notes.append("OpenAI not configured; tried Ollama")
                }
            case .ollama:
                break
            }
        }

        do {
            return (try await ollama.format(text: text), .ollama, notes)
        } catch {
            if !notes.isEmpty {
                notes.append("Ollama also failed (\(Self.shortReason(error)))")
            }
            throw error
        }
    }

    private static func shortReason(_ error: Error) -> String {
        if let app = error as? AppError {
            switch app {
            case .llmTimeout: return "timed out"
            case .llmOffline: return "offline / unreachable"
            case .notConfigured: return "not configured"
            case .llmFailed(let msg): return msg
            default: return app.localizedDescription
            }
        }
        if let urlError = error as? URLError {
            switch urlError.code {
            case .timedOut: return "network timeout"
            case .notConnectedToInternet: return "no internet"
            case .cannotConnectToHost, .dnsLookupFailed: return "cannot reach host"
            case .networkConnectionLost: return "connection lost"
            default: return urlError.localizedDescription
            }
        }
        return error.localizedDescription
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
