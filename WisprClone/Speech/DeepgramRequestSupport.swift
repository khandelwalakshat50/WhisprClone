import Foundation

/// Shared Deepgram query helpers — keeps HTTP + live WebSocket requests valid.
enum DeepgramRequestSupport {
    /// Reject corrupted / dictated model strings (e.g. "re a") and fall back to Nova-3.
    static func sanitizedModel(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let folded = trimmed.lowercased()
        guard !folded.isEmpty else { return Constants.Speech.defaultDeepgramModel }

        let allowedPrefixes = ["nova-", "nova2", "nova3", "flux", "enhanced", "base", "whisper-"]
        if allowedPrefixes.contains(where: { folded.hasPrefix($0) })
            || folded == "nova-3"
            || folded == "nova-2"
            || folded.hasPrefix("nova-3") {
            return trimmed
        }

        // Common accidental free-text corruption from the Settings field.
        DiagnosticLog.write(
            "deepgram model invalid \"\(trimmed)\" — resetting to \(Constants.Speech.defaultDeepgramModel)"
        )
        return Constants.Speech.defaultDeepgramModel
    }

    static func supportsKeyterm(_ model: String) -> Bool {
        let folded = sanitizedModel(model).lowercased()
        return folded.hasPrefix("nova-3") || folded.hasPrefix("flux")
    }

    /// Keyterms only for Nova-3 / Flux. Cap + drop stopwords so URLs stay valid.
    static func keyterms(from bias: String, model: String, limit: Int = 12) -> [String] {
        guard supportsKeyterm(model) else { return [] }
        let terms = bias
            .split { $0 == "," || $0.isNewline }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { term in
                guard term.count >= 2 else { return false }
                return !stopwords.contains(term.lowercased())
            }
        var seen = Set<String>()
        var unique: [String] = []
        for term in terms {
            let key = term.lowercased()
            if seen.insert(key).inserted {
                unique.append(term)
            }
            if unique.count >= limit { break }
        }
        return unique
    }

    private static let stopwords: Set<String> = [
        "a", "an", "the", "and", "or", "but", "if", "then", "so", "to", "of", "in",
        "on", "for", "with", "at", "by", "from", "as", "is", "are", "was", "were",
        "be", "been", "this", "that", "these", "those", "it", "its", "you", "your",
        "we", "our", "they", "them", "i", "me", "my", "how", "what", "when", "where",
        "why", "who", "can", "could", "would", "should", "will", "just", "also",
        "very", "really", "basically", "actually", "like", "okay", "ok", "yes", "no",
        "now", "one", "two", "there", "here", "let", "make", "use", "add", "start",
        "run", "update", "manage", "provide", "follow", "followed", "difference",
        "determine", "clarify", "hello", "thanks", "thank", "please"
    ]
}
