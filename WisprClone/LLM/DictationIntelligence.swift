import Foundation

/// How aggressively the LLM may transform the transcript.
enum FormattingLevel: String, Sendable {
    /// Punctuation, capitalization, paragraphs, light filler removal. Preserve wording.
    case preserve
    /// Reorganize into lists / notes / steps without rewriting meaning.
    case structure
    /// Full rewrite — only when the user explicitly asks.
    case rewrite
}

/// Coarse intent for specialized prompts (heuristic, no extra LLM round-trip).
enum DictationIntent: String, Sendable {
    case plain
    case email
    case chat
    case meetingNotes
    case taskList
    case checklist
    case numberedSteps
    case shoppingList
    case documentation
    case technical
    case journal
    case brainstorm
}

/// Frontmost-app preferences that bias level + prompt tone.
struct AppFormattingProfile: Sendable {
    var id: String
    var preferShortParagraphs: Bool
    var allowBulletsFreely: Bool
    var allowMarkdownHeadings: Bool
    var preserveConversationalTone: Bool
    var treatAsTechnical: Bool
    var emailFriendly: Bool

    static func resolve(
        bundleID: String?,
        appName: String?,
        windowTitle: String? = nil,
        siteHint: String? = nil
    ) -> AppFormattingProfile {
        let bid = (bundleID ?? "").lowercased()
        let name = (appName ?? "").lowercased()
        let title = (windowTitle ?? "").lowercased()
        let site = (siteHint ?? "").lowercased()

        if bid.contains("cursor") || name.contains("cursor") || site == "cursor" {
            return AppFormattingProfile(
                id: "cursor",
                preferShortParagraphs: true,
                allowBulletsFreely: false,
                allowMarkdownHeadings: false,
                preserveConversationalTone: false,
                treatAsTechnical: true,
                emailFriendly: false
            )
        }
        if bid.contains("slack") || name.contains("slack") || site == "slack" || title.contains("slack") {
            return AppFormattingProfile(
                id: "slack",
                preferShortParagraphs: true,
                allowBulletsFreely: false,
                allowMarkdownHeadings: false,
                preserveConversationalTone: true,
                treatAsTechnical: false,
                emailFriendly: false
            )
        }
        // Gmail.com in Chrome/Safari: window title usually contains "Gmail".
        if site == "gmail" || site == "mail"
            || bid.contains("mail") || bid.contains("gmail")
            || name.contains("gmail") || name == "mail"
            || title.contains("gmail") || title.contains("mail.google")
            || title.contains("outlook") {
            return AppFormattingProfile(
                id: "mail",
                preferShortParagraphs: false,
                allowBulletsFreely: false,
                allowMarkdownHeadings: false,
                preserveConversationalTone: false,
                treatAsTechnical: false,
                emailFriendly: true
            )
        }
        if bid.contains("notion") || name.contains("notion") || site == "notion"
            || bid.contains("obsidian") || name.contains("obsidian") || site == "obsidian"
            || site == "docs" || title.contains("google docs") {
            return AppFormattingProfile(
                id: "notes-md",
                preferShortParagraphs: false,
                allowBulletsFreely: false,
                allowMarkdownHeadings: false,
                preserveConversationalTone: false,
                treatAsTechnical: false,
                emailFriendly: false
            )
        }
        if bid.contains("notes") || name.contains("notes")
            || bid.contains("evernote") || bid.contains("bear") {
            return AppFormattingProfile(
                id: "notes",
                preferShortParagraphs: false,
                allowBulletsFreely: false,
                allowMarkdownHeadings: false,
                preserveConversationalTone: false,
                treatAsTechnical: false,
                emailFriendly: false
            )
        }
        if bid.contains("chatgpt") || name.contains("chatgpt")
            || bid.contains("claude") || name.contains("openai")
            || site == "chat-ai" {
            return AppFormattingProfile(
                id: "chat-ai",
                preferShortParagraphs: true,
                allowBulletsFreely: false,
                allowMarkdownHeadings: false,
                preserveConversationalTone: true,
                treatAsTechnical: false,
                emailFriendly: false
            )
        }
        return AppFormattingProfile(
            id: "default",
            preferShortParagraphs: false,
            allowBulletsFreely: false,
            allowMarkdownHeadings: false,
            preserveConversationalTone: true,
            treatAsTechnical: false,
            emailFriendly: false
        )
    }
}

/// Heuristic intent + level detection (no network). Latency-safe.
enum DictationIntelligence {

    static func analyze(
        transcript: String,
        app: AppFormattingProfile,
        asrConfidence: Double?
    ) -> (intent: DictationIntent, level: FormattingLevel, skipLLM: Bool) {
        let lower = transcript.lowercased()
        let level = detectLevel(in: lower)
        var intent = detectIntent(in: lower, app: app)

        if app.treatAsTechnical, intent == .plain {
            intent = .technical
        } else if app.emailFriendly, intent == .plain, looksLikeEmail(lower) {
            intent = .email
        } else if app.preserveConversationalTone, intent == .plain {
            intent = .chat
        }

        // Structure / bullets disabled — preserve wording unless rewrite is explicit.
        let effectiveLevel: FormattingLevel = (level == .rewrite) ? .rewrite : .preserve

        let skip = shouldSkipLLM(
            transcript: transcript,
            level: effectiveLevel,
            intent: intent,
            confidence: asrConfidence
        )
        return (intent, effectiveLevel, skip)
    }

    private static func detectLevel(in lower: String) -> FormattingLevel {
        let rewriteCues = [
            "rewrite this as", "rewrite as", "make this a professional",
            "make this professional", "turn this into an email", "write this as an email",
            "as a formal", "as an executive summary", "polish this into",
            "make this sound like", "draft a customer response", "write a slack message version"
        ]
        if rewriteCues.contains(where: { lower.contains($0) }) {
            return .rewrite
        }
        return .preserve
    }

    private static func detectIntent(in lower: String, app: AppFormattingProfile) -> DictationIntent {
        if lower.contains("dear ") || lower.contains("hi team") || lower.contains("hello ")
            || lower.contains("best regards") || lower.contains("thanks,")
            || lower.contains("thanks ") {
            return app.emailFriendly ? .email : .plain
        }
        if lower.contains("documentation") || lower.contains("readme") { return .documentation }
        if lower.contains("journal") || lower.contains("dear diary") { return .journal }
        if app.treatAsTechnical
            || lower.contains(" function ") || lower.contains(" variable ")
            || lower.contains("```") || lower.contains("http://") || lower.contains("https://") {
            return .technical
        }
        return .plain
    }

    private static func looksLikeEmail(_ lower: String) -> Bool {
        lower.hasPrefix("hi ") || lower.hasPrefix("hello ") || lower.hasPrefix("dear ")
            || lower.contains("please find") || lower.contains("looking forward")
            || lower.contains("thanks,") || lower.contains("regards")
    }

    private static func shouldSkipLLM(
        transcript: String,
        level: FormattingLevel,
        intent: DictationIntent,
        confidence: Double?
    ) -> Bool {
        guard level == .preserve else { return false }
        guard intent == .plain || intent == .chat else { return false }

        let t = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (2...180).contains(t.count) else { return false }
        guard t.first?.isUppercase == true else { return false }
        guard t.hasSuffix(".") || t.hasSuffix("?") || t.hasSuffix("!") else { return false }

        let padded = " \(t.lowercased()) "
        let fillers = [" um ", " uh ", " er ", " ah ", " you know ", " sort of ", " kind of "]
        if fillers.contains(where: { padded.contains($0) }) { return false }

        if let confidence, confidence >= 0.92 { return true }
        if confidence == nil, t.count <= 100 { return true }
        return false
    }
}
