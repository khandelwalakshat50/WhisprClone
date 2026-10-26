# WisprClone

A macOS menu-bar dictation app. Double-tap **Fn**, speak, stop, and the text is pasted into the app you were typing in.

Speech goes to **Deepgram Nova-3** over a live WebSocket. Cleanup is optional: **Groq** for short phrases, **OpenAI** for longer ones, **Gemini** only if those fail. Nothing in this repo contains a real API key.

**Give the app to someone else (they use their own keys):** [SHARING_MAC.md](SHARING_MAC.md)  
**First-time setup from source:** [SETUP_FOR_BEGINNERS.md](SETUP_FOR_BEGINNERS.md)  
**Architecture, permissions, and deployment:** [PROJECT_HANDBOOK.md](PROJECT_HANDBOOK.md)

## What you need

- macOS 15 or newer
- Xcode 16 or newer, if you are building it yourself
- A **Deepgram** API key (required for transcription)
- A **Groq** and/or **OpenAI** key if you want the text cleaned up
- A **Gemini** key only as a last-resort backup

## API keys

Real keys stay on your Mac. They are never committed.

```bash
cp .env.example .env
```

Fill in `.env` with your own keys:

```env
DEEPGRAM_API_KEY=
GEMINI_API_KEY=
OPENAI_API_KEY=
GROQ_API_KEY=
```

`GOOGLE_API_KEY` is accepted as another name for the Gemini key.

On launch the app reads keys from the environment, then `.env`, then `~/Library/Application Support/WisprClone/.env`. Empty Keychain entries are filled from that file. You can also paste keys in **Wispr → Preferences…**. They are stored in the Keychain after that.

`.env` is listed in `.gitignore`. Do not remove that line, and do not commit a filled-in `.env`.

## Run it

1. Open `WisprClone.xcodeproj` in Xcode.
2. Let Xcode fetch the WhisperKit package (only needed if you switch off Deepgram).
3. Run the **WisprClone** scheme (⌘R).
4. Allow **Microphone**, **Accessibility**, and **Input Monitoring**, then quit and reopen the app.

To hand someone a built app instead of this repo, follow [SHARING_MAC.md](SHARING_MAC.md).

## Hotkeys

| Action | Binding |
|---|---|
| Start | Double-tap **Fn** |
| Stop and paste | Tap **Fn** once |
| Toggle | **⌘⇧Space** |

On a Windows keyboard, Fn usually never reaches macOS. Use **⌘⇧Space**.

## How formatting is chosen

Preferences mode **Auto Fallback** (the default):

| Dictation | Order |
|---|---|
| About 12 seconds or shorter | Groq, then OpenAI, then Gemini |
| Longer | OpenAI, then Groq, then Gemini |
| All of those fail | Local Ollama, if it is running |

Groq uses `qwen/qwen3.8-27b` with reasoning off. OpenAI uses `gpt-5.4-nano`. Gemini is `gemini-3.1-flash-lite`. You can still pin one provider in Preferences.

The model is told to punctuate and remove fillers. It is not supposed to answer a question you dictated. If the reply looks like an answer, the app throws it away and pastes a lightly cleaned transcript instead.

## Security

- This GitHub repo is **private**.
- `.env` has never been committed. `.env.example` has empty placeholders only.
- Audio is sent to Deepgram. Only the transcript text is sent to Groq, OpenAI, or Gemini, and only to providers whose keys you added.
- Dictation history stays on the Mac (`UserDefaults`). Debug logs stay in `~/Library/Application Support/WisprClone/`.
- The app is not sandboxed, because a menu-bar dictation tool has to see global hotkeys and paste into other apps. Do not ship it widely without Developer ID signing and notarization (`PROJECT_HANDBOOK.md`).
