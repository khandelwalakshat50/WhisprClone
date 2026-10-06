# WisprClone — System Design

Local-first AI dictation for **macOS 15+**: menu-bar app, no Dock icon. Speak → ASR → intelligent LLM polish → paste into the focused app without stealing focus.

Related: [README.md](README.md) · [PROJECT_HANDBOOK.md](PROJECT_HANDBOOK.md) · [SETUP_FOR_BEGINNERS.md](SETUP_FOR_BEGINNERS.md)

---

## Product loop

1. **Start** — double-tap **fn** or **⌘⇧Space**
2. **Speak** — live ASR chunks (~4s) while listening
3. **Stop** — single-tap **fn** (deferred so double-tap can cancel)
4. **Format** — intent/app-aware LLM (or skip when ASR is already clean)
5. **Paste** — Accessibility inject, else clipboard + ⌘V

**Hotkeys:** double-fn start · single-fn stop · ⌘⇧Space toggle. Begin is ignored during refine/inject.

---

## Technology

| Layer | Stack |
|---|---|
| App | **Swift 6**, SwiftUI + AppKit |
| ASR | **Deepgram Nova-3** (default, cloud) · WhisperKit / Apple Speech optional |
| Live ASR | `LiveChunkTranscriber` + VAD (~4s windows) via Deepgram or Whisper |
| LLM | **Groq** `llama-3.1-8b-instant` (short only) · **Gemini** `gemini-3.5-flash` (+ lite fallback) · OpenAI · Ollama |
| Intelligence | `DictationIntelligence` + `LLMPromptLibrary` (levels / intents / app profiles) |
| Memory | Per-app `ContextSessionStore` + `PersonalDictionaryStore` |
| HUD | Frosted glass, metallic silver, orbiting thin 3D ring |

```
Hotkeys → DictationCoordinator
            ├─ AudioRecorder + VAD
            ├─ LiveChunkTranscriber (Deepgram / WhisperKit)
            ├─ ProgressiveLLMFormatter (Groq, ≤1 short chunk)
            ├─ LLMFormattingService (intent · app · confidence)
            └─ TextInjector (AX → clipboard)
```

---

## Formatting intelligence (latency-first)

| Level | When | Behaviour |
|---|---|---|
| **1 Preserve** (default) | Most dictation | Punctuation, capitalization, paragraphs, light filler removal — **keep wording** |
| **2 Structure** | Lists / notes / clear cues, or Notes/Notion-friendly apps | Organize without rewriting meaning |
| **3 Rewrite** | Explicit spoken request only | Tone/format rewrite |

Heuristics pick intent (email, chat, tasks, technical, …) and frontmost-app profile (Gmail, Slack, Cursor, Notion, ChatGPT, Notes). High Deepgram confidence + already-clean transcript → **skip LLM**.

Rolling per-app session summaries (topic / people / acronyms / style) and a personal vocabulary feed the formatter without mixing unrelated windows.

---

## Auto routing (quality-first for real dictation)

| Utterance | Provider | Why |
|---|---|---|
| ≈ **4–5 seconds** or less | **Groq first** | Fast enough; progressive single-chunk overlap |
| **Longer** than ~5s | **Gemini first** | Much better cleanup quality |
| Failures | Other cloud → OpenAI → Ollama | Resilience |

**Progressive LLM:** Groq may format the **first** live chunk only. A second chunk abandons progressive work so the final pass uses **Gemini** (not stitched Groq pieces).

**Long fallback splits:** ≤700-character pieces run **parallel Gemini-first** (not Groq).

Specialized short prompts + warm HTTP + output caps apply to all providers.

---

## Latency vs quality

- **Short phrases:** live ASR + one Groq call (or skip) → often under ~1s refine.
- **Medium/long:** live ASR still overlaps speech; formatting waits for Gemini (quality). Prefer this over fast-but-bad Groq on long text.
- Prefer a slightly simpler result immediately over a perfect rewrite that takes seconds.

---

## ASR / LLM / UX (brief)

- Deepgram returns confidence for skip/cleanup scaling; vocabulary keyterms include learned personal terms.
- LLM is a post-processor only (`<transcript>` in → polished text out) — never a chatbot.
- Overlay: glass capsule, orbiting ring, silver waveform.
- Diagnostics: `~/Library/Application Support/WisprClone/debug.log`

**Key files:** `DictationCoordinator` · `LiveChunkTranscriber` · `DictationIntelligence` · `LLMPromptLibrary` · `LLMFormattingService` · `ContextSessionStore` · `PersonalDictionaryStore` · `Constants`
