import Combine
import Foundation

/// Keeps the most recent transcripts so the user can re-copy text when a paste
/// into another app doesn't land. Stored locally in UserDefaults only.
///
/// This intentionally persists transcript *text* (unlike `LLMUsageStore`), which
/// the user explicitly requested for manual copy/paste recovery.
@MainActor
final class TranscriptHistoryStore: ObservableObject {
    struct Entry: Codable, Identifiable, Sendable {
        let id: UUID
        let text: String
        let timestamp: Date
        let provider: LLMProvider?
        /// Speech engine + model used for transcription (e.g. "WhisperKit · base").
        let transcriptionModel: String?
        /// Seconds from the start of recording until text was pasted.
        let durationSeconds: Double?

        init(
            id: UUID = UUID(),
            text: String,
            timestamp: Date = .now,
            provider: LLMProvider? = nil,
            transcriptionModel: String? = nil,
            durationSeconds: Double? = nil
        ) {
            self.id = id
            self.text = text
            self.timestamp = timestamp
            self.provider = provider
            self.transcriptionModel = transcriptionModel
            self.durationSeconds = durationSeconds
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
                durationSeconds: durationSeconds
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

    /// Sets duration on the most recent entry (called after injection completes or fails).
    func updateLatestDuration(_ durationSeconds: Double) {
        guard !entries.isEmpty else { return }
        let latest = entries[0]
        entries[0] = Entry(
            id: latest.id,
            text: latest.text,
            timestamp: latest.timestamp,
            provider: latest.provider,
            transcriptionModel: latest.transcriptionModel,
            durationSeconds: durationSeconds
        )
        save()
    }

    private func save() {
        if let data = try? JSONEncoder().encode(entries) {
            defaults.set(data, forKey: storageKey)
        }
    }
}
