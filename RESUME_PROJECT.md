# OpenWhisper (WisprClone) — Resume Project Write-Up

**One-line summary:** Built a macOS menu-bar AI dictation app that turns speech into polished, context-aware writing and pastes it into the focused app — similar in spirit to Wispr Flow, engineered for low latency and low API cost.

---

## Elevator pitch (use on resume)

**OpenWhisper / WisprClone** — Native macOS (Swift 6) AI dictation assistant: global hotkeys → streaming STT → intent-aware LLM formatting → automatic paste into the active app. Evolved from raw transcription into an OS-level writing layer with app-aware intelligence, per-window memory, and cost-efficient multi-provider routing.

---

## What I built

A production-style **menu-bar dictation app** for macOS 15+ that feels invisible while you work:

1. **Start** with double-tap **fn** (or ⌘⇧Space)
2. **Speak** while a non-activating HUD shows live audio feedback
3. **Stop** with a single fn tap
4. Text is **transcribed**, optionally **refined by an LLM**, then **pasted** into the focused app (Mail, Slack, Cursor, Notion, etc.) without stealing focus

Core stack: **Swift 6**, SwiftUI + AppKit, Accessibility injection, Keychain-backed API keys, Deepgram Nova-3 (default ASR), optional on-device WhisperKit / Apple Speech, and cloud LLMs (Groq, Gemini Flash, OpenAI) plus local Ollama.

---

## Evolution: from transcription to intelligent writing

### Phase 1 — Simple speech-to-text
Early version focused on capture → ASR → paste. Useful, but output often needed manual cleanup (fillers, missing punctuation, no structure).

### Phase 2 — LLM formatting layer
Added a post-processing LLM pass so dictation became usable writing:
- Punctuation, capitalization, paragraph breaks
- Light filler removal
- Conservative cleanup that preserves the user’s wording (not a chatbot rewrite)

### Phase 3 — Latency + cost optimization
Tuned the pipeline so intelligence does **not** mean waiting or burning tokens:
- **Short utterances (~≤5s):** route to **Groq** (`llama-3.1-8b-instant`) for near-instant polish
- **Longer dictation:** route to **Gemini Flash** for better quality
- **Progressive formatting:** start LLM work on the first live ASR chunk *while the user is still speaking*
- **Skip LLM** when ASR confidence is high and the transcript already looks clean
- Warm HTTP sessions, short specialized prompts, capped outputs

### Phase 4 — Wispr Flow–style intelligence (cost-effective)
Moved beyond “format everything the same way” toward an **OS-level writing assistant**:

| Capability | What it does | Why it’s cost-effective |
|---|---|---|
| **Formatting levels** | Preserve (default) → Structure lists/notes → Rewrite only if asked | Avoids expensive creative rewrites by default |
| **Intent detection** | Email, chat, tasks, meeting notes, technical, etc. (heuristic, no extra LLM call) | No second model round-trip for classification |
| **App-aware profiles** | Different behaviour in Gmail vs Slack vs Cursor vs Notion | Better results without heavier prompts |
| **Per-app context sessions** | Compact rolling summary per window/app (topic, people, acronyms, style) | Tiny context instead of full chat history |
| **Personal dictionary** | Learns names/terms; biases ASR + LLM | Fewer retries / corrections over time |
| **Confidence-based processing** | High Deepgram confidence → minimal or zero LLM | Direct STT → paste when “good enough” |

This is the feature set that makes the product feel like **Wispr Flow / modern AI dictation**: system-wide, fast, context-aware, and predictable — while remaining **highly cost-effective** because most of the intelligence is routing, heuristics, and skipping work rather than always calling a large model.

---

## Technical highlights (bullet bank for interviews)

- Designed an end-to-end dictation pipeline with **live chunk ASR** (VAD + ~4s windows) and full-file fallback
- Implemented **multi-provider LLM routing** with automatic fallback (Groq ↔ Gemini ↔ OpenAI ↔ Ollama)
- Built **intent/level/app-aware prompt library** instead of one monolithic system prompt
- Added **per-app memory** and **personal vocabulary** without maintaining a global conversation (avoids context pollution)
- Prioritized **perceived latency**: stream ASR early, overlap LLM with speech, skip LLM when safe
- Shipped polished native UX: glassmorphic overlay, global hotkeys, Accessibility + clipboard injection, Preferences + Keychain secrets

---

## Resume bullet examples (copy/adapt)

- Built a **native macOS AI dictation app** (Swift 6) that captures speech via global hotkeys, transcribes with **Deepgram Nova-3** (optional WhisperKit), formats with LLMs, and pastes into the focused application without stealing focus.
- Evolved the product from raw STT into an **intelligent writing assistant** with intent detection, app-aware formatting profiles, and rewrite-only-when-requested behaviour inspired by tools like Wispr Flow.
- Designed a **cost-efficient multi-provider architecture**: skip LLM on high-confidence transcripts; use Groq for short utterances and Gemini Flash for longer ones; start progressive formatting during speech to hide latency.
- Implemented **per-app rolling context memory** and a **personal dictionary** to improve continuity and vocabulary accuracy without storing full conversation history or mixing unrelated workstreams.

---

## Skills demonstrated

Swift · SwiftUI/AppKit · concurrency/async pipelines · speech recognition (cloud + on-device) · LLM API integration · prompt design · latency optimization · cost-aware systems design · macOS Accessibility · product iteration from MVP → polished tool

---

## Suggested resume title line

**OpenWhisper (WisprClone)** — macOS AI Dictation & Writing Assistant *(Swift 6 · Deepgram · Groq/Gemini · Accessibility)*
