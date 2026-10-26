# Sharing WisprClone with Another Mac User

How to give WisprClone to a friend or family member who has their own Mac and their own API keys. They do **not** need Xcode, Terminal skills, or this repository. You send them the finished app; they paste in their own keys.

---

## Part 1 — For you (the sender)

### 1. Make sure your installed app is the latest build

The app you share is the one in `/Applications/WisprClone.app`. If you've changed the code, rebuild and reinstall it first.

### 2. Zip the app

Open Terminal and run:

```bash
ditto -c -k --keepParent /Applications/WisprClone.app ~/Desktop/WisprClone.zip
```

Use `ditto`, not Finder's **Compress** or `zip` — `ditto` keeps the app's code signature intact.

### 3. Send `WisprClone.zip`

AirDrop, Google Drive, iCloud Drive, or a USB stick all work.

### What never to send

| Don't share | Why |
|---|---|
| Your `.env` file | Contains your API keys |
| The `OpenWhisper` project folder | Has your `.env` and is useless to a non-developer |
| `~/Library/Application Support/WisprClone/` | A copy of your keys (`.env`) and debug logs |
| `~/Library/Preferences/com.openwhisper.WisprClone.plist` | Your settings and recent dictation history |
| Your API keys in a message | They should create their own — usage is billed to the key owner |

The app bundle itself contains **no API keys** — it's safe to send.

---

## Part 2 — For them (the recipient)

### What you need

| Requirement | Notes |
|---|---|
| A Mac | **macOS 15 (Sequoia) or newer** — Apple menu → **About This Mac**. Works on Apple Silicon and Intel. |
| Internet | Speech recognition and text cleanup run in the cloud |
| Your own API keys | See [Step 4](#step-4--get-your-api-keys) |

### Step 1 — Install

1. Double-click `WisprClone.zip` to unzip it.
2. Drag **WisprClone.app** into your **Applications** folder.

### Step 2 — Open it the first time (Gatekeeper)

WisprClone isn't from the App Store or a notarized developer, so macOS blocks it the first time.

1. Double-click **WisprClone** in Applications. macOS will say it can't be opened — click **Done** / **Cancel**.
2. Open **System Settings → Privacy & Security**.
3. Scroll down — next to the message about WisprClone, click **Open Anyway**, then confirm with your password.

If **Open Anyway** doesn't appear, open **Terminal** and run this once, then open the app again:

```bash
xattr -dr com.apple.quarantine /Applications/WisprClone.app
```

### Step 3 — Grant permissions

macOS will ask for these; you can also set them in **System Settings → Privacy & Security**:

| Permission | Why it's needed |
|---|---|
| **Microphone** | To hear your voice |
| **Accessibility** | To paste the text into the app you're typing in |
| **Input Monitoring** | To detect the Fn / ⌘⇧Space shortcuts from any app |

After turning these on, **quit and reopen WisprClone** (menu bar **Wispr → Quit WisprClone**, then open it from Applications).

### Step 4 — Get your API keys

| Service | Required? | What it does | Where to get a key |
|---|---|---|---|
| **Deepgram** | **Yes** | Turns speech into text | [console.deepgram.com](https://console.deepgram.com) → API Keys |
| **Groq** | Strongly recommended | Fast cleanup of short dictation (~0.3s) | [console.groq.com/keys](https://console.groq.com/keys) |
| **OpenAI** | Recommended | Cleanup of longer dictation; backup for Groq | [platform.openai.com/api-keys](https://platform.openai.com/api-keys) |
| **Gemini** | Optional | Last-resort backup | [aistudio.google.com/apikey](https://aistudio.google.com/apikey) |

With only Deepgram, dictation still works — you just get Deepgram's own punctuation without the extra cleanup.

### Step 5 — Enter your keys

1. Look for **Wispr** in the menu bar at the top-right of the screen (there's no Dock icon or main window).
2. Click it → **Preferences…**
3. Paste your keys:
   - **Speech** section → **Deepgram API Key**
   - **Formatting** section → **Groq API Key**, **OpenAI API Key**, **Gemini API Key**
4. Leave **Mode** on **Auto Fallback**.

Keys are saved in your Mac's **Keychain** — they stay on your Mac and are only sent to the matching provider. If macOS asks whether WisprClone may access the Keychain, click **Always Allow**.

### Step 6 — Dictate

| Action | MacBook keyboard | Any keyboard |
|---|---|---|
| Start | **Double-tap Fn** | **⌘⇧Space** |
| Stop and paste | **Tap Fn once** | **⌘⇧Space** again |
| Start without a shortcut | Menu bar **Wispr → Start Dictation** | same |

1. Click into the text field where you want the words (Notes, Slack, Mail, a browser…).
2. Start dictation, speak, then stop.
3. The text appears where your cursor was.

On an external Windows-style keyboard, the Fn key usually isn't visible to macOS — use **⌘⇧Space** (often the **Windows key + Shift + Space**).

To find the app in Spotlight, search **WisprClone** (not "OpenWhisper").

---

## Troubleshooting

| Problem | Fix |
|---|---|
| Nothing in the menu bar | Open **WisprClone** from Applications. If the menu bar is crowded, the icon may be hidden behind the notch — quit a few menu bar apps. |
| Shortcut does nothing | Turn on **Input Monitoring** for WisprClone, then quit and reopen it. Or use **Wispr → Start Dictation**. |
| Overlay says **"Accessibility off · copied, press ⌘V"** | Turn on **Accessibility** for WisprClone. Your text is on the clipboard — press **⌘V** to paste it now. |
| Permission is on but paste/shortcuts still fail | In the permission list, select WisprClone, remove it with **−**, add `/Applications/WisprClone.app` again with **+**, then reopen the app. |
| "Deepgram API Key Missing" | Add your Deepgram key in **Preferences…** |
| Text appears without cleanup | Check your Groq / OpenAI keys in Preferences. |
| Recovering text that didn't paste | Your last 10 dictations are listed in **Preferences…** for copying. |

---

## Updating to a newer version

1. The sender makes a new zip (Part 1).
2. Quit WisprClone (**Wispr → Quit WisprClone**).
3. Replace the app in **Applications** with the new one.
4. Open it. Your keys stay in the Keychain. If shortcuts or paste stop working, re-enable **Accessibility** and **Input Monitoring** (see Troubleshooting).

## Uninstalling

1. Quit WisprClone and delete it from **Applications**.
2. Optionally delete `~/Library/Application Support/WisprClone/` (logs) and `~/Library/Preferences/com.openwhisper.WisprClone.plist` (settings and dictation history).
3. Optionally remove WisprClone from **System Settings → Privacy & Security** (Microphone, Accessibility, Input Monitoring).
4. Optionally delete the saved keys in **Keychain Access** (search `com.openwhisper.WisprClone`).

---

## Privacy in one paragraph

Audio is sent to **Deepgram** for transcription. The resulting text (not audio) is sent to whichever cleanup provider handles it — Groq, OpenAI, or Gemini. Each provider bills and sees requests under **the recipient's own keys**, not the sender's. Dictation history stays on the recipient's Mac.

---

## For wider distribution (later)

Sharing with many people, or avoiding the Gatekeeper step, requires an Apple Developer Program membership, **Developer ID** signing, and **notarization**. See `PROJECT_HANDBOOK.md` for that process.
