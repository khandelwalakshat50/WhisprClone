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
- Optional: OpenAI and/or Groq API keys (via `.env`)

## API keys (`.env`)

1. Edit the repo-root [`.env`](.env) file (already created; gitignored):

```env
OPENAI_API_KEY=sk-...
GROQ_API_KEY=gsk_...
```

2. Or copy from the template: `cp .env.example .env`

On launch the app loads keys from:

1. Process environment  
2. `~/Library/Application Support/WisprClone/.env`  
3. Working directory / walk-up from the app bundle (finds the repo `.env` when run from Xcode)

Keys are seeded into the **Keychain** when missing. You can also paste/edit them in **Preferences**.

## Open & Run

1. Open `WisprClone.xcodeproj` in Xcode.
2. Allow Xcode to resolve the **WhisperKit** Swift package.
3. Paste your keys into `.env`.
4. Run the **WisprClone** scheme (⌘R).
5. Grant **Microphone**, **Accessibility**, and **Input Monitoring**.

## Hotkeys

| Action | Binding |
|---|---|
| Start dictation | **Double-tap Left ⌘** |
| Stop and transcribe | **Tap Left ⌘ once** |
| Toggle dictation | **⌘⇧Space** |

Speak for as long as needed → manually stop → format (Ollama → Groq → OpenAI in Auto mode) → paste into the focused app.

## Formatting modes

- **Local Only** — Ollama  
- **Groq Only** — Groq Chat Completions  
- **OpenAI Only** — OpenAI Chat Completions  
- **Auto Fallback** — Ollama → Groq → OpenAI  

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
| 8 LLM formatting | Done |
| 9 Text injection | Done |
| 10 Settings | Done |
| 11 Unified OSLog (`AppLogger`) | Done |
| 12 Final integration polish | Done |

## Security notes

- **App Sandbox is disabled** (required for `CGEventTap` and cross-app paste).
- Hardened Runtime is enabled.
- `.env` is gitignored — never commit real keys.
- Runtime storage prefers **Keychain** after the first successful load.
