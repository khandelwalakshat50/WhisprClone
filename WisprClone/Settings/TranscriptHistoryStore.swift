import Combine
import Foundation

/// Keeps the most recent transcripts so the user can re-copy text when a paste
/// into another app doesn't land. Stored locally in UserDefaults only.
///
/// This intentionally persists transcript *text* (unlike `LLMUsageStore`), which
/// the user explicitly requested for manual copy/paste recovery.
@MainActor
final class TranscriptHistoryStore: ObservableObject {
    /// Per-stage timings (seconds) measured after the user stops speaking.
    struct TimingBreakdown: Codable, Sendable, Equatable {
        var transcriptionSeconds: Double?
        var formattingSeconds: Double?
        var injectionSeconds: Double?
        /// Stop → paste (excludes time spent recording).
        var processingSeconds: Double?

        var slowestStage: String? {
            let stages: [(String, Double)] = [
                ("Transcription", transcriptionSeconds ?? 0),
                ("Formatting", formattingSeconds ?? 0),
                ("Paste", injectionSeconds ?? 0)
            ].filter { $0.1 > 0 }
            return stages.max(by: { $0.1 < $1.1 })?.0
        }
    }

    struct Entry: Codable, Identifiable, Sendable {
        let id: UUID
        let text: String
        let timestamp: Date
        let provider: LLMProvider?
        /// Speech engine + model used for transcription (e.g. "WhisperKit · base").
        let transcriptionModel: String?
        /// Seconds from the start of recording until text was pasted.
        let durationSeconds: Double?
        let timing: TimingBreakdown?
        /// Human-readable explanation of what made this run slow (or notes).
        let delayNote: String?

        init(
            id: UUID = UUID(),
            text: String,
            timestamp: Date = .now,
            provider: LLMProvider? = nil,
            transcriptionModel: String? = nil,
            durationSeconds: Double? = nil,
            timing: TimingBreakdown? = nil,
            delayNote: String? = nil
        ) {
            self.id = id
            self.text = text
            self.timestamp = timestamp
            self.provider = provider
            self.transcriptionModel = transcriptionModel
            self.durationSeconds = durationSeconds
            self.timing = timing
            self.delayNote = delayNote
        }
    }

    static let maxEntries = 10

    @Published private(set) var entries: [Entry]

    private let defaults: UserDefaults
    private let storageKey = "transcriptHistoryEntries"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: storageKey),
           let decoded = try? JSONDecoder().decode([Entry].self, from: data) {
            entries = Array(decoded.prefix(Self.maxEntries))
        } else {
            entries = []
        }
    }

    /// Inserts the newest transcript at the top and trims to `maxEntries`.
    func record(
        _ text: String,
        provider: LLMProvider? = nil,
        transcriptionModel: String? = nil,
        durationSeconds: Double? = nil,
        timing: TimingBreakdown? = nil,
        delayNote: String? = nil,
        at date: Date = .now
    ) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        entries.insert(
            Entry(
                text: trimmed,
                timestamp: date,
                provider: provider,
                transcriptionModel: transcriptionModel,
                durationSeconds: durationSeconds,
                timing: timing,
                delayNote: delayNote
            ),
            at: 0
        )
        if entries.count > Self.maxEntries {
            entries.removeLast(entries.count - Self.maxEntries)
        }
        save()
        AppLogger.pipeline.info("Recorded transcript in history (\(trimmed.count, privacy: .public) chars)")
    }

    func clear() {
        entries = []
        defaults.removeObject(forKey: storageKey)
    }

    /// Fills in duration / timing / delay note on the most recent entry after paste finishes.
    func updateLatestMetrics(
        durationSeconds: Double?,
        timing: TimingBreakdown?,
        delayNote: String?
    ) {
        guard !entries.isEmpty else { return }
        let latest = entries[0]
        entries[0] = Entry(
            id: latest.id,
            text: latest.text,
            timestamp: latest.timestamp,
            provider: latest.provider,
            transcriptionModel: latest.transcriptionModel,
            durationSeconds: durationSeconds ?? latest.durationSeconds,
            timing: timing ?? latest.timing,
            delayNote: delayNote ?? latest.delayNote
        )
        save()
    }

    private func save() {
        if let data = try? JSONEncoder().encode(entries) {
            defaults.set(data, forKey: storageKey)
        }
    }
}
