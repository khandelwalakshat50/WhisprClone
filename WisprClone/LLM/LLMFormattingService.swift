import Foundation

/// Result of an LLM formatting pass, including which provider won and any
/// fallback / network notes useful for History diagnostics.
struct FormatResult: Sendable {
    let text: String
    let provider: LLMProvider
    let notes: [String]
    var intent: DictationIntent = .plain
    var level: FormattingLevel = .preserve
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
        try await formatDetailed(FormattingRequest(text: text)).text
    }

    func formatDetailed(text: String) async throws -> FormatResult {
        try await formatDetailed(FormattingRequest(text: text, utteranceDurationSeconds: utteranceDurationSeconds))
    }

    func formatDetailed(_ request: FormattingRequest) async throws -> FormatResult {
        var request = request
        if request.utteranceDurationSeconds <= 0, utteranceDurationSeconds > 0 {
            request.utteranceDurationSeconds = utteranceDurationSeconds
        }

        let trimmed = request.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return FormatResult(text: "", provider: .ollama, notes: ["skipped: empty transcript"])
        }

        let app = AppFormattingProfile.resolve(
            bundleID: request.targetBundleID,
            appName: request.targetAppName,
            windowTitle: request.targetWindowTitle,
            siteHint: request.siteHint
        )
        let analysis = DictationIntelligence.analyze(
            transcript: trimmed,
            app: app,
            asrConfidence: request.asrConfidence
        )

        if analysis.skipLLM {
            DiagnosticLog.write(
                "llm skip intelligence intent=\(analysis.intent.rawValue) level=\(analysis.level.rawValue) chars=\(trimmed.count)"
            )
            return FormatResult(
                text: trimmed,
                provider: .groq,
                notes: ["skipped LLM: high-confidence / already clean"],
                intent: analysis.intent,
                level: analysis.level
            )
        }

        // Legacy clean check as a secondary fast path for plain preserve.
        if analysis.level == .preserve,
           analysis.intent == .plain || analysis.intent == .chat,
           Self.looksAlreadyClean(trimmed) {
            DiagnosticLog.write("llm skip already-clean chars=\(trimmed.count)")
            return FormatResult(
                text: trimmed,
                provider: .groq,
                notes: ["skipped LLM: transcript already clean"],
                intent: analysis.intent,
                level: analysis.level
            )
        }

        let systemPrompt = LLMPromptLibrary.systemPrompt(
            level: analysis.level,
            intent: analysis.intent,
            app: app
        )
        let userMessage = LLMPromptLibrary.userMessage(
            transcript: trimmed,
            appName: request.targetAppName,
            level: analysis.level,
            intent: analysis.intent,
            sessionSummary: request.sessionSummary,
            personalTerms: request.personalTerms
        )

        DiagnosticLog.write(
            "llm intelligence intent=\(analysis.intent.rawValue) level=\(analysis.level.rawValue) app=\(app.id)"
        )

        let pieces = Self.splitForFormatting(trimmed, maxCharacters: Constants.Formatting.maxChunkCharacters)
        if pieces.count == 1 {
            var result = try await formatSingle(
                pieces[0],
                routingTranscript: trimmed,
                preferLongFormOverride: nil,
                extraNotes: [
                    "intent=\(analysis.intent.rawValue)",
                    "level=\(analysis.level.rawValue)",
                    "app=\(app.id)"
                ],
                systemPrompt: systemPrompt,
                userMessage: userMessage,
                durationSeconds: request.utteranceDurationSeconds
            )
            result.intent = analysis.intent
            result.level = analysis.level
            return Self.finalizeOutput(result, original: trimmed)
        }

        // Long dictation: parallel long-form-route pieces (OpenAI first, then Gemini).
        // Per-piece prompts stay Level-1 preserve to avoid structural drift mid-split.
        var notes = [
            "LLM split into \(pieces.count) chunks for long dictation (parallel OpenAI-first)",
            "intent=\(analysis.intent.rawValue)",
            "level=\(analysis.level.rawValue)"
        ]
        let pieceSystem = LLMPromptLibrary.systemPrompt(level: .preserve, intent: analysis.intent, app: app)
        let appName = request.targetAppName
        let sessionSummary = request.sessionSummary
        let personalTerms = request.personalTerms
        let durationSeconds = request.utteranceDurationSeconds
        let pieceIntent = analysis.intent
        let results: [(Int, FormatResult)] = try await withThrowingTaskGroup(of: (Int, FormatResult).self) { group in
            for (i, piece) in pieces.enumerated() {
                let pieceText = piece
                group.addTask {
                    let pieceUser = LLMPromptLibrary.userMessage(
                        transcript: pieceText,
                        appName: appName,
                        level: .preserve,
                        intent: pieceIntent,
                        sessionSummary: sessionSummary,
                        personalTerms: personalTerms
                    )
                    let part = try await self.formatSingle(
                        pieceText,
                        routingTranscript: pieceText,
                        preferLongFormOverride: true,
                        extraNotes: [],
                        systemPrompt: pieceSystem,
                        userMessage: pieceUser,
                        durationSeconds: durationSeconds
                    )
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

        return Self.finalizeOutput(
            FormatResult(
                text: formattedParts.joined(separator: "\n\n"),
                provider: provider,
                notes: notes,
                intent: analysis.intent,
                level: analysis.level
            ),
            original: trimmed
        )
    }

    /// Drop assistant-style answers that inflate a dictated question into a reply.
    private static func finalizeOutput(_ result: FormatResult, original: String) -> FormatResult {
        let guarded = rejectAssistantAnswer(original: original, formatted: result.text, level: result.level)
        guard guarded != result.text else { return result }
        DiagnosticLog.write(
            "llm rejected answer expansion in=\(original.count) out=\(result.text.count) → kept \(guarded.count)"
        )
        return FormatResult(
            text: guarded,
            provider: result.provider,
            notes: result.notes + ["rejected LLM answer expansion; kept transcript polish only"],
            intent: result.intent,
            level: result.level
        )
    }

    /// If the model answered a dictated question, fall back to a light local polish of the transcript.
    private static func rejectAssistantAnswer(
        original: String,
        formatted: String,
        level: FormattingLevel
    ) -> String {
        let source = original.trimmingCharacters(in: .whitespacesAndNewlines)
        let output = formatted.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !source.isEmpty, !output.isEmpty else { return formatted }
        // Explicit rewrite may legitimately expand — still block pure Q→A.
        let lowerOut = output.lowercased()
        let lowerIn = source.lowercased()

        let assistantOpeners = [
            "sure,", "sure!", "of course", "absolutely", "here's", "here is", "here are",
            "the answer is", "you can ", "you should ", "you could ", "i'd recommend",
            "i recommend", "let me explain", "let me help", "to do this", "to solve this",
            "the solution is", "try this", "one way to", "there are several"
        ]
        let startsLikeAssistant = assistantOpeners.contains { lowerOut.hasPrefix($0) }

        let looksLikeQuestion =
            source.contains("?")
            || lowerIn.hasPrefix("how ")
            || lowerIn.hasPrefix("what ")
            || lowerIn.hasPrefix("why ")
            || lowerIn.hasPrefix("when ")
            || lowerIn.hasPrefix("where ")
            || lowerIn.hasPrefix("who ")
            || lowerIn.hasPrefix("can you ")
            || lowerIn.hasPrefix("could you ")
            || lowerIn.hasPrefix("please ")
            || lowerIn.contains(" how do i ")
            || lowerIn.contains(" how can i ")
            || lowerIn.contains(" what is ")
            || lowerIn.contains(" what's ")

        let expandedFar = output.count > max(Int(Double(source.count) * 1.55) + 48, source.count + 80)
        let muchLonger = output.count > source.count * 2 + 60

        if startsLikeAssistant && (looksLikeQuestion || muchLonger) {
            return lightLocalPolish(source)
        }
        if level != .rewrite, looksLikeQuestion, expandedFar {
            return lightLocalPolish(source)
        }
        if level != .rewrite, muchLonger, looksLikeQuestion {
            return lightLocalPolish(source)
        }
        return formatted
    }

    private static func lightLocalPolish(_ text: String) -> String {
        var t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        while t.contains("  ") { t = t.replacingOccurrences(of: "  ", with: " ") }
        guard let first = t.first else { return t }
        return first.uppercased() + t.dropFirst()
    }

    private func formatSingle(
        _ trimmed: String,
        routingTranscript: String,
        preferLongFormOverride: Bool?,
        extraNotes: [String],
        systemPrompt: String,
        userMessage: String,
        durationSeconds: TimeInterval
    ) async throws -> FormatResult {
        var notes = extraNotes
        let result: String
        let provider: LLMProvider
        let duration = durationSeconds > 0 ? durationSeconds : utteranceDurationSeconds

        switch mode {
        case .localOnly:
            result = try await ollama.format(text: trimmed, systemPrompt: systemPrompt, userMessage: userMessage)
            provider = .ollama
        case .geminiOnly:
            guard let gemini else { throw AppError.notConfigured("Gemini API Key Missing") }
            result = try await gemini.format(text: trimmed, systemPrompt: systemPrompt, userMessage: userMessage)
            provider = .gemini
        case .groqOnly:
            guard let groq else { throw AppError.notConfigured("Groq API Key Missing") }
            result = try await groq.format(text: trimmed, systemPrompt: systemPrompt, userMessage: userMessage)
            provider = .groq
        case .openAIOnly:
            guard let openAI else { throw AppError.notConfigured("OpenAI API Key Missing") }
            result = try await openAI.format(text: trimmed, systemPrompt: systemPrompt, userMessage: userMessage)
            provider = .openAI
        case .autoFallback:
            let longForm = preferLongFormOverride ?? Self.isLongForm(
                transcript: routingTranscript,
                durationSeconds: duration
            )
            (result, provider, notes) = try await autoFormat(
                trimmed,
                longForm: longForm,
                systemPrompt: systemPrompt,
                userMessage: userMessage,
                durationSeconds: duration
            )
            notes = extraNotes + notes
        }

        await recordUsage?(provider)
        return FormatResult(text: Self.sanitize(result), provider: provider, notes: notes)
    }

    /// Longer than ~12s → OpenAI first. Shorter → Groq first.
    static func isLongForm(transcript: String, durationSeconds: TimeInterval) -> Bool {
        if durationSeconds > Constants.Formatting.longFormAudioSeconds {
            return true
        }
        if durationSeconds > 0 {
            return false
        }
        let words = transcript
            .split { $0.isWhitespace || $0.isNewline }
            .filter { !$0.isEmpty }
            .count
        let chars = transcript.count
        if words >= Constants.Formatting.longFormMinWords { return true }
        if chars >= Constants.Formatting.longFormMinCharacters { return true }
        return false
    }

    /// Conservative: only skip when ASR already looks like typed prose.
    static func looksAlreadyClean(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (2...Constants.Formatting.skipLLMMaxCharacters).contains(t.count) else { return false }
        guard t.first?.isUppercase == true else { return false }
        guard t.hasSuffix(".") || t.hasSuffix("?") || t.hasSuffix("!") else { return false }

        let padded = " \(t.lowercased()) "
        let fillers = [" um ", " uh ", " er ", " ah ", " you know ", " sort of ", " kind of ", " like "]
        if fillers.contains(where: { padded.contains($0) }) { return false }
        return true
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

    /// Auto order — long: OpenAI → Groq → Gemini; short: Groq → OpenAI → Gemini; then Ollama.
    private func autoFormat(
        _ text: String,
        longForm: Bool,
        systemPrompt: String,
        userMessage: String,
        durationSeconds: TimeInterval
    ) async throws -> (String, LLMProvider, [String]) {
        var notes: [String] = []
        let words = text.split { $0.isWhitespace || $0.isNewline }.filter { !$0.isEmpty }.count
        if longForm {
            notes.append(
                String(
                    format: "Auto route: long-form (%.1fs / %d words) → OpenAI first",
                    durationSeconds,
                    words
                )
            )
            DiagnosticLog.write(
                String(format: "format route=openai-first duration=%.1fs words=%d", durationSeconds, words)
            )
        } else {
            notes.append(
                String(
                    format: "Auto route: short-form (%.1fs / %d words) → Groq first",
                    durationSeconds,
                    words
                )
            )
            DiagnosticLog.write(
                String(format: "format route=groq-first duration=%.1fs words=%d", durationSeconds, words)
            )
        }

        // Gemini is last in both routes — it is the slowest provider in practice.
        let cloudOrder: [LLMProvider] = longForm
            ? [.openAI, .groq, .gemini]
            : [.groq, .openAI, .gemini]

        for provider in cloudOrder {
            let client: (any TextFormatter)?
            let name: String
            switch provider {
            case .gemini: client = gemini; name = "Gemini"
            case .groq: client = groq; name = "Groq"
            case .openAI: client = openAI; name = "OpenAI"
            case .ollama: continue
            }
            guard let client else {
                notes.append("\(name) not configured; tried next provider")
                continue
            }
            let started = ContinuousClock.now
            do {
                let output = try await Self.format(
                    with: client,
                    text: text,
                    systemPrompt: systemPrompt,
                    userMessage: userMessage
                )
                DiagnosticLog.write(
                    String(format: "llm %@ ok %.2fs", name, AppLogger.elapsedMilliseconds(since: started) / 1000)
                )
                return (output, provider, notes)
            } catch let error where Self.shouldFallback(error) {
                notes.append("\(name) unavailable (\(Self.shortReason(error))); tried next provider")
                DiagnosticLog.write(
                    String(
                        format: "llm %@ failed after %.2fs: %@",
                        name,
                        AppLogger.elapsedMilliseconds(since: started) / 1000,
                        Self.shortReason(error)
                    )
                )
                AppLogger.llm.warning(
                    "\(name, privacy: .public) unavailable; trying next — \(error.localizedDescription, privacy: .public)"
                )
            }
        }

        do {
            return (
                try await ollama.format(
                    text: text,
                    systemPrompt: systemPrompt,
                    userMessage: userMessage
                ),
                .ollama,
                notes
            )
        } catch {
            if !notes.isEmpty {
                notes.append("Ollama also failed (\(Self.shortReason(error)))")
            }
            throw error
        }
    }

    private static func format(
        with client: any TextFormatter,
        text: String,
        systemPrompt: String,
        userMessage: String
    ) async throws -> String {
        switch client {
        case let groq as GroqClient:
            return try await groq.format(text: text, systemPrompt: systemPrompt, userMessage: userMessage)
        case let openAI as OpenAIClient:
            return try await openAI.format(text: text, systemPrompt: systemPrompt, userMessage: userMessage)
        case let gemini as GeminiClient:
            return try await gemini.format(text: text, systemPrompt: systemPrompt, userMessage: userMessage)
        default:
            return try await client.format(text: text)
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
