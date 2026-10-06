import Foundation

/// Growing personal vocabulary for ASR keyterms + LLM preservation hints.
@MainActor
final class PersonalDictionaryStore {
    static let shared = PersonalDictionaryStore()

    private let defaults: UserDefaults
    private let storageKey = "dictation.personalDictionary.v1"
    private(set) var terms: [String] = []

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        terms = defaults.stringArray(forKey: storageKey) ?? []
    }

    func allTerms(includingConfiguredBias bias: String) -> [String] {
        let configured = bias
            .split { $0 == "," || $0.isNewline }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return Self.merge(configured + terms, limit: 100)
    }

    func learn(from formatted: String) {
        let candidates = formatted
            .split(whereSeparator: { $0.isWhitespace || $0.isNewline || $0.isPunctuation })
            .map(String.init)
            .filter { token in
                guard (3...28).contains(token.count) else { return false }
                // Prefer proper nouns / acronyms.
                if token.uppercased() == token,
                   token.unicodeScalars.allSatisfy({ CharacterSet.letters.contains($0) }) {
                    return true
                }
                return token.first?.isUppercase == true
                    && token.dropFirst().contains(where: \.isLowercase)
            }
        guard !candidates.isEmpty else { return }
        terms = Self.merge(terms + candidates, limit: 120)
        defaults.set(terms, forKey: storageKey)
    }

    private static func merge(_ values: [String], limit: Int) -> [String] {
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
