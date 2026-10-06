import Foundation

/// Per-app rolling context — compact local memory, not full chat history.
///
/// LLM-facing payload is intentionally tiny (vocabulary only) so old topics
/// cannot pollute new dictation. Full recent snippets stay on-device only.
struct DictationSessionSummary: Codable, Equatable, Sendable {
    var currentTopic: String = ""
    var people: [String] = []
    var projects: [String] = []
    var acronyms: [String] = []
    var writingStyle: String = ""
    var recentIntent: String = ""
    var recentEntities: [String] = []
    /// Last few short dictation snippets (on-device only; not sent to LLM).
    var recentSnippets: [String] = []
    var updatedAt: Date = .distantPast

    enum CodingKeys: String, CodingKey {
        case currentTopic, people, projects, acronyms, writingStyle
        case recentIntent, recentEntities, recentSnippets, updatedAt
    }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        currentTopic = try c.decodeIfPresent(String.self, forKey: .currentTopic) ?? ""
        people = try c.decodeIfPresent([String].self, forKey: .people) ?? []
        projects = try c.decodeIfPresent([String].self, forKey: .projects) ?? []
        acronyms = try c.decodeIfPresent([String].self, forKey: .acronyms) ?? []
        writingStyle = try c.decodeIfPresent(String.self, forKey: .writingStyle) ?? ""
        recentIntent = try c.decodeIfPresent(String.self, forKey: .recentIntent) ?? ""
        recentEntities = try c.decodeIfPresent([String].self, forKey: .recentEntities) ?? []
        recentSnippets = try c.decodeIfPresent([String].self, forKey: .recentSnippets) ?? []
        updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt) ?? .distantPast
    }

    /// Debug / UI line — not sent to the model.
    var compactLine: String {
        var parts: [String] = []
        if !currentTopic.isEmpty { parts.append("topic=\(currentTopic)") }
        if !people.isEmpty { parts.append("people=\(people.prefix(4).joined(separator: "/"))") }
        if !acronyms.isEmpty { parts.append("acronyms=\(acronyms.prefix(6).joined(separator: "/"))") }
        if !recentIntent.isEmpty { parts.append("intent=\(recentIntent)") }
        parts.append("snippets=\(recentSnippets.count)")
        return parts.joined(separator: "; ")
    }

    /// Ultra-cheap LLM hint: vocabulary only (≈ a few dozen tokens max).
    /// Never includes prior transcript prose (that caused invented content).
    var llmVocabularyHint: String? {
        let terms = Array(
            (acronyms.prefix(8) + people.prefix(6) + recentEntities.prefix(4))
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        )
        let unique = Self.dedupe(terms, limit: 12)
        guard !unique.isEmpty else { return nil }
        return unique.joined(separator: ", ")
    }

    private static func dedupe(_ values: [String], limit: Int) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for value in values {
            let key = value.lowercased()
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            out.append(value)
            if out.count >= limit { break }
        }
        return out
    }
}

/// Window/site-scoped context sessions to avoid polluting unrelated work.
@MainActor
final class ContextSessionStore {
    static let shared = ContextSessionStore()

    /// Keep at most this many recent dictation snippets per session (on-device).
    static let maxRecentSnippets = 8
    /// Cap stored app/site sessions.
    static let maxSessions = 24

    private let defaults: UserDefaults
    private let storageKey = "dictation.contextSessions.v2"
    private var sessions: [String: DictationSessionSummary] = [:]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        load()
    }

    /// Prefetch at dictation start — local UserDefaults only, zero API tokens.
    func prefetch(sessionKey: String) -> DictationSessionSummary {
        let key = Self.normalize(sessionKey)
        return sessions[key] ?? DictationSessionSummary()
    }

    func summary(forSessionKey sessionKey: String) -> DictationSessionSummary {
        prefetch(sessionKey: sessionKey)
    }

    /// Legacy helper — prefer sessionKey from `FrontmostWritingContext`.
    func summary(forBundleID bundleID: String?) -> DictationSessionSummary {
        summary(forSessionKey: bundleID ?? "unknown")
    }

    func record(
        sessionKey: String,
        intent: DictationIntent,
        transcript: String,
        formatted: String
    ) {
        let key = Self.normalize(sessionKey)
        var summary = sessions[key] ?? DictationSessionSummary()
        summary.recentIntent = intent.rawValue
        summary.updatedAt = Date()

        let source = formatted.isEmpty ? transcript : formatted
        let topic = Self.guessTopic(from: source)
        if !topic.isEmpty { summary.currentTopic = topic }

        let people = Self.guessCapitalizedNames(from: source)
        summary.people = Self.mergeUnique(summary.people, people, limit: 10)

        let acronyms = Self.guessAcronyms(from: source)
        summary.acronyms = Self.mergeUnique(summary.acronyms, acronyms, limit: 12)

        let entities = Self.guessEntities(from: source)
        summary.recentEntities = Self.mergeUnique([], entities, limit: 8)

        let snippet = String(source.prefix(120))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !snippet.isEmpty {
            summary.recentSnippets.append(snippet)
            if summary.recentSnippets.count > Self.maxRecentSnippets {
                summary.recentSnippets = Array(summary.recentSnippets.suffix(Self.maxRecentSnippets))
            }
        }

        if source.contains("\n1.") || source.contains("\n-") || source.contains("\n•") {
            summary.writingStyle = "list"
        } else if intent == .email {
            summary.writingStyle = "email"
        } else if intent == .chat {
            summary.writingStyle = "chat"
        } else if source.count > 220 {
            summary.writingStyle = "longer prose"
        }

        sessions[key] = summary
        if sessions.count > Self.maxSessions {
            let trimmed = sessions.sorted { $0.value.updatedAt > $1.value.updatedAt }
                .prefix(Self.maxSessions)
            sessions = Dictionary(uniqueKeysWithValues: trimmed.map { ($0.key, $0.value) })
        }
        save()
    }

    /// Convenience matching older call sites.
    func record(
        bundleID: String?,
        intent: DictationIntent,
        transcript: String,
        formatted: String
    ) {
        record(
            sessionKey: bundleID ?? "unknown",
            intent: intent,
            transcript: transcript,
            formatted: formatted
        )
    }

    private func load() {
        if let data = defaults.data(forKey: storageKey),
           let decoded = try? JSONDecoder().decode([String: DictationSessionSummary].self, from: data) {
            sessions = decoded
            return
        }
        // One-time migrate from v1 if present.
        if let data = defaults.data(forKey: "dictation.contextSessions.v1"),
           let decoded = try? JSONDecoder().decode([String: DictationSessionSummary].self, from: data) {
            sessions = decoded
            save()
        }
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(sessions) else { return }
        defaults.set(data, forKey: storageKey)
    }

    private static func normalize(_ sessionKey: String) -> String {
        let raw = sessionKey.trimmingCharacters(in: .whitespacesAndNewlines)
        return raw.isEmpty ? "unknown" : raw.lowercased()
    }

    private static func guessTopic(from text: String) -> String {
        let line = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? text
        let clipped = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard clipped.count >= 8 else { return "" }
        return String(clipped.prefix(60))
    }

    private static func guessCapitalizedNames(from text: String) -> [String] {
        text.split(whereSeparator: { $0.isWhitespace || $0.isNewline || $0.isPunctuation })
            .map(String.init)
            .filter { token in
                guard token.count >= 2, token.count <= 24 else { return false }
                guard token.first?.isUppercase == true else { return false }
                let lower = token.lowercased()
                let stop: Set<String> = [
                    "i", "i'm", "the", "a", "an", "and", "or", "to", "for", "of", "in", "on",
                    "thanks", "that", "this", "first", "second", "third"
                ]
                return !stop.contains(lower)
            }
    }

    private static func guessAcronyms(from text: String) -> [String] {
        text.split(whereSeparator: { $0.isWhitespace || $0.isNewline || $0.isPunctuation })
            .map(String.init)
            .filter { token in
                token.count >= 2 && token.count <= 6 && token.uppercased() == token
                    && token.unicodeScalars.allSatisfy { CharacterSet.letters.contains($0) }
            }
    }

    private static func guessEntities(from text: String) -> [String] {
        Array(guessCapitalizedNames(from: text).prefix(6))
    }

    private static func mergeUnique(_ existing: [String], _ incoming: [String], limit: Int) -> [String] {
        var seen = Set(existing.map { $0.lowercased() })
        var out = existing
        for item in incoming {
            let key = item.lowercased()
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            out.append(item)
            if out.count >= limit { break }
        }
        return Array(out.suffix(limit))
    }
}
