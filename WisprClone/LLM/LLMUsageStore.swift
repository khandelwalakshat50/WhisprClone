import Combine
import Foundation

enum LLMProvider: String, CaseIterable, Codable, Sendable {
    case gemini
    case ollama
    case groq
    case openAI

    var displayName: String {
        switch self {
        case .gemini: return "Gemini"
        case .ollama: return "Ollama"
        case .groq: return "Groq"
        case .openAI: return "OpenAI"
        }
    }

    var detail: String {
        switch self {
        case .gemini: return "Cloud API key · Priority"
        case .ollama: return "Local · No API key"
        case .groq: return "Cloud API key"
        case .openAI: return "Cloud API key"
        }
    }

    var symbolName: String {
        switch self {
        case .gemini: return "sparkles"
        case .ollama: return "desktopcomputer"
        case .groq: return "bolt.fill"
        case .openAI: return "cloud.fill"
        }
    }
}

/// Persists privacy-safe provider usage. It stores only provider names and
/// timestamps—never API keys, transcript text, or generated content.
@MainActor
final class LLMUsageStore: ObservableObject {
    struct Event: Codable, Identifiable, Sendable {
        let id: UUID
        let provider: LLMProvider
        let timestamp: Date
    }

    static let rollingWindow: TimeInterval = 48 * 60 * 60

    @Published private(set) var events: [Event]

    private let defaults: UserDefaults
    private let storageKey = "llmProviderUsageEvents"
    private let retention: TimeInterval = 30 * 24 * 60 * 60

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: storageKey),
           let decoded = try? JSONDecoder().decode([Event].self, from: data) {
            events = decoded
        } else {
            events = []
        }
        pruneAndSave()
    }

    func record(_ provider: LLMProvider, at date: Date = .now) {
        events.append(Event(id: UUID(), provider: provider, timestamp: date))
        pruneAndSave()
        AppLogger.llm.info("Recorded successful provider usage: \(provider.displayName, privacy: .public)")
    }

    func count(for provider: LLMProvider, now: Date = .now) -> Int {
        let cutoff = now.addingTimeInterval(-Self.rollingWindow)
        return events.lazy.filter { $0.provider == provider && $0.timestamp >= cutoff }.count
    }

    func lastUsed(for provider: LLMProvider, now: Date = .now) -> Date? {
        let cutoff = now.addingTimeInterval(-Self.rollingWindow)
        return events
            .lazy
            .filter { $0.provider == provider && $0.timestamp >= cutoff }
            .map(\.timestamp)
            .max()
    }

    var totalInRollingWindow: Int {
        let cutoff = Date.now.addingTimeInterval(-Self.rollingWindow)
        return events.lazy.filter { $0.timestamp >= cutoff }.count
    }

    var mostRecentlyUsedProvider: LLMProvider? {
        let cutoff = Date.now.addingTimeInterval(-Self.rollingWindow)
        return events
            .filter { $0.timestamp >= cutoff }
            .max(by: { $0.timestamp < $1.timestamp })?
            .provider
    }

    func clear() {
        events = []
        defaults.removeObject(forKey: storageKey)
    }

    private func pruneAndSave() {
        let cutoff = Date.now.addingTimeInterval(-retention)
        events.removeAll { $0.timestamp < cutoff }
        if let data = try? JSONEncoder().encode(events) {
            defaults.set(data, forKey: storageKey)
        }
    }
}
