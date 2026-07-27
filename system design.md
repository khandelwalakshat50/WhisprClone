# WisprClone — System Design

Local-first AI dictation for **macOS 15+**: menu-bar app, no Dock icon. Speak → on-device Whisper → LLM cleanup → paste into the focused app without stealing focus.

Related: [README.md](README.md) · [PROJECT_HANDBOOK.md](PROJECT_HANDBOOK.md) · [SETUP_FOR_BEGINNERS.md](SETUP_FOR_BEGINNERS.md)

---

## Product loop

1. **Start** — double-tap **fn** or **⌘⇧Space**
2. **Speak** — live Whisper chunks (~4s) + progressive Groq formatting overlap with speech
3. **Stop** — single-tap **fn** (deferred so double-tap can cancel)
4. **Paste** — Accessibility inject, else clipboard + ⌘V
5. HUD shows Listening → Thinking → Refining → Writing → Done, then dismisses

**Hotkeys:** double-fn start · single-fn stop · ⌘⇧Space toggle. Begin is ignored during refine/inject so a double-fn cannot abort formatting.

---

## Technology

| Layer | Stack |
|---|---|
| App | **Swift 6**, SwiftUI + AppKit, `async/await` |
| ASR | **WhisperKit** (CoreML) primary; Apple Speech optional |
| Live ASR | `LiveChunkTranscriber` + VAD (phrase / max-window commits, audio overlap) |
| LLM | **Groq** `llama-3.1-8b-instant` · **Gemini** `gemini-3.5-flash` (+ lite fallback) · OpenAI · Ollama |
| Prompt | Shared short `LLMPrompt.system` in `TextFormatter.swift` |
| Audio | AVAudioEngine tap on **hardware input** format |
| Secrets | `.env` → Keychain; Preferences via `UserDefaults` |
| HUD | Frosted glass capsule, metallic silver, orbiting thin 3D ring + waveform |

```
Hotkeys → DictationCoordinator
            ├─ AudioRecorder + VAD
            ├─ LiveChunkTranscriber (WhisperKit)
            ├─ ProgressiveLLMFormatter (Groq per chunk)
            └─ TextInjector (AX → clipboard)
```

---

## Latency architecture (current)

Stop-to-paste delay ≈ remaining ASR + remaining LLM + paste. ASR and LLM are designed to finish **during** speech.

### Short dictation (seconds)

- One live Whisper chunk + one progressive Groq call (short prompt + instant model).
- Target: LLM stage often **under ~1s** (`Groq.chat` in `debug.log`).

### Medium / long dictation (20–60s+) — latest optimization

Earlier mistake: progressive LLM **quit after the first chunk**, then a **single Gemini** call on the full transcript → **10s+** “Refining.”

**Now:**

| Lever | Behavior |
|---|---|
| Live ASR windows | ~**4s** (more chunks, more overlap) |
| Progressive LLM | **Every** usable live chunk → Groq (forced short-form routing) |
| Auto routing | Groq first under ~**90s**; Gemini only for very long captures |
| Fallback split | ≤**700** chars/piece, **parallel Groq-first** (not Gemini-per-piece) |
| Coverage guard | Progressive must cover ≥**80%** of full transcript length, else single-shot |
| Prompt | ~12-line shared system prompt for all providers |
| HTTP | Warm `URLSession`; `max_tokens` / `maxOutputTokens` = **1536** |
| Skip | Already-clean short ASR → no network |

For ~30s speech: ~7–8 small Groq jobs run **while talking**; stop mostly waits on the **last** chunk.

```
speak  ████████████████████████████
asr    ..████..████..████..████..██
llm      ░░  ░░  ░░  ░░  ░░     ░  ← progressive Groq
paste                            ██
```

### What changed from the slow builds

| Before | After |
|---|---|
| ~2k-token system prompt on Groq/OpenAI | Shared short prompt |
| Groq `llama-3.3-70b-versatile` | `llama-3.1-8b-instant` |
| Progressive abandoned after 1 chunk | Progressive on **all** live chunks |
| >7s → whole transcript to Gemini | >90s only; medium stays Groq |
| Parallel splits still Gemini-first | Parallel pieces forced Groq-first |
| Cold `URLSession.shared` | Warm session + output caps |

Prompt “caching” in-app is limited: keep the system string **byte-identical**; real win is **short prefill + fast model + overlap**.

---

## ASR notes

- Whisper model **cached** across sessions; local CoreML folder preferred (`download: false`).
- Alias `base` → `openai_whisper-base` avoids Hub “multiple models” → Unavailable.
- Empty / non-speech → idle (no LLM, no paste).
- Live ASR empty → full-file Whisper fallback.

---

## LLM role

Not a chatbot — a **dictation post-processor** only. Input is `<transcript>…</transcript>`; output is polished text only (fillers, punctuation, spoken commands, self-corrections). Never answer questions or invent identifiers.

Modes: Local / Gemini / Groq / OpenAI / **Auto** (defaults above).

---

## Overlay

Glassmorphic silver HUD: orbiting thin 3D ring (revolves, does not coin-spin), status word, silver waveform, stop control while listening. Constants in `OverlayTheme`.

---

## Observability & ship

- Timings: OSLog (`AppLogger`) + `~/Library/Application Support/WisprClone/debug.log`
- History: provider + stage timings in Preferences
- Release → `/Applications/WisprClone.app` (`xattr -cr` after copy)

**Key files:** `DictationCoordinator` · `LiveChunkTranscriber` · `WhisperKitRecognizer` · `ProgressiveLLMFormatter` · `LLMFormattingService` · `TextFormatter` · `OpenAICompatibleChat` · `GeminiClient` · `Constants`

---

## Summary

WisprClone is optimized for **felt latency**: on-device live Whisper, a **tiny** system prompt, **Groq instant** on every speech chunk, and Gemini only for ultra-long captures. Short phrases feel near-instant; longer dictation stays useful because formatting was moved **into** the speaking window instead of one giant call at the end.
