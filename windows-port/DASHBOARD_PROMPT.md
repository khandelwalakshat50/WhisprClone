# Cursor prompt add-on — Preferences / Dashboard (Mac parity)

Paste this into your Windows Cursor chat **in addition to** `CURSOR_PROMPT.md`.
Do this after Phase 1 works (hotkey → paste). The Mac app is not tray-only — it has a full **Preferences dashboard**.

---

## Goal
Build a dedicated **Preferences / Dashboard window** like macOS WisprClone Preferences — not just a tiny settings dialog. Tray icon stays for quick actions; double-click tray (or “Preferences…”) opens this window.

## Window shell
- Title: `OpenWhisper Preferences` (or WisprClone)
- Size: ~540×640 min, resizable
- Tabs (required):
  1. **Settings**
  2. **History**
- Optional later tab: **About**
- Closing the window must NOT quit the app (tray keeps running)
- Opening Preferences may activate the window, but **during an active dictation session do not steal focus** from the target app

## Tray menu (mirror Mac)
- Start Dictation
- Preferences…
- (separator)
- Preview Overlay (cycles listening → refining → success → failure → idle for UI testing)
- About
- Quit

## Tab 1 — Settings (grouped sections)

### Speech
- Engine picker: Deepgram Nova-3 (default) | (optional later: local Whisper)
- Deepgram model text field — default `nova-3`; sanitize invalid values back to `nova-3`
- Deepgram API Key (password box)
- Vocabulary / keyterms (comma-separated optional)
- Helper captions under fields (same tone as Mac)

### Formatting
- Mode picker:
  - Local Only (Ollama) — optional / can hide if unused
  - Gemini Only
  - Groq Only
  - OpenAI Only
  - **Auto Fallback (short→Groq, long→Gemini)** ← default
- Model name fields: Gemini, Groq, OpenAI (Ollama optional)
- Secure API key fields: Gemini, Groq, OpenAI
- Button: Reload `.env` / environment keys if supported
- Temperature slider 0–1
- Note if keys were loaded from env

### Provider Usage · Last 48 Hours
- Per-provider success counts (Gemini / Groq / OpenAI / Local)
- “Last successful provider: …”
- Clear usage button
- Caption: counts successful formatting only; never store transcript text or API keys here

### Appearance
- Theme: System / Light / Dark

### Hotkeys
- Read-only labels for Windows defaults, e.g.:
  - Toggle dictation: `Ctrl+Win+Space`
  - (Do not show Mac Fn gestures unless you implement them)

### Permissions (Windows equivalents)
Show status + “Open Settings” / request buttons for:
- Microphone
- Accessibility / UI automation if needed for paste
- (Optional) Speech recognition if you add local ASR later

### Build footer
- Small caption with version / build id, selectable text

## Tab 2 — History (critical Mac feature)
Keep the last **10** transcripts locally (Windows: `%AppData%\OpenWhisper` or user settings).

Each row shows:
- Timestamp
- Total duration (optional)
- Transcription model label (e.g. `Deepgram · nova-3`)
- Formatting provider label (e.g. `Gemini formatting`)
- Timing breakdown: Transcription / Formatting / Paste seconds when available
- Delay note (human-readable latency explanation) when present
- Full transcript text (selectable)
- **Copy** button (re-copy if paste failed into another app)

Footer:
- “Keeps the last 10 transcripts, stored only on this PC.”
- Clear History button

Empty state:
- “No Transcripts Yet” + short explanation about Copy recovery

## Data rules
- History **does** store transcript text (user requested for recovery)
- Usage store **must not** store transcript text or API keys
- API keys → Windows Credential Manager / DPAPI, not plain settings JSON

## UX quality bar (match Mac feel)
- Clean grouped form layout (not a cluttered options dump)
- Captions under complex fields
- History rows as cards with light background + corner radius
- Instant refresh when a dictation completes (History updates live)
- Preferences open from tray in <200ms

## Implementation notes (WPF / WinUI)
- Use a `TabControl` with Settings + History
- Bind to view-models: `SettingsViewModel`, `HistoryViewModel`, `UsageViewModel`
- After each successful dictation, push an entry into `TranscriptHistoryStore` with timings + delay note
- Persist history as JSON under AppData

## Definition of done
1. Tray → Preferences opens the dashboard window
2. Settings tab can edit keys/models and persist them
3. History tab shows recent dictations with Copy
4. Usage section updates after formatting
5. Closing Preferences leaves the tray app running
6. Looks like a real product preferences UI, not a debug form

## Out of scope for this pass
- Redesigning the live floating overlay (already separate)
- Porting WhisperKit local engine UI beyond a disabled/hidden option
- Exact pixel clone of macOS SwiftUI — match **structure and capability**, Windows-native visuals are fine
