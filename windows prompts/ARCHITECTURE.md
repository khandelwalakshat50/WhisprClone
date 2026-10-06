# Architecture (Mac product → Windows rewrite)

## Pipeline (identical product behavior)

```
Hotkey BEGIN
  → remember foreground window / app
  → show overlay "listening"
  → START MIC IMMEDIATELY
  → start Deepgram live WebSocket in background
  → buffer PCM until socket ready, then stream
  → (optional) progressive LLM on finalized segments — Mac limits this aggressively

Hotkey STOP
  → short post-roll (~200ms streaming)
  → flush remaining PCM
  → Finalize WebSocket
  → join final transcript
  → if empty/incomplete → full-file Deepgram fallback
  → LLM format (punctuation / caps only)
  → reject assistant-style answers
  → restore focus to target window
  → clipboard paste (Ctrl+V)
  → overlay success → idle
  → restore previous clipboard later
```

## Modules to recreate

| Module | Responsibility |
|--------|----------------|
| `HotkeyService` | Global toggle; debounce duplicate edges; ignore stop <650ms after begin |
| `AudioCapture` | WASAPI → 16 kHz mono PCM + optional WAV sidecar for fallback |
| `DeepgramLiveStreamer` | WebSocket ingest / Finalize / CloseStream / KeepAlive |
| `DeepgramBatch` | HTTP POST fallback for full file / chunks |
| `LlmFormatter` | Gemini/Groq routing + prompts + anti-answer guard |
| `TextInjector` | Save clipboard → set text → focus target → Ctrl+V → delayed restore |
| `Overlay` | Tiny status HUD |
| `Settings` | API keys + model names |
| `Coordinator` | Session state machine |

## State machine
`idle | listening | detectingSpeech | transcribing | formatting | injecting | success | failure`

## Focus / paste contract
1. On BEGIN: store target HWND (the app user was in)
2. Never leave our Settings/overlay as the paste target
3. On inject: `SetForegroundWindow(target)` → sleep 25ms → paste → sleep 35ms
4. Clipboard restore after ~900ms asynchronously

## What Mac uses that Windows replaces

| Mac | Windows |
|-----|---------|
| Menu bar NSStatusItem | NotifyIcon tray |
| CGEventTap Fn double-tap | RegisterHotKey / low-level hook (`Ctrl+Win+Space`) |
| AVAudioEngine | NAudio WASAPI |
| URLSessionWebSocketTask | ClientWebSocket |
| Keychain | Credential Manager |
| Accessibility + Cmd+V | SendInput Ctrl+V |
| AppKit floating panel | WPF/WinUI ToolWindow Topmost |
