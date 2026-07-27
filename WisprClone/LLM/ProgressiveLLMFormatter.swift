import Foundation

/// Formats live ASR chunk texts as soon as Whisper returns them, so most
/// “Refining” work overlaps with speaking / remaining transcription.
///
/// Each ~4–5s live chunk is formatted on the fast Groq path (short system
/// prompt + instant model). For a 30s utterance that means ~6 small calls
/// that finish *during* speech — stop-to-paste waits mostly for the last one.
final class ProgressiveLLMFormatter: @unchecked Sendable {
    private let formatter: LLMFormattingService
    private let lock = NSLock()
    private var tasks: [Int: Task<FormatResult?, Never>] = [:]
    private var started = 0

    /// Chunk-local routing always prefers Groq in Auto mode (each live chunk
    /// is short-form), which is the main latency win for long dictation.
    init(formatter: LLMFormattingService) {
        var copy = formatter
        // Force short-form routing regardless of parent utterance length.
        copy.utteranceDurationSeconds = 0
        self.formatter = copy
    }

    func ingest(index: Int, text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        lock.lock()
        defer { lock.unlock() }

        if tasks[index] != nil { return }

        started += 1
        let formatter = self.formatter
        let task = Task<FormatResult?, Never> {
            do {
                let result = try await formatter.formatDetailed(text: trimmed)
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

    /// Waits for every ingested chunk. Returns nil only if coverage is unusable
    /// so the caller can fall back to full-transcript formatting.
    func finish() async -> FormatResult? {
        let snapshot: [Int: Task<FormatResult?, Never>] = {
            lock.lock()
            defer { lock.unlock() }
            return tasks
        }()

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
        var notes = [
            "Progressive LLM · \(ordered.count)/\(snapshot.count) chunk(s) overlapped with speech"
        ]
        for (index, result) in ordered {
            notes.append(contentsOf: result.notes.map { "chunk \(index): \($0)" })
        }
        DiagnosticLog.write(
            "progressive LLM done chunks=\(ordered.count) chars=\(text.count) provider=\(provider.rawValue)"
        )
        return FormatResult(text: text, provider: provider, notes: notes)
    }

    var didStart: Bool {
        lock.lock()
        defer { lock.unlock() }
        return started > 0
    }

    var startedCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return started
    }
}
