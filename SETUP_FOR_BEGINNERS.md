# How to Run WisprClone (Beginner Guide)

This guide assumes you have never used Xcode before. Follow the steps in order.  
If something asks for a password, that is normal on a Mac.

---

## What this app does

WisprClone lives in your **menu bar** (top-right of the screen).  
You press a keyboard shortcut, speak, pause, and it types what you said into whatever app you were using (Notes, Slack, email, etc.).

It does **not** show a normal app icon in the Dock.

---

## Before you start — checklist

You need:

1. A Mac running **macOS Sequoia (15)** or newer  
   - Click the Apple menu → **About This Mac** to check.
2. An internet connection (first launch downloads speech models; cloud formatting needs the web).
3. About **30–60 minutes** the first time (mostly waiting for downloads).
4. At least one API key already in your `.env` file (OpenAI and/or Groq) — if someone set that up for you, you can skip the “API keys” section.

---

## Step 1 — Install Xcode (the free Apple developer app)

WisprClone is built with Apple’s tools. You run it through **Xcode**.

1. Open the **App Store** on your Mac.
2. Search for **Xcode**.
3. Click **Get** / **Install** (it is large — several GB; go make tea).
4. When install finishes, open **Xcode** once.
5. If it asks to install **additional components**, click **Install** and wait.
6. Agree to the license if asked.

You only need to do this once.

---

## Step 2 — Open the project

1. Open **Finder**.
2. Go to the folder: **OpenWhisper** (usually in your user folder, or wherever it was saved).
3. Double-click the file named:

   **`WisprClone.xcodeproj`**

   (It looks like a blue blueprint / Xcode icon.)

4. Xcode opens. Wait until the progress spinner at the top stops.

### If Xcode says packages need to resolve

You may see a message about **WhisperKit** or Swift packages.

1. In the menu bar, click **File**.
2. Click **Packages** → **Resolve Package Versions** (or **Update to Latest Package Versions**).
3. Wait until downloading finishes. This can take several minutes.

---

## Step 3 — Put in your API keys (if not already done)

The app can clean up your wording using **Groq** and/or **OpenAI**.

1. In Finder, open the **OpenWhisper** folder.
2. Find the file named **`.env`**  
   - If you do not see it: press **Command + Shift + .** (period) to show hidden files.
3. Open `.env` with **TextEdit**.
4. You should see two lines like:

   ```
   OPENAI_API_KEY=...
   GROQ_API_KEY=...
   ```

5. Replace the text after each `=` with your real key (no spaces).
6. Save (**Command + S**) and close.

You only need **one** key to use cloud formatting. Both is fine.

**Keep this file private.** Do not email it or put it on GitHub.

---

## Step 4 — Run the app from Xcode

1. At the top of the Xcode window, make sure the scheme says **WisprClone** (next to a stop/play area).
2. Next to that, choose **My Mac** (not an iPhone).
3. Click the big **Play** button (▶) in the top-left  
   — or press **Command + R**.
4. The first build can take several minutes. Wait for “Build Succeeded”.
5. If macOS asks whether to allow the app, click **Allow** / **Open**.

### What you should see

- In **Debug** runs from Xcode: a **Dock icon** named WisprClone (so you know it launched).
- In the **menu bar** (top-right): a mic icon plus the word **Wispr**.
  - On a MacBook with a notch, check the **»** overflow chevron on the right side of the menu bar.
- Click **Wispr** → you should see **Start Dictation**, Preferences, About, Quit.

If there is no icon: make sure you pressed **Play ▶** (⌘R), not only Build. Check Xcode’s bottom console for crashes.

### Keyboard shortcut does nothing?

1. Click the **Wispr** menu → **Start Dictation** (this works without the hotkey).
2. Enable **Input Monitoring** + **Accessibility** for **WisprClone** (and also **Xcode** if you run from Xcode):
   - Apple menu → System Settings → Privacy & Security → Input Monitoring / Accessibility.
3. Quit WisprClone completely, then press Play ▶ again.
4. Then try **⌘⇧Space** again.

--- 

## Step 5 — Turn on Mac permissions (required)

Without these, the app cannot hear you or type into other apps.

### A. Open Preferences in the app

1. Click the waveform icon in the menu bar.
2. Click **Preferences…**

### B. Grant each permission

In Preferences, use **Open Settings** next to each item, or go manually:

**Apple menu → System Settings → Privacy & Security**

Turn **on** WisprClone (or Xcode, if that’s how it appears) for:

| Permission | Why |
|---|---|
| **Microphone** | So it can hear you |
| **Accessibility** | So it can paste text into other apps |
| **Input Monitoring** | So the keyboard shortcut works globally |
| **Speech Recognition** (optional) | Only if you pick “Apple Speech” in Preferences |

After changing a permission, you may need to:

1. Quit the app (menu bar → **Quit WisprClone**).
2. In Xcode, click Play ▶ again.

In Preferences you can also click **Request Missing…** then **Refresh Status**.

---

## Step 6 — Try dictation (first successful use)

1. Open **Notes** (or any app where you can type).
2. Click inside a note so the cursor is blinking.
3. Press together:

   **Command + Shift + Space**

   (⌘ ⇧ Space)

   Alternate: **double-tap the Left Command key** (the ⌘ key on the left side of the space bar).

4. A small floating panel should appear near the bottom of the screen (“Listening…”).
5. Speak normally for as long as you need. Pauses do not stop recording.
6. Tap the **Left Command key once** to stop and transcribe.
7. The panel may show Transcribing → Formatting → Done.
8. Your words should appear in Notes.

The **first** transcription may be slow while the speech model downloads. Later uses are faster.

---

## Everyday use (after the first setup)

You do **not** need to rebuild every day, but while developing from source you usually:

1. Open `WisprClone.xcodeproj` in Xcode.
2. Press **Command + R** (Play).
3. Double-tap **Left ⌘** to start, then tap **Left ⌘** once to stop.  
   You can also use **⌘⇧Space** to toggle recording.

To stop the app: menu bar waveform → **Quit WisprClone**.

---

## Optional: local cleaning with Ollama

If you want formatting **without** sending text to Groq/OpenAI:

1. Install [Ollama](https://ollama.com) from their website.
2. Open **Terminal** and run:

   ```bash
   ollama pull qwen3:8b
   ```

3. Leave Ollama running.
4. In WisprClone Preferences, set Formatting to **Local Only** or leave **Auto Fallback**.

If Ollama is off, Auto Fallback will try Groq, then OpenAI.

---

## If something goes wrong

### “I don’t see the menu bar icon”

- Make sure you pressed Play in Xcode and the build succeeded.
- Check the menu bar overflow (» chevron) on smaller screens / with notch.
- Quit and run again with Command + R.

### “Shortcut does nothing”

- Enable **Input Monitoring** for the app.
- Quit and relaunch after granting it.
- Try double-tap **Right** ⌘ (not the left one).

### “It listens but nothing is typed”

- Enable **Accessibility**.
- Click into a text field first (cursor must be active).
- Check Preferences for error messages / API keys.

### “Microphone Unavailable”

- Enable **Microphone** in System Settings.
- Check the Mac isn’t using the mic exclusively in another app.
- Try unplugging/replugging a USB headset.

### Xcode is confusing / red errors

- Install the newest **Xcode** from the App Store.
- **File → Packages → Resolve Package Versions**.
- Ask someone technical to open the **Issue Navigator** (triangle icon) and read the first red error.

---

## Quick reference card

| Want to… | Do this |
|---|---|
| Start the app | Open Xcode → Play ▶ (⌘R) |
| Dictate | Click a text field → double-tap **Left ⌘** → speak → tap **Left ⌘** |
| Open settings | Menu bar waveform → Preferences… |
| Quit | Menu bar waveform → Quit |
| Edit API keys | Edit `.env` or Preferences → API key fields |

---

## Privacy reminder

- Your `.env` file holds secret keys — treat it like a password.
- Do not screenshot Preferences with keys visible and share that online.
