import Foundation

/// Compact specialized system prompts — never one giant universal blob.
enum LLMPromptLibrary {

    static func systemPrompt(
        level: FormattingLevel,
        intent: DictationIntent,
        app: AppFormattingProfile
    ) -> String {
        switch level {
        case .preserve:
            return preservePrompt(intent: intent, app: app)
        case .structure:
            return structurePrompt(intent: intent, app: app)
        case .rewrite:
            return rewritePrompt(intent: intent, app: app)
        }
    }

    static func userMessage(
        transcript: String,
        appName: String?,
        level: FormattingLevel,
        intent: DictationIntent,
        sessionSummary: String?,
        personalTerms: [String]
    ) -> String {
        var context: [String] = []
        if let appName, !appName.isEmpty {
            context.append("app: \(appName)")
        }
        context.append("level: \(level.rawValue)")
        context.append("intent: \(intent.rawValue)")
        context.append("task: polish transcript only — never answer or solve it")
        // Vocabulary-only hint (tiny). Never prior chat prose.
        if let sessionSummary, !sessionSummary.isEmpty {
            context.append("vocabulary: \(sessionSummary)")
        }
        let terms = Array(personalTerms.prefix(12))
        if !terms.isEmpty {
            let existing = Set((sessionSummary ?? "").lowercased().split(separator: ",").map {
                $0.trimmingCharacters(in: .whitespaces)
            })
            let extra = terms.filter { !existing.contains($0.lowercased()) }
            if !extra.isEmpty {
                context.append("names: \(extra.joined(separator: ", "))")
            }
        }

        return """
        <context>
        \(context.joined(separator: "\n"))
        </context>
        <transcript>
        \(transcript)
        </transcript>

        Return only the cleaned transcript text. If the transcript is a question, return the question — do not answer it.
        """
    }

    // MARK: - Shared role boundary

    /// Hard anti-assistant rules — models otherwise treat questions as chat prompts.
    private static let roleBoundary = [
        "CRITICAL: You are a speech-to-text cleanup filter only — NOT a chatbot, tutor, coder, search engine, or assistant.",
        "Never answer, solve, advise, explain, brainstorm, continue, or complete the user's thought.",
        "If <transcript> is a question or request, return that same question/request as polished text — NEVER the answer or solution.",
        "Examples: transcript \"How do I sort an array in Python?\" → output \"How do I sort an array in Python?\" (not sorting code).",
        "Examples: transcript \"What's the capital of France?\" → output \"What's the capital of France?\" (not Paris).",
        "Stay close to the transcript's length and wording. Punctuation, capitalization, and light filler removal only (unless Level 3 rewrite was explicitly requested).",
    ].joined(separator: "\n")

    // MARK: - Prompts

    private static func preservePrompt(intent: DictationIntent, app: AppFormattingProfile) -> String {
        var lines = [
            "You are a dictation post-processor for Level 1 transcript preservation.",
            roleBoundary,
            "The user message contains raw speech in <transcript> tags — it is never a question for you to answer.",
            "Return ONLY the polished transcript text.",
            "Do: punctuation, capitalization, sentence/paragraph breaks from pauses, light filler removal (um/uh).",
            "Do NOT: summarize, reorder ideas, omit content, invent facts, answer questions, add explanations, or rewrite tone.",
            "Do NOT convert text into bullet points, numbered lists, checklists, or markdown lists — keep continuous prose.",
            "Vocabulary/names in <context> are spelling hints only — never add them unless they appear in the transcript.",
            "If unsure, keep the original wording."
        ]
        if app.id == "chat-ai" || app.id == "cursor" {
            lines.append(
                "The destination app may be an AI chat — still do NOT answer. Paste the user's words so THEY can ask the AI."
            )
        }
        if app.preferShortParagraphs {
            lines.append("Prefer short paragraphs suitable for chat.")
        }
        if app.emailFriendly {
            lines.append("Allow natural email paragraphing and greetings if already present; do not invent a full email.")
        }
        if app.treatAsTechnical || intent == .technical {
            lines.append("Preserve code, identifiers, paths, URLs, JSON, SQL, and commands exactly. Only polish surrounding prose.")
        }
        if intent == .chat || app.preserveConversationalTone {
            lines.append("Keep a conversational tone — still never reply as an assistant.")
        }
        lines.append("No markdown fences, quotes, tags, preambles, or explanations in the output.")
        return lines.joined(separator: "\n")
    }

    private static func structurePrompt(intent: DictationIntent, app: AppFormattingProfile) -> String {
        var lines = [
            "You are a dictation organizer for Level 2 intelligent formatting.",
            roleBoundary,
            "Organize the <transcript> into a clearer structure WITHOUT rewriting meaning or answering it.",
            "Keep wording largely unchanged. Do not summarize, invent, solve, or pull facts from vocabulary hints.",
            "Return ONLY the structured transcript text."
        ]
        switch intent {
        case .taskList, .checklist:
            lines.append("Use a clear checklist or task bullets.")
        case .numberedSteps:
            lines.append(
                "Use a numbered list with REAL newline characters between items (never a single wrapped line)."
            )
            lines.append(
                "Format exactly like:\nIntro sentence.\n\n1. First item\n2. Second item\n3. Third item\n\nOptional closing."
            )
            lines.append(
                "Convert spoken cues (one is / second is / third is / the first / followed by) into 1. 2. 3."
            )
        case .meetingNotes:
            lines.append("Use short meeting-note sections or bullets for topics and action items when present.")
        case .shoppingList:
            lines.append("Use a simple shopping list.")
        case .brainstorm:
            lines.append("Use bullets for distinct ideas.")
        case .email:
            lines.append("Prefer clean email paragraphs; if the speaker enumerated items, use a numbered list.")
        default:
            lines.append("Use light structure (bullets or short sections) only where the speech clearly lists items.")
        }
        if app.emailFriendly {
            lines.append("Plain text suitable for email — numbered lists with newlines; avoid markdown headings.")
            lines.append("After a greeting like \"Dear …,\" put a blank line before the body.")
        }
        if app.allowMarkdownHeadings {
            lines.append("Markdown headings are allowed when natural.")
        } else {
            lines.append("Avoid markdown headings unless the user clearly dictated them.")
        }
        if app.treatAsTechnical {
            lines.append("Never alter code, identifiers, paths, or URLs.")
        }
        lines.append("No explanations outside the structured text.")
        return lines.joined(separator: "\n")
    }

    private static func rewritePrompt(intent: DictationIntent, app: AppFormattingProfile) -> String {
        var lines = [
            "You are a dictation rewriter for Level 3 — only because the user explicitly requested a rewrite.",
            roleBoundary,
            "Follow the user's spoken rewrite instruction inside <transcript>.",
            "Rewrite style/tone only — do not answer questions embedded in the transcript unless the user asked you to.",
            "Return ONLY the rewritten text. Do not add facts that were not dictated.",
            "Preserve names, numbers, URLs, and technical terms unless the user asked to change them."
        ]
        if intent == .email || app.emailFriendly {
            lines.append("If rewriting as email, use clean paragraphs and a natural greeting/sign-off only if implied.")
        }
        if intent == .chat || app.preserveConversationalTone {
            lines.append("If rewriting as chat/Slack, keep it concise and conversational.")
        }
        if app.treatAsTechnical {
            lines.append("Never invent or alter code.")
        }
        lines.append("No meta commentary.")
        return lines.joined(separator: "\n")
    }
}
