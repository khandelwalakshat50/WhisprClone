import Foundation

/// Deterministic newline repair when the model returns a spoken list as one line.
/// Zero tokens — runs after LLM sanitize.
enum StructurePostProcessor {

    static func apply(_ text: String, intent: DictationIntent, level: FormattingLevel) -> String {
        guard level == .structure || intent == .numberedSteps || intent == .taskList else {
            return text
        }
        var output = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !output.isEmpty else { return output }

        // Already structured.
        if output.contains("\n") && (output.contains("\n1.") || output.contains("\n- ") || output.contains("\n•")) {
            return output
        }

        output = normalizeSpokenEnumeration(output)
        output = ensureGreetingBreak(output)
        return output
    }

    /// Turn "… one is X, second is Y, and the third is Z" into a numbered list.
    private static func normalizeSpokenEnumeration(_ text: String) -> String {
        let lower = text.lowercased()
        let hasCues = (lower.contains("one is") || lower.contains("the first") || lower.contains("first is"))
            && (lower.contains("second is") || lower.contains("the second") || lower.contains("third is")
                || lower.contains("the third") || lower.contains("followed by"))
        guard hasCues else {
            // Still break "1. … 2. …" if flattened.
            return breakFlatNumberedMarkers(text)
        }

        // Split on spoken ordinals.
        let patterns = [
            #"(?i)(?:^|[,\s]+)(?:the\s+)?first(?:\s+one|\s+point|\s+is|:)\s*"#,
            #"(?i)(?:^|[,\s]+)one(?:\s+is|:)\s*"#,
            #"(?i)(?:^|[,\s]+)(?:the\s+)?second(?:\s+one|\s+point|\s+is|:)\s*"#,
            #"(?i)(?:^|[,\s]+)(?:and\s+)?(?:the\s+)?third(?:\s+one|\s+point|\s+is|:)\s*"#,
            #"(?i)(?:^|[,\s]+)(?:and\s+)?(?:the\s+)?fourth(?:\s+one|\s+point|\s+is|:)\s*"#
        ]

        var working = text
        // Find earliest first-item cue to separate intro.
        let firstCue = firstMatchRange(
            in: working,
            patterns: [
                #"(?i)(?:the\s+)?first(?:\s+one|\s+point|\s+is|:)\s+"#,
                #"(?i)\bone(?:\s+is|:)\s+"#
            ]
        )

        var intro = ""
        var body = working
        if let firstCue {
            intro = String(working[..<firstCue.lowerBound])
                .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ",")))
            body = String(working[firstCue.lowerBound...])
        }

        // Re-scan body with ordinal splits.
        var items: [String] = []
        let splitRegex = try? NSRegularExpression(
            pattern: #"(?i)(?:(?:the\s+)?first(?:\s+one|\s+point)?(?:\s+is|:)?|one(?:\s+is|:)|(?:the\s+)?second(?:\s+one|\s+point)?(?:\s+is|:)?|(?:and\s+)?(?:the\s+)?third(?:\s+one|\s+point)?(?:\s+is|:)?|(?:and\s+)?(?:the\s+)?fourth(?:\s+one|\s+point)?(?:\s+is|:)?)\s+"#
        )
        if let splitRegex {
            let ns = body as NSString
            let matches = splitRegex.matches(in: body, range: NSRange(location: 0, length: ns.length))
            if matches.count >= 2 {
                for (i, match) in matches.enumerated() {
                    let start = match.range.location + match.range.length
                    let end = (i + 1 < matches.count) ? matches[i + 1].range.location : ns.length
                    guard end > start else { continue }
                    var piece = ns.substring(with: NSRange(location: start, length: end - start))
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    while piece.hasSuffix(",") || piece.hasSuffix(".") || piece.hasSuffix(";") {
                        // Keep sentence-ending period on last item only.
                        if piece.count > 1, piece.hasSuffix("."), i == matches.count - 1 { break }
                        piece = String(piece.dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
                    }
                    // Strip trailing "and"
                    if piece.lowercased().hasPrefix("and ") {
                        piece = String(piece.dropFirst(4)).trimmingCharacters(in: .whitespacesAndNewlines)
                    }
                    if let andRange = piece.lowercased().range(of: " and ", options: .backwards),
                       andRange.upperBound == piece.endIndex {
                        piece = String(piece[..<andRange.lowerBound])
                    }
                    // Remove trailing connective before next ordinal already split.
                    if piece.lowercased().hasSuffix(" and") {
                        piece = String(piece.dropLast(4)).trimmingCharacters(in: .whitespacesAndNewlines)
                    }
                    guard !piece.isEmpty else { continue }
                    items.append(piece)
                }
            }
        }

        guard items.count >= 2 else {
            return breakFlatNumberedMarkers(text)
        }

        var lines: [String] = []
        if !intro.isEmpty {
            var cleanedIntro = intro
            if !cleanedIntro.hasSuffix(".") && !cleanedIntro.hasSuffix(":") && !cleanedIntro.hasSuffix("!") {
                cleanedIntro += ":"
            }
            lines.append(cleanedIntro)
            lines.append("")
        }
        for (idx, item) in items.enumerated() {
            var cleaned = item.trimmingCharacters(in: .whitespacesAndNewlines)
            // Drop leading "and "
            if cleaned.lowercased().hasPrefix("and ") {
                cleaned = String(cleaned.dropFirst(4)).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            // Capitalize first letter
            if let first = cleaned.first {
                cleaned = String(first).uppercased() + cleaned.dropFirst()
            }
            lines.append("\(idx + 1). \(cleaned)")
        }
        return lines.joined(separator: "\n")
    }

    private static func breakFlatNumberedMarkers(_ text: String) -> String {
        guard !text.contains("\n") else { return text }
        let pattern = #"\s+([2-9]|1[0-9])\.\s+"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        let ns = text as NSString
        let mutable = NSMutableString(string: text)
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
        for match in matches.reversed() {
            guard match.numberOfRanges >= 2 else { continue }
            let num = ns.substring(with: match.range(at: 1))
            mutable.replaceCharacters(in: match.range, with: "\n\(num). ")
        }
        // Ensure "1." starts on its own line when preceded by prose.
        let withOne = mutable as String
        if let regex1 = try? NSRegularExpression(pattern: #"(?<=[.!?:,])\s+1\.\s+"#) {
            let out = NSMutableString(string: withOne)
            regex1.replaceMatches(
                in: out,
                range: NSRange(location: 0, length: out.length),
                withTemplate: "\n\n1. "
            )
            return out as String
        }
        return withOne
    }

    private static func ensureGreetingBreak(_ text: String) -> String {
        guard !text.contains("\n") else { return text }
        // "Dear X, rest..." → "Dear X,\n\nrest..."
        guard let regex = try? NSRegularExpression(
            pattern: #"(?i)^(dear\s+[^,]{1,40},)\s+"#
        ) else { return text }
        let ns = text as NSString
        guard let match = regex.firstMatch(in: text, range: NSRange(location: 0, length: ns.length))
        else { return text }
        let greeting = ns.substring(with: match.range(at: 1))
        let rest = ns.substring(from: match.range.location + match.range.length)
        return "\(greeting)\n\n\(rest)"
    }

    private static func firstMatchRange(in text: String, patterns: [String]) -> Range<String.Index>? {
        var best: Range<String.Index>?
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let ns = text as NSString
            guard let match = regex.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)),
                  let range = Range(match.range, in: text)
            else { continue }
            if best == nil || range.lowerBound < best!.lowerBound {
                best = range
            }
        }
        return best
    }
}
