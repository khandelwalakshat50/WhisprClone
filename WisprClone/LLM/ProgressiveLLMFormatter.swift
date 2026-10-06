import Foundation

/// Formats live ASR while the user is still speaking — **Groq short-form only**.
///
/// Auto mode restricts Groq to ≈4–5s (one live chunk). As soon as a second
/// chunk arrives, progressive work is abandoned so the final pass can use
/// the long-form route (OpenAI, then Gemini).
final class ProgressiveLLMFormatter: @unchecked Sendable {
    private let formatter: LLMFormattingService
    private let baseRequest: FormattingRequest
    private let lock = NSLock()
    private var tasks: [Int: Task<FormatResult?, Never>] = [:]
    private var started = 0
    private var abandoned = false

    /// Chunk-local routing prefers Groq (short-form) for the single allowed chunk.
    init(formatter: LLMFormattingService, baseRequest: FormattingRequest = FormattingRequest(text: "")) {
        var copy = formatter
        copy.utteranceDurationSeconds = 0
        self.formatter = copy
        var request = baseRequest
        request.utteranceDurationSeconds = 0
        self.baseRequest = request
    }

    func ingest(index: Int, text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        lock.lock()
        defer { lock.unlock() }

        if abandoned { return }
        if tasks[index] != nil { return }

        if tasks.count >= Constants.Formatting.progressiveMaxChunks {
            for task in tasks.values {
                task.cancel()
            }
            tasks.removeAll()
            abandoned = true
            DiagnosticLog.write(
                "progressive LLM abandoned at chunk #\(index); long-form single-shot next"
            )
            return
        }

        started += 1
        let formatter = self.formatter
        var request = baseRequest
        request.text = trimmed
        let task = Task<FormatResult?, Never> {
            do {
                let result = try await formatter.formatDetailed(request)
                DiagnosticLog.write(
                    "progressive LLM chunk #\(index) provider=\(result.provider.rawValue) chars=\(result.text.count)"
                )
                return result
            } catch {
                DiagnosticLog.write(
                    "progressive LLM chunk #\(index) failed: \(error.localizedDescription)"
                )
                return nil
            }
        }
        tasks[index] = task
    }

    /// Returns the single short Groq result, or nil to force a long-form single-shot.
    func finish() async -> FormatResult? {
        let (wasAbandoned, snapshot): (Bool, [Int: Task<FormatResult?, Never>]) = {
            lock.lock()
            defer { lock.unlock() }
            return (abandoned, tasks)
        }()

        if wasAbandoned {
            DiagnosticLog.write("progressive LLM finish skipped (multi-chunk → long-form path)")
            return nil
        }

        guard !snapshot.isEmpty else { return nil }

        var ordered: [(Int, FormatResult)] = []
        for index in snapshot.keys.sorted() {
            guard let task = snapshot[index] else { continue }
            guard let result = await task.value else {
                DiagnosticLog.write("progressive LLM incomplete at chunk #\(index); fallback")
                return nil
            }
            let cleaned = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleaned.isEmpty else {
                DiagnosticLog.write("progressive LLM empty at chunk #\(index); fallback")
                return nil
            }
            ordered.append((index, result))
        }

        guard !ordered.isEmpty, ordered.count == snapshot.count else { return nil }

        let text = ordered.map(\.1.text)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard !text.isEmpty else { return nil }

        let provider = ordered.last?.1.provider ?? .groq
        let intent = ordered.last?.1.intent ?? .plain
        let level = ordered.last?.1.level ?? .preserve
        var notes = [
            "Progressive LLM · \(ordered.count)/\(snapshot.count) short chunk(s) via Groq"
        ]
        for (index, result) in ordered {
            notes.append(contentsOf: result.notes.map { "chunk \(index): \($0)" })
        }
        DiagnosticLog.write(
            "progressive LLM done chunks=\(ordered.count) chars=\(text.count) provider=\(provider.rawValue)"
        )
        return FormatResult(
            text: text,
            provider: provider,
            notes: notes,
            intent: intent,
            level: level
        )
    }

    var didStart: Bool {
        lock.lock()
        defer { lock.unlock() }
        return started > 0 && !abandoned
    }

    var startedCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return started
    }
}
