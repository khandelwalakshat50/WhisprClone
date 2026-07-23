# WisprClone — Setup Guide for Non‑Technical Mac Users

This guide is for someone who has **never used Xcode or Terminal** before.  
Follow the steps in order. Take your time — the first setup is the slowest; everyday use is much simpler.

**GitHub repository:** [https://github.com/khandelwalakshat50/WhisprClone](https://github.com/khandelwalakshat50/WhisprClone)

---

## What WisprClone does

WisprClone is a **menu‑bar dictation app** for Mac (no Dock icon in normal use).

1. You press a keyboard shortcut and speak.
2. WisprClone turns your speech into text on your Mac.
3. It can optionally clean up the wording (punctuation, filler words).
4. It pastes the result into whatever app you were typing in (Notes, Slack, Mail, browser, etc.).

---

## What you need

| Requirement | Notes |
|---|---|
| A Mac | **macOS 15 (Sequoia)** or newer — Apple menu → **About This Mac** |
| Internet | Needed the first time (downloads speech model + optional cloud formatting) |
| Time | First setup: about **30–60 minutes** (mostly waiting for downloads) |
| Optional API keys | Groq and/or OpenAI — only if you want cloud text cleanup |
| Optional Ollama | Only if you want cleanup that never leaves your Mac |

---

## Step 1 — Get the project from GitHub

### Option A — Download as a ZIP (easiest)

1. Open this page in a browser:  
   [https://github.com/khandelwalakshat50/WhisprClone](https://github.com/khandelwalakshat50/WhisprClone)
2. Click the green **Code** button.
3. Click **Download ZIP**.
4. In **Downloads**, double‑click the ZIP to unzip it.
5. Move the folder somewhere easy to find (for example **Documents**).  
   You should see a file named **`WisprClone.xcodeproj`** inside.

### Option B — Clone with GitHub Desktop (also friendly)

1. Install [GitHub Desktop](https://desktop.github.com/).
2. **File → Clone Repository → URL**.
3. Paste: `https://github.com/khandelwalakshat50/WhisprClone`
4. Choose a local folder and click **Clone**.

---

## Step 2 — Install Xcode (free, from Apple)

WisprClone is built with Apple’s developer tools. You run it through **Xcode**.

1. Open the **App Store**.
2. Search for **Xcode**.
3. Click **Get** / **Install** (it is large — several gigabytes).
4. When finished, open **Xcode** once.
5. Install any **additional components** it asks for.
6. Agree to the license if asked.

You only do this once.

---

## Step 3 — Open the project in Xcode

1. In Finder, open the WisprClone / OpenWhisper folder you downloaded.
2. Double‑click **`WisprClone.xcodeproj`** (blue Xcode icon).
3. Wait until the spinner at the top of Xcode stops.

### If Xcode asks about packages (WhisperKit)

1. Menu: **File → Packages → Resolve Package Versions**.
2. Wait for downloads to finish (can take several minutes the first time).

---

## Step 4 — API keys (optional, for cloud cleanup)

Speech transcription can run **entirely on your Mac**.  
Cleanup (“make this sound like writing”) can use:

- **Groq** or **OpenAI** (cloud — text leaves your Mac for that step), or  
- **Ollama** (local — text stays on your Mac), or  
- Skip cleanup and paste raw transcripts.

### Using Preferences (recommended for beginners)

1. Run the app once (Step 5).
2. Click **Wispr** in the menu bar → **Preferences…**
3. Paste your Groq and/or OpenAI key into the fields.
4. Keys are stored in your Mac’s **Keychain** (not uploaded to GitHub).

### Or using a `.env` file

1. In the project folder, copy `.env.example` to `.env` if needed.
2. In Finder, press **Command + Shift + .** to show hidden files.
3. Open `.env` in TextEdit and fill in:

   ```
   OPENAI_API_KEY=sk-...
   GROQ_API_KEY=gsk-...
   ```

4. Save. **Never commit this file or share it.**

You only need **one** cloud key if you use cloud formatting.

---

## Step 5 — Run the app

1. At the top of Xcode, make sure the scheme says **WisprClone**.
2. Choose **My Mac** (not an iPhone).
3. Click the **Play** button ▶ — or press **Command + R**.
4. Wait for “Build Succeeded”. The first build can take several minutes.

### What you should see

- A **Wispr** / mic item in the **menu bar** (top‑right of the screen).  
  On a MacBook with a notch, check the **»** overflow menu on the right.
- Click it → **Start Dictation**, **Preferences…**, **Quit**.

If you see nothing: confirm you pressed **Play ▶**, not only Build. Check the menu bar overflow.

---

## Step 6 — Turn on Mac permissions (required)

Without these, the app cannot hear you, see your shortcuts, or paste text.

**Apple menu → System Settings → Privacy & Security**

Enable **WisprClone** (or **Xcode**, if you only run from Xcode) for:

| Permission | Why it matters |
|---|---|
| **Microphone** | Hear your voice |
| **Accessibility** | Paste text into other apps |
| **Input Monitoring** | Global keyboard shortcuts |
| **Speech Recognition** | Only if you choose Apple Speech in Preferences |

After changing permissions:

1. Menu bar → **Quit WisprClone**.
2. In Xcode, press **Play ▶** again.

You can also open **Preferences** in the app and use **Open Settings** / **Refresh Status**.

---

## Step 7 — Try dictation

1. Open **Notes** (or any app with a text field).
2. Click so the cursor is blinking where you want text.
3. **Start:** double‑tap the **fn** key  
   *(or press **Command + Shift + Space** once to toggle)*
4. A small floating bar should appear (“Listening”).
5. Speak normally. Pauses do **not** stop recording.
6. **Stop:** tap **fn** once  
   *(or **Command + Shift + Space** again)*
7. Wait for Thinking → Refining → Writing → Done.
8. Your words should appear at the cursor.

The **first** transcription can be slow while the speech model finishes preparing. Later uses are faster. Short phrases may still take a few seconds; longer speech often feels quicker because work starts while you talk.

**Tip:** Keep the cursor in the other app (Notes, Slack, etc.). Don’t click the Wispr overlay before paste finishes.

---

## Everyday use (after setup)

| Want to… | Do this |
|---|---|
| Start the app | Open `WisprClone.xcodeproj` → Play ▶ (**⌘R**) |
| Start dictation | Double‑tap **fn** (or **⌘⇧Space**) |
| Stop dictation | Tap **fn** once (or **⌘⇧Space**) |
| Open settings | Menu bar **Wispr** → Preferences… |
| Quit | Menu bar **Wispr** → Quit |

You do not need to rebuild every day unless code changed — but while using the Xcode workflow, you usually press **Play** each time you want the app running.

---

## Optional: keep formatting fully on your Mac (Ollama)

1. Install [Ollama](https://ollama.com).
2. Open **Terminal** and run:

   ```bash
   ollama pull qwen3:8b
   ```

3. Leave Ollama running.
4. In WisprClone Preferences, set formatting to **Local Only** (or **Auto Fallback**, which can try local after cloud).

---

## If something goes wrong

### No menu bar icon
- Confirm Play ▶ succeeded.
- Check the menu bar **»** overflow.
- Quit and run again with **⌘R**.

### Shortcut does nothing
- Enable **Input Monitoring**.
- Quit and relaunch after granting it.
- Use menu **Start Dictation** as a workaround.
- Try **⌘⇧Space**.

### It listens but nothing is typed
- Enable **Accessibility**.
- Click into a text field first.
- Check Preferences for missing API keys / errors.

### Microphone unavailable
- Enable **Microphone** in System Settings.
- Close other apps that might lock the mic.

### Xcode shows red errors
- Update Xcode from the App Store.
- **File → Packages → Resolve Package Versions**.
- Ask someone technical to read the first error in the Issue navigator.

---

## Privacy & where your data lives

### What stays on your MacBook

By default, WisprClone is designed to be **local‑first**:

- **Microphone audio** is recorded and processed on your machine for transcription (WhisperKit / on‑device Apple Speech).
- **Whisper models** download into your Mac’s Application Support folder and stay there.
- **API keys** you paste are stored in your Mac’s **Keychain** (and optionally a local `.env` file you control).
- **Recent transcript history** in Preferences is stored locally on your Mac.
- Temporary audio files are written under your user temp folder and removed after a session.

WisprClone does **not** require an account with this open‑source project, and the GitHub repo does not receive your audio or keys.

### When something can leave your Mac

If you enable **Groq** or **OpenAI** formatting, the **text transcript** (not the raw audio file, in the normal flow) is sent to that provider over the internet so it can clean up wording.  
Their privacy policies apply for that step.

If you use **Local Only (Ollama)** or skip cloud formatting, that cleanup step stays on your machine.

### How to stay as private as possible

1. Prefer **WhisperKit** for speech (default).
2. Set formatting to **Local Only** with Ollama, or avoid cloud keys entirely.
3. Never commit `.env`, never paste keys into GitHub Issues or chat screenshots.
4. Review **System Settings → Privacy & Security** so only apps you trust have Microphone / Accessibility / Input Monitoring.

---

## Disclaimer — security & risk awareness

This software is provided **as‑is**, for personal and educational use. It is **not** a notarized consumer product from Apple’s App Store unless someone separately signs and notarizes a release build for you.

Please understand:

1. **Powerful permissions** — Accessibility and Input Monitoring can, in general, allow an app to observe keyboard activity and control other apps. Only install and run builds you trust, from a source you trust (this repository / a person you trust).
2. **Development builds** — Running from Xcode or an ad‑hoc `/Applications` copy is normal for open‑source Mac tools, but it is not the same as Apple‑notarized App Store software. macOS may warn you the first time you open an unsigned or locally signed binary.
3. **API keys are secrets** — Anyone with your Groq/OpenAI key can use your quota. Treat keys like passwords. Rotate them if they leak.
4. **Cloud formatting risk** — Sending transcripts to a third‑party LLM can expose sensitive content (passwords, medical details, private messages). Do not dictate secrets if cloud formatting is on.
5. **No warranty** — Authors and contributors are not responsible for data loss, unexpected pastes into the wrong app, API charges, or security incidents arising from misuse, misconfiguration, or running untrusted builds.
6. **Your responsibility** — Keep macOS updated, grant the minimum permissions you need, and quit the app when you are not using it if you want to reduce always‑on hotkey exposure.

### Bottom line

Used as intended with **local transcription** and careful control of cloud formatting, WisprClone keeps your **voice processing and keys on your own MacBook**. Cloud cleanup is optional and explicit. Permissions are powerful on purpose (global dictation), so treat the app like any other trusted system utility: install carefully, configure deliberately, and do not share secrets in dictated text when cloud LLMs are enabled.

---

## Quick reference

| Action | Shortcut / place |
|---|---|
| Start listening | Double‑tap **fn** |
| Stop & process | Tap **fn** once |
| Toggle | **⌘⇧Space** |
| Preferences | Menu bar **Wispr** → Preferences… |
| Start without hotkey | Menu bar **Wispr** → Start Dictation |
| Project on GitHub | [khandelwalakshat50/WhisprClone](https://github.com/khandelwalakshat50/WhisprClone) |

For deeper technical detail (architecture, signing, troubleshooting for developers), see **[PROJECT_HANDBOOK.md](PROJECT_HANDBOOK.md)** and **[README.md](README.md)**.
