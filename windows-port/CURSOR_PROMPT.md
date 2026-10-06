# Cursor prompt — paste this into a NEW Windows project

You are building **OpenWhisper for Windows**: a tray/menu dictation app that mirrors the macOS WisprClone / OpenWhisper product.

## Product
Global hotkey dictation app:
1. User presses hotkey → mic starts immediately
2. Speech streams to Deepgram Nova-3 live WebSocket
3. On stop → Finalize stream → LLM polishes punctuation only
4. Paste into the previously focused app via clipboard + Ctrl+V
5. Never steal focus permanently; restore target window before paste

## Non-goals for v1
- Do not port Swift/AppKit code
- Do not implement Fn-key double-tap (Windows often can't see Fn) — use `Ctrl+Win+Space` toggle
- Do not build WhisperKit / local ASR first — Deepgram cloud only
- Do not answer user questions in the LLM layer — format transcript only

## Tech stack (use these unless blocked)
- C# / .NET 8
- WPF + NotifyIcon tray (simpler than WinUI packaging for v1) OR WinUI 3 if you prefer
- NAudio for WASAPI capture
- ClientWebSocket for Deepgram
- HttpClient for Gemini / Groq
- Windows Credential Manager for API keys
- Serilog or simple file log under `%AppData%\OpenWhisper\debug.log`

## Build order (strict)
### Phase 0 — Skeleton
- Tray icon: Start / Stop / Settings / Quit
- Settings window: Deepgram key, Gemini key, Groq key, hotkey display
- Persist keys securely

### Phase 1 — End-to-end dumb path
- Hotkey toggle start/stop
- Record mic to memory/WAV (16 kHz mono linear16 ideal)
- POST to Deepgram pre-recorded `/v1/listen?model=nova-3`
- Clipboard set + Ctrl+V into foreground window
- Prove text appears in Notepad

### Phase 2 — Live streaming (required for Mac parity)
- Open `wss://api.deepgram.com/v1/listen` with Authorization `Token <KEY>`
- Query params: model=nova-3, encoding=linear16, sample_rate=16000, channels=1, smart_format=true, punctuate=true, interim_results=true, endpointing=300, utterance_end_ms=1000
- **CRITICAL:** start mic FIRST, connect WebSocket in background, buffer PCM until connected, then flush
- On stop: ~200ms post-roll → send `{"type":"Finalize"}` → wait for finals / from_finalize (~2s max) → `{"type":"CloseStream"}`
- KeepAlive every 5s while open
- If stream empty/fails → fallback to full-file Deepgram POST of the recorded WAV

### Phase 3 — LLM polish
- Use prompts from `LLM_PROMPTS.md` (role boundary is mandatory)
- Auto route: short utterances → Groq `llama-3.1-8b-instant`; longer → Gemini `gemini-3.1-flash-lite`
- Reject answer-expansion: if input looks like a question and output is much longer / starts with "Sure," "Here's", etc., keep lightly polished transcript instead

### Phase 4 — UX
- Small always-on-top overlay near cursor: Listening / Transcribing / Refining / Done
- Don't activate our window in a way that kills the text caret in the target app

## Architecture rules
- Single `DictationCoordinator`-style orchestrator owns session state machine:
  `idle → listening → detectingSpeech → transcribing → formatting → injecting → success/failure → idle`
- Capture foreground HWND *before* any UI work on begin
- Restore that HWND, short settle (~25ms), then paste, short settle (~35ms)
- Restore original clipboard after ~900ms off the critical path
- Log every stage to debug.log with timestamps

## Definition of done for first usable build
1. Ctrl+Win+Space starts listening within ~100ms of mic open
2. Speaking immediately after hotkey keeps the first words
3. Stopping keeps the last sentence
4. Pasted text is cleaned speech, not an LLM answer
5. Works into Notepad, Chrome, and VS Code/Cursor

## Reference files in this repo folder
Read and follow:
- ARCHITECTURE.md
- DEEPGRAM_LIVE.md
- LLM_PROMPTS.md
- CONSTANTS.md
- PITFALLS.md

Start by scaffolding the WPF tray app and Phase 1. Ask before large refactors. Keep commits small and vertical.
