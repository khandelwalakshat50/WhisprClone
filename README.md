# WisprClone

Local-first AI dictation for macOS 15+. Menu bar app — no Dock icon.

**New to this?** Follow the plain-language guide: **[SETUP_FOR_BEGINNERS.md](SETUP_FOR_BEGINNERS.md)**

**Architecture, security, troubleshooting, deployment, and Mac-to-Mac migration:**  
**[PROJECT_HANDBOOK.md](PROJECT_HANDBOOK.md)**

## Requirements

- Xcode 16+ (full Xcode, not Command Line Tools alone)
- macOS 15+
- Swift 6
- Optional: [Ollama](https://ollama.com) for local formatting (`qwen3:8b` / `llama3.2`)
- Optional: **Deepgram**, **Gemini**, Groq, and/or OpenAI API keys (via `.env` or Preferences)

## API keys (`.env`)

1. Copy the template and fill in real keys (never commit `.env`):

```bash
cp .env.example .env
```

```env
DEEPGRAM_API_KEY=your_deepgram_key
GEMINI_API_KEY=AIza...
OPENAI_API_KEY=sk-...
GROQ_API_KEY=gsk_...
```

`GOOGLE_API_KEY` is also accepted as an alias for Gemini.

Default speech engine is **Deepgram Nova-3** (`DEEPGRAM_API_KEY`). WhisperKit and Apple Speech remain available in Preferences.

2. On launch the app loads keys from (first match wins per key, then merges):

1. Process environment  
2. Working directory / walk-up from the app bundle (finds the repo `.env` when run from Xcode)  
3. `~/OpenWhisper/.env` (and a few common clone paths) when launched from `/Applications`  
4. `~/Library/Application Support/WisprClone/.env` (mirrored for Release installs)

Keys are seeded into the **Keychain** when missing. You can also paste/edit them in **Preferences → Formatting**. Use **Reload .env** after editing the file.

## Open & Run

1. Open `WisprClone.xcodeproj` in Xcode.
2. Allow Xcode to resolve the **WhisperKit** Swift package.
3. Paste your keys into `.env` (or Preferences).
4. Run the **WisprClone** scheme (⌘R).
5. Grant **Microphone**, **Accessibility**, and **Input Monitoring**.

For a polished Release build in Applications, see the beginner guide / handbook deploy notes.

## Hotkeys

| Action | Binding |
|---|---|
| Start dictation | **Double-tap fn** |
| Stop and transcribe | **Tap fn once** |
| Toggle dictation | **⌘⇧Space** |

Speak → manually stop → Deepgram Nova-3 (live chunks + full-file fallback) → LLM format → paste into the focused app.

## Formatting modes

| Mode | Behavior |
|---|---|
| **Local Only** | Ollama on your Mac |
| **Gemini Only** | Google Gemini (`gemini-3.5-flash` by default) |
| **Groq Only** | Groq Chat Completions |
| **OpenAI Only** | OpenAI Chat Completions |
| **Auto Fallback** | **Very short** (≈ **4–5s**) → **Groq first** (speed). **Longer** dictation → **Gemini first** (quality), with parallel Gemini splits when needed. Then the other cloud provider → OpenAI → Ollama. |

Gemini calls use a short dictation prompt, **minimal thinking**, and an 8s timeout; if `gemini-3.5-flash` is overloaded they retry **`gemini-3.1-flash-lite`** before falling through.

## Phases

| Phase | Status |
|---|---|
| 1 Menu bar skeleton | Done |
| 2 Floating overlay | Done |
| 3 Keychain + Permission Manager | Done |
| 4 Global hotkeys (`CGEventTap`) | Done |
| 5 Audio recording | Done |
| 6 RMS VAD | Done |
| 7 Speech (WhisperKit + Apple) | Done |
| 8 LLM formatting (Gemini / Groq / OpenAI / Ollama) | Done |
| 9 Text injection | Done |
| 10 Settings | Done |
| 11 Unified OSLog (`AppLogger`) | Done |
| 12 Final integration polish | Done |

## Security notes

- **App Sandbox is disabled** (required for `CGEventTap` and cross-app paste).
- Hardened Runtime is enabled.
- `.env` is gitignored — never commit real keys.
- Runtime storage prefers **Keychain** after the first successful load.
- Cloud formatting sends **transcript text** (not raw audio) to the chosen provider — only enable keys you intend to use.
