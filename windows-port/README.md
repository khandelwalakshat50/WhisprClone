# Windows Port Kit — OpenWhisper / WisprClone

Copy this entire `windows-port/` folder to your Windows laptop.
Open a **new empty folder** in Cursor on Windows, then paste `CURSOR_PROMPT.md` as the first message.

## How to approach (read this first)

### Do NOT
- Try to compile the macOS Swift app on Windows
- Start with Electron unless you specifically want web tech (native feels snappier for a tray dictation app)
- Build every Mac feature in week 1

### Do
1. **New C# / WinUI 3 (or WPF) tray app** — closest UX to the Mac menu-bar app
2. **Reuse the cloud brain** — Deepgram + Gemini/Groq prompts are identical
3. **Ship vertical slices** in this order (same lessons we learned on Mac):

| Phase | Goal | Done when |
|------|------|-----------|
| 0 | Empty tray app + settings for API keys | Keys stored in Credential Manager |
| 1 | Hold-to-talk OR Ctrl+Win+Space toggle → record WAV → Deepgram HTTP → paste | Text lands in Notepad |
| 2 | Deepgram **live WebSocket**; mic starts *before* socket is ready; buffer leading audio | No missing first words; stop→paste feels fast |
| 3 | LLM polish with anti-answer prompts | Questions stay questions |
| 4 | Floating status overlay near cursor | Visual feedback while listening |
| 5 | App-aware paste restore + history | Matches Mac polish |

### Hotkey reality on Windows
Mac uses **double-tap Fn**. Many Windows laptops don't expose Fn to apps.
**Default Windows hotkey:** `Ctrl+Win+Space` toggle (or hold Right-Ctrl).
Optional later: double-tap a remap key via PowerToys / Interception — don't block v1 on Fn.

### Stack recommendation
- **Language:** C# (.NET 8+)
- **UI:** WinUI 3 packaged app *or* WPF + NotifyIcon (simpler to start)
- **Audio:** NAudio (WASAPI capture → 16 kHz mono PCM)
- **WebSocket:** `ClientWebSocket`
- **Paste:** Clipboard + `SendInput` Ctrl+V; restore previous clipboard after ~900ms
- **Secrets:** Windows Credential Manager / DPAPI

### Copy these files into the Windows repo
- `CURSOR_PROMPT.md` → paste into Cursor Agent as the project brief
- `DASHBOARD_PROMPT.md` → Preferences / History dashboard (Mac parity UI)
- `VISUAL_PROMPT.md` → icon, easy launch, Mac-like bottom waveform HUD
- `ARCHITECTURE.md` → product + pipeline truth
- `DEEPGRAM_LIVE.md` → streaming protocol (critical for latency)
- `LLM_PROMPTS.md` → exact formatting prompts (anti-answer rules)
- `CONSTANTS.md` → timing numbers that already work on Mac
- `PITFALLS.md` → bugs we already paid for — don't repeat them

### Success criteria for “exactly the same”
Same *product behavior*, not same code:
1. Global hotkey start/stop without stealing focus permanently
2. Speak immediately; leading words not cut
3. Trailing words not cut on stop
4. Fast paste into focused app (Chrome, Word, Cursor, Slack…)
5. LLM cleans punctuation only — never answers the question
6. Tray icon + small listening indicator
