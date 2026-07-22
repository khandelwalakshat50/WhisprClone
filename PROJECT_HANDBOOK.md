# WisprClone Project Handbook

## 1. Introduction

WisprClone is a native macOS AI dictation application inspired by products such
as Wispr Flow. It runs as a lightweight menu-bar utility, records speech from
the microphone, transcribes the recording locally or with Apple Speech, cleans
and restructures the transcript with a configurable language model, and inserts
the final text into whichever application currently owns keyboard focus.

The application is intended to make voice input feel like a system capability
rather than a separate transcription tool. It can be used in Notes, Mail,
Messages, browsers, editors, IDEs, document tools, and most other macOS
applications that accept text.

The normal interaction is:

1. Double-tap the **left Command key** to begin recording.
2. Speak naturally for as long as needed. Pauses do not stop recording.
3. Tap the **left Command key once** to stop.
4. WisprClone transcribes, formats, and inserts the text at the current cursor.

`Command + Shift + Space` remains available as a recording toggle.

WisprClone is currently a personal/development application rather than a
notarized public product. A standalone Release build can run without Xcode on
the Mac on which it was built, but distribution to unrelated Macs requires
additional signing and notarization work described later in this document.

---

## 2. What the application does

### 2.1 Capture

WisprClone installs a system-wide hotkey listener. When dictation starts, it
opens the selected microphone with `AVAudioEngine`, streams PCM buffers to the
overlay for a live microphone-reactive waveform, and writes the same audio to a
temporary WAV file.

Recording ends manually. Voice activity detection is still used to identify
speech and drive visual state, but silence does not terminate the session. A
ten-minute emergency timeout prevents an accidentally abandoned recording from
running forever.

### 2.2 Transcription

The application supports two speech engines:

- **WhisperKit** — local Whisper inference through Core ML. The model is
  downloaded to Application Support, prewarmed at launch, and cached in memory.
  Audio stays on the Mac during transcription.
- **Apple Speech** — Apple's `SFSpeechRecognizer`, configured to request
  on-device recognition. Availability depends on the language, model support,
  and macOS configuration.

WhisperKit is the default engine.

### 2.3 AI formatting

The raw transcript is sent to a post-processing prompt that:

- removes filler words and false starts;
- repairs punctuation, capitalization, and grammar;
- preserves names, technical terms, meaning, and tone;
- executes spoken formatting commands such as “new paragraph,” “bullet
  points,” and dictated punctuation;
- applies corrections such as “scratch that,” “no wait,” or “change X to Y”;
- returns only the polished text and does not answer questions contained in the
  transcript.

Formatting providers are:

- **Ollama** — local HTTP service at `http://localhost:11434`;
- **Groq** — cloud OpenAI-compatible API;
- **OpenAI** — cloud Chat Completions API.

The supported routing modes are Local Only, Groq Only, OpenAI Only, and Auto
Fallback. Auto Fallback currently tries:

```text
Ollama → Groq → OpenAI
```

This matters for privacy: in Auto Fallback mode, a transcript may leave the Mac
if Ollama is unavailable and a cloud API key is configured.

### 2.4 Text insertion

The primary insertion strategy is:

1. Back up the current pasteboard.
2. Put the formatted transcript on the pasteboard.
3. Synthesize `Command + V`.
4. Keep the transcript available long enough for the target app to consume it.
5. Restore the previous pasteboard later, provided no other application changed
   the pasteboard in the meantime.

If clipboard injection fails, WisprClone attempts direct insertion through the
macOS Accessibility API.

### 2.5 User interface

WisprClone uses:

- a menu-bar status item;
- a Preferences window;
- a non-activating floating recording overlay;
- a microphone-reactive liquid waveform;
- a cyan/blue recording state;
- a blue-violet processing state;
- spring-driven state transitions and a soft completion dismissal.

The panel does not intentionally take focus from the target application. Its
stop button provides a mouse alternative to the keyboard stop gesture.

### 2.6 Provider usage history

Preferences shows successful formatting-provider usage over the last 48 hours:

- Ollama count;
- Groq count;
- OpenAI count;
- last successful use of each provider;
- most recently successful provider.

The history stores only provider names and timestamps. It does not store API
keys, transcript text, generated text, or audio.

---

## 3. End-to-end architecture

```text
Global hotkey / menu command
            │
            ▼
    DictationCoordinator
            │
            ├── request/check macOS permissions
            │
            ├── AudioRecorder ──► temporary WAV file
            │         │
            │         └──► VoiceActivityDetector
            │                    │
            │                    └──► live overlay audio level
            │
            ├── WhisperKitRecognizer OR AppleSpeechRecognizer
            │                    │
            │                    ▼
            │              raw transcript
            │
            ├── LLMFormattingService
            │       ├── OllamaClient
            │       ├── GroqClient
            │       └── OpenAIClient
            │                    │
            │                    ▼
            │             polished transcript
            │
            └── TextInjector
                    ├── ClipboardInjection
                    └── AccessibilityInjection
                                  │
                                  ▼
                         focused macOS application
```

The central application state progresses through:

```text
idle
  → listening / detectingSpeech
  → transcribing
  → formatting
  → injecting
  → success or failure
  → idle
```

`AppDelegate` owns the long-lived application services. `DictationCoordinator`
owns each active dictation session. UI objects observe the state stores rather
than implementing speech or network behavior directly.

---

## 4. Technology stack

### 4.1 Language and concurrency

- **Swift 6**
- Complete strict-concurrency checking
- Swift async/await and structured tasks
- `@MainActor` for application and UI coordination
- `Sendable` boundaries for callbacks crossing queues
- `Synchronization.Mutex` for shared non-actor state

### 4.2 Native macOS frameworks

- **AppKit**
  - `NSApplication` lifecycle
  - menu-bar status item and menus
  - Preferences window
  - non-activating `NSPanel`
  - pasteboard access
- **SwiftUI**
  - recording overlay
  - animated Canvas waveform
  - Preferences form
- **Combine**
  - observable configuration, usage, and overlay presentation models
- **AVFoundation**
  - microphone authorization
  - `AVAudioEngine`
  - PCM audio buffers
  - WAV file writing
- **Speech**
  - Apple Speech authorization and transcription
- **ApplicationServices / Accessibility**
  - trust checks
  - focused-element text insertion
- **CoreGraphics**
  - global event taps
  - synthetic keyboard events
- **Carbon.HIToolbox**
  - virtual key constants
- **Security.framework**
  - Keychain storage
- **Foundation**
  - URL loading, JSON, filesystem, persistence, and dates
- **OSLog**
  - structured diagnostic and performance logging

### 4.3 Swift Package Manager

The direct package dependency is:

- **WhisperKit 0.18.0** — local Whisper inference and Core ML model management.

Resolved transitive packages include Swift Transformers, Swift Collections,
Swift Crypto, Swift ASN.1, Swift Jinja, yyjson, and Swift Argument Parser.
Exact versions are locked in:

```text
WisprClone.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved
```

### 4.4 External services

- Groq Chat Completions API
- OpenAI Chat Completions API
- Optional local Ollama server
- Hugging Face/WhisperKit model download infrastructure

---

## 5. Repository structure and codebase overview

```text
OpenWhisper/
├── .env.example
├── .gitignore
├── README.md
├── SETUP_FOR_BEGINNERS.md
├── PROJECT_HANDBOOK.md
├── WisprClone.xcodeproj/
└── WisprClone/
    ├── App/
    ├── Audio/
    ├── Hotkeys/
    ├── Injection/
    ├── LLM/
    ├── MenuBar/
    ├── Overlay/
    ├── Permissions/
    ├── Resources/
    ├── Security/
    ├── Settings/
    ├── Shared/
    ├── Speech/
    └── WisprClone.entitlements
```

### 5.1 Application lifecycle

#### `WisprClone/App/AppMain.swift`

Creates the `NSApplication`, retains the delegate, selects the application
activation policy, and starts the macOS event loop. Release behaves as a
menu-bar accessory application. Debug builds can expose a Dock presence for
development convenience.

#### `WisprClone/App/AppDelegate.swift`

The composition root. It creates and retains:

- `RecordingStateStore`;
- `ConfigurationStore`;
- `PermissionManager`;
- `LLMUsageStore`;
- `OverlayPresentationModel`;
- `MenuBarController`;
- `OverlayManager`;
- `SettingsWindowController`;
- `DictationCoordinator`.

It also applies the selected appearance, handles application termination, and
nudges the user when critical permissions are missing.

#### `WisprClone/App/DictationCoordinator.swift`

Orchestrates the complete dictation pipeline. Important responsibilities:

- starts and stops global hotkeys;
- requests microphone and speech permissions;
- manages manual recording termination;
- creates the VAD and forwards live audio levels;
- caches the WhisperKit recognizer;
- invokes transcription;
- selects formatting clients and credentials;
- records successful provider usage;
- injects the final text;
- maps failures into user-visible recording states;
- cleans up temporary audio.

This is the first file to inspect when debugging an end-to-end pipeline failure.

### 5.2 Audio

#### `WisprClone/Audio/AudioPermissions.swift`

A small microphone-permission helper. Most application permission coordination
is performed by `PermissionManager`.

#### `WisprClone/Audio/AudioRecorder.swift`

Owns `AVAudioEngine`, installs an input-node tap, writes buffers to a temporary
WAV file, and forwards buffers to the VAD. Audio state is serialized on a
dedicated dispatch queue.

#### `WisprClone/Audio/VoiceActivityDetector.swift`

Calculates RMS energy from PCM samples. It identifies the start of speech and a
silence interval and emits continuous RMS values for the reactive overlay.
Silence events do not currently stop recording; manual stop is intentional.

### 5.3 Hotkeys

#### `WisprClone/Hotkeys/GlobalHotkeyManager.swift`

Installs a `CGEventTap` and uses `NSEvent` monitoring as a fallback. It supports:

- double-tap Left Command to begin;
- single Left Command to stop during recording;
- `Command + Shift + Space` to toggle.

Input Monitoring is required for reliable system-wide capture. The manager runs
the Core Graphics event tap on a dedicated thread and forwards actions to the
main actor.

### 5.4 Speech recognition

#### `WisprClone/Speech/SpeechRecognizer.swift`

Defines the speech-recognition abstraction and engine factory concepts.

#### `WisprClone/Speech/WhisperKitRecognizer.swift`

Loads WhisperKit lazily, prewarms it at application launch, and caches the
pipeline across sessions. Models are stored under Application Support rather
than Documents to avoid folder privacy failures.

#### `WisprClone/Speech/AppleSpeechRecognizer.swift`

Transcribes the temporary audio file through `SFSpeechRecognizer`. It requests
on-device recognition and protects its continuation against multiple callback
resumptions.

### 5.5 Language-model formatting

#### `WisprClone/LLM/TextFormatter.swift`

Defines the formatting protocol and the system prompt. The prompt is a major
behavioral component: it explains cleanup, spoken formatting commands,
self-correction handling, and the requirement to output text rather than answer
the transcript.

#### `WisprClone/LLM/LLMFormattingService.swift`

Routes each request to Ollama, Groq, OpenAI, or the automatic fallback chain.
It sanitizes model output and records the provider that successfully produced
the final text.

#### `WisprClone/LLM/OpenAICompatibleChat.swift`

Shared HTTP implementation used by Groq and OpenAI. It builds Chat Completions
requests, adds authorization, handles timeouts and HTTP failures, decodes the
response, and validates non-empty content.

#### `WisprClone/LLM/GroqClient.swift`

Groq-specific endpoint, model, timeout, and API-key wrapper.

#### `WisprClone/LLM/OpenAIClient.swift`

OpenAI-specific endpoint, model, timeout, and API-key wrapper.

#### `WisprClone/LLM/OllamaClient.swift`

Calls the local Ollama `/api/chat` endpoint and can retry with a fallback local
model.

#### `WisprClone/LLM/LLMUsageStore.swift`

Persists successful provider names and timestamps. Preferences displays a
rolling 48-hour view; events are retained for up to 30 days. No transcript or
credential data is recorded.

> `WisprClone/LLM/TextFormatter copy.swift` is an unused duplicate file and is
> not included in the Xcode target. It should be removed unless intentionally
> retained as a manual backup. Adding it to the target would create duplicate
> declarations.

### 5.6 Text insertion

#### `WisprClone/Injection/TextInjector.swift`

Coordinates the preferred clipboard strategy and Accessibility fallback.

#### `WisprClone/Injection/ClipboardInjection.swift`

Backs up the pasteboard, posts `Command + V`, waits for delivery, and restores
the original clipboard without overwriting newer clipboard activity.

#### `WisprClone/Injection/AccessibilityInjection.swift`

Finds the focused Accessibility element and attempts direct selected-text or
value mutation.

### 5.7 Overlay

#### `WisprClone/Overlay/FloatingPanel.swift`

Defines a borderless, non-activating panel above normal windows and across
Spaces/full-screen applications.

#### `WisprClone/Overlay/OverlayManager.swift`

Owns panel lifetime, screen positioning, show/hide animation, auto-dismiss, and
the persistent observable presentation model.

#### `WisprClone/Overlay/StatusView.swift`

Implements the premium graphite/glass overlay, microphone-reactive liquid
Canvas waveform, processing-energy state, ambient light, spring motion, and
tactile stop control.

### 5.8 Menu bar

#### `WisprClone/MenuBar/MenuBarController.swift`

Creates the menu-bar item, status appearance, Start Dictation command,
Preferences command, About panel, Quit command, and Debug overlay preview.

### 5.9 Settings and persistence

#### `WisprClone/Settings/ConfigurationStore.swift`

Publishes preferences, saves non-secret settings to UserDefaults, seeds API
keys from the environment/Keychain, and writes edited credentials to Keychain.

#### `WisprClone/Settings/SettingsWindow.swift`

Builds the Preferences UI for speech, formatting, credentials, provider usage,
appearance, hotkeys, and permissions.

### 5.10 Permissions and security

#### `WisprClone/Permissions/PermissionManager.swift`

Checks, requests, and opens System Settings for Microphone, Speech Recognition,
Accessibility, and Input Monitoring.

#### `WisprClone/Security/KeychainStore.swift`

Stores OpenAI and Groq credentials as generic-password Keychain records.

#### `WisprClone/Security/EnvLoader.swift`

Loads process-environment and `.env` credentials, caches them safely, and
mirrors discovered values to Application Support.

### 5.11 Shared infrastructure

#### `WisprClone/Shared/RecordingState.swift`

Defines all pipeline states and user-facing status text.

#### `WisprClone/Shared/Configuration.swift`

Defines speech engines, formatting modes, themes, and the complete
configuration snapshot.

#### `WisprClone/Shared/Constants.swift`

Contains bundle, hotkey, audio, model, injection, and overlay constants.

#### `WisprClone/Shared/AppError.swift`

Defines localized application-domain errors.

#### `WisprClone/Shared/AppLogger.swift`

Provides categorized `OSLog` loggers and timed-operation helpers.

### 5.12 Resources and project metadata

- `WisprClone/Resources/Info.plist` contains bundle metadata, usage
  descriptions, minimum macOS information, and menu-bar-only configuration.
- `WisprClone/Resources/Assets.xcassets` contains colors and app-icon slots.
- `WisprClone/WisprClone.entitlements` contains runtime entitlements.
- `WisprClone.xcodeproj/project.pbxproj` contains target, source, signing,
  package, and build configuration.
- `WisprClone.xcodeproj/xcshareddata/xcschemes/WisprClone.xcscheme` contains
  shared Debug/Release launch and archive actions.

---

## 6. Required macOS permissions

macOS privacy permissions are managed by the Transparency, Consent, and Control
system (TCC). They cannot be bundled into the application or copied from another
Mac. The user must approve them.

### 6.1 Microphone

**Why it is required:** captures speech through `AVAudioEngine`.

**How to grant it:**

1. Start a dictation or open Preferences and choose **Request Missing…**.
2. Accept the macOS microphone prompt.
3. Alternatively open:
   **System Settings → Privacy & Security → Microphone**.
4. Enable WisprClone.
5. Quit and reopen the application if the status does not update immediately.

### 6.2 Speech Recognition

**Why it is required:** used only when Apple Speech is selected.

**How to grant it:**

1. Select Apple Speech in Preferences or choose **Request Missing…**.
2. Accept the Speech Recognition prompt.
3. Alternatively open:
   **System Settings → Privacy & Security → Speech Recognition**.
4. Enable WisprClone and relaunch it.

WhisperKit does not require Speech Recognition permission because it performs
local inference directly.

### 6.3 Accessibility

**Why it is required:** allows text insertion into another application's
focused control and supports synthetic paste behavior.

**How to grant it:**

1. Open **System Settings → Privacy & Security → Accessibility**.
2. Find WisprClone and enable its switch.
3. If it is absent, click **+** and choose:
   `/Applications/WisprClone.app`.
4. Quit WisprClone completely and reopen it.

### 6.4 Input Monitoring

**Why it is required:** allows the global hotkey event tap to observe keyboard
events while other applications are active.

**How to grant it:**

1. Open **System Settings → Privacy & Security → Input Monitoring**.
2. Enable WisprClone.
3. If it is absent, click **+** and select:
   `/Applications/WisprClone.app`.
4. Quit and reopen WisprClone.

### 6.5 Why a permission may appear enabled but still be denied

TCC grants are associated with application identity, signature, and sometimes
path. Common causes are:

- approving an old Debug build and then launching the Release build;
- changing the signing certificate;
- repeatedly using ad-hoc signing;
- moving or replacing the `.app`;
- having Xcode and `/Applications/WisprClone.app` running simultaneously;
- not relaunching after changing the toggle.

Recovery procedure:

1. Quit every WisprClone process.
2. Remove stale WisprClone entries from Accessibility/Input Monitoring.
3. Launch only `/Applications/WisprClone.app`.
4. Add and enable that exact application.
5. Relaunch once.

For development troubleshooting, TCC entries can be reset from Terminal:

```bash
tccutil reset Accessibility com.openwhisper.WisprClone
tccutil reset ListenEvent com.openwhisper.WisprClone
```

This intentionally removes approval and requires a new grant.

### 6.6 Permissions WisprClone does not request

The app does not request camera, Screen Recording, location, contacts,
calendars, photos, or full-disk access.

---

## 7. Entitlements and runtime security model

The app currently has Hardened Runtime enabled and App Sandbox disabled.

Sandboxing is disabled because global event monitoring and cross-application
text insertion are central features that do not fit a conventional sandboxed
design.

The entitlement file currently contains audio input and Apple Events-related
entries. The source code does not presently send Apple Events. The broad
temporary Apple Events exception should therefore be reviewed and preferably
removed before public distribution.

`LSUIElement` is enabled in `Info.plist`, so the Release application behaves as
a menu-bar utility without a normal Dock icon.

---

## 8. Configuration, credentials, and data locations

### 8.1 Non-secret preferences

Stored in UserDefaults for bundle identifier:

```text
com.openwhisper.WisprClone
```

The corresponding file is normally:

```text
~/Library/Preferences/com.openwhisper.WisprClone.plist
```

It includes model names, engine choices, formatting mode, temperature, timeout,
theme, and provider usage timestamps.

### 8.2 API keys

Groq and OpenAI keys are stored in macOS Keychain:

```text
Service: com.openwhisper.WisprClone
Accounts: groq_api_key and openai_api_key
```

The records use `WhenUnlockedThisDeviceOnly`. This means:

- the key is available only while the Mac's Keychain is unlocked;
- it is intentionally tied to the current device;
- it does not automatically migrate to another Mac;
- it must be entered again on the destination Mac.

### 8.3 `.env`

Development keys can be supplied with:

```dotenv
GROQ_API_KEY=...
OPENAI_API_KEY=...
```

Never commit the real `.env` file. `.env.example` should contain names and
placeholders only.

The loader can also mirror values to:

```text
~/Library/Application Support/WisprClone/.env
```

That mirror is plaintext. See the security section before using this on a
shared or managed computer.

### 8.4 Whisper models

WhisperKit model files are stored in:

```text
~/Library/Application Support/WisprClone/Models/
```

The first setup requires a network download and enough free disk space. Model
loading and Core ML specialization can make the first run slower.

### 8.5 Temporary recordings

Recording files use names similar to:

```text
wispr-<UUID>.wav
```

They are created in the system temporary directory and deleted at the end of a
normal session. A crash or forced termination can leave a temporary file until
macOS cleans the temporary directory.

### 8.6 Logs

Operational logs use the subsystem:

```text
com.openwhisper.WisprClone
```

Recent application logs can be inspected with:

```bash
/usr/bin/log show --last 10m \
  --predicate 'subsystem == "com.openwhisper.WisprClone"' \
  --info --debug
```

Do not add API keys or full transcripts to logs.

---

## 9. Initial setup on the development Mac

### 9.1 Requirements

- A Mac running macOS 15 or later
- Xcode capable of building Swift 6 projects
- Internet access for Swift packages and the initial Whisper model
- An Apple Development signing identity for source builds
- A Groq/OpenAI key, or a working local Ollama installation

### 9.2 Source setup

1. Open `WisprClone.xcodeproj` in Xcode.
2. Allow Swift Package Manager to resolve packages.
3. Select the WisprClone scheme and **My Mac**.
4. In **Signing & Capabilities**, select your own development team if the
   configured team is unavailable.
5. Add keys through Preferences or create a local `.env`.
6. Build and run.
7. Grant Microphone, Accessibility, and Input Monitoring.
8. Grant Speech Recognition only if Apple Speech will be used.

### 9.3 Ollama setup

Ollama is optional. If used:

1. Install Ollama independently.
2. Start its local service.
3. Pull the model configured in Preferences, for example:

```bash
ollama pull qwen3:8b
```

4. Confirm the server responds at `http://localhost:11434`.
5. Select Local Only or Auto Fallback.

If Ollama is not installed, choose Groq Only or OpenAI Only to avoid an
unnecessary failed local attempt.

---

## 10. Building a standalone application

Xcode is required to build the source, but it is not required to run the
finished application.

### 10.1 Build Release

From the repository root:

```bash
xcodebuild \
  -project "WisprClone.xcodeproj" \
  -scheme "WisprClone" \
  -configuration Release \
  -derivedDataPath "$PWD/.build/Standalone" \
  build
```

The resulting application is:

```text
.build/Standalone/Build/Products/Release/WisprClone.app
```

### 10.2 Install locally

```bash
rm -rf "/Applications/WisprClone.app"
ditto \
  ".build/Standalone/Build/Products/Release/WisprClone.app" \
  "/Applications/WisprClone.app"
open "/Applications/WisprClone.app"
```

Verify its signature:

```bash
codesign --verify --deep --strict --verbose=2 \
  "/Applications/WisprClone.app"
```

After installation, launch it with Spotlight or from Applications. Xcode can be
closed.

### 10.3 Start at login

To launch automatically:

1. Open **System Settings → General → Login Items**.
2. Add `/Applications/WisprClone.app` under **Open at Login**.

The app then appears in the menu bar after login.

### 10.4 Updating the standalone application

Changing source files does not update `/Applications/WisprClone.app`.
Rebuild Release, quit the running process, replace the installed app, and
relaunch it. Keep the bundle identifier and signing identity stable to minimize
permission churn.

---

## 11. Using WisprClone on another MacBook

There are two practical migration methods.

### Method A — build from source on the destination Mac

This is the recommended method during development.

#### On the original Mac

1. Ensure the real `.env` is not included in the transferred source.
2. Copy the project folder using a private transfer method such as AirDrop,
   encrypted external storage, or a private source-control repository.
3. Optionally copy the Whisper model directory separately to avoid downloading
   it again.

#### On the destination Mac

1. Install Xcode.
2. Copy the project to a local development folder.
3. Open `WisprClone.xcodeproj`.
4. Let Xcode resolve Swift packages.
5. Select the destination owner's Apple Development team under Signing.
6. Build a Release application using the command in the previous section.
7. Install it into `/Applications`.
8. Enter Groq/OpenAI keys again in Preferences.
9. Grant Microphone, Accessibility, Input Monitoring, and optionally Speech
   Recognition.
10. Run a short test in Notes.

Do not copy macOS TCC databases. Permissions must be granted normally on the
destination Mac.

#### Optional model transfer

Copy:

```text
~/Library/Application Support/WisprClone/Models/
```

to the same location on the destination Mac. If macOS version or hardware
architecture differs, Core ML may still rebuild compiled artifacts. Deleting
the copied model and allowing a fresh download is the safest fallback.

#### Optional preferences transfer

Settings can be recreated through Preferences. If exact migration is needed,
copy:

```text
~/Library/Preferences/com.openwhisper.WisprClone.plist
```

while WisprClone is not running. Provider usage history is included in this
preferences domain.

API keys will not be transferred by this file.

#### Ollama migration

Ollama is a separate product. On the new Mac:

1. Install Ollama.
2. Pull the configured models again.
3. Start its service.
4. Confirm the selected model name matches WisprClone Preferences.

### Method B — distribute a signed and notarized application

This is the correct approach for non-developers.

The present Apple Development-signed build is not a finished public
distribution artifact. Before sharing broadly:

1. Enroll in the Apple Developer Program.
2. Create a **Developer ID Application** certificate.
3. Change Release signing to Developer ID.
4. Remove unnecessary broad entitlements.
5. Archive the app in Xcode.
6. Export the Developer ID-signed application.
7. Submit it to Apple's notarization service.
8. Staple the notarization ticket.
9. Package the app in a signed DMG or installer.
10. Test installation on a clean Mac account and a second Mac.

Typical command-line notarization flow:

```bash
xcrun notarytool submit "WisprClone.zip" \
  --keychain-profile "YOUR_NOTARY_PROFILE" \
  --wait

xcrun stapler staple "WisprClone.app"

spctl --assess --type execute --verbose=4 "WisprClone.app"
```

Do not tell recipients to disable Gatekeeper globally. Proper signing and
notarization are the secure solution.

### What must be reconfigured on every other Mac

- Accessibility permission
- Input Monitoring permission
- Microphone permission
- Speech Recognition permission when applicable
- Groq/OpenAI credentials
- Ollama installation and models, if used
- login-item preference

### Apple Silicon and Intel Macs

The installed Release build should be checked with:

```bash
lipo -archs "/Applications/WisprClone.app/Contents/MacOS/WisprClone"
```

A universal build contains both `arm64` and `x86_64`. Otherwise rebuild on the
destination architecture or configure Xcode to produce a universal archive.

---

## 12. Common roadblocks and recovery

### 12.1 Build succeeds but no app appears

Release is a menu-bar application. Look for **Wispr** in the menu bar. It does
not normally show a Dock icon. Confirm it is running:

```bash
pgrep -lx WisprClone
```

### 12.2 Two copies respond to the hotkey

This happens when an Xcode Debug process and `/Applications/WisprClone.app` run
at the same time. Quit both, then open only the installed application.

### 12.3 Hotkeys do nothing

- Confirm Input Monitoring is granted to the exact running app.
- Relaunch after granting.
- Confirm Accessibility is also enabled.
- Remove stale Debug entries.
- Use the menu-bar Start Dictation command to isolate whether only the event tap
  is failing.

### 12.4 Accessibility or Input Monitoring says Denied despite an enabled toggle

The toggle probably belongs to an older signature/path. Follow the TCC recovery
procedure in Section 6.5.

### 12.5 “Model not found”

Possible causes:

- invalid Whisper model name;
- interrupted download;
- insufficient disk space;
- network failure;
- corrupted model metadata;
- an old model stored in a protected Documents location.

Current builds use:

```text
~/Library/Application Support/WisprClone/Models/
```

Quit the app, remove only the corrupted model directory, relaunch, and allow a
fresh download.

### 12.6 Transcribing takes a long time

- First launch downloads and compiles the model.
- Wait for background prewarming before the first dictation.
- Use the Release build rather than Debug.
- Select a smaller Whisper model.
- Ensure only one app instance is running.
- Check logs to separate recording, transcription, LLM, and injection timing.

### 12.7 “LLM Offline”

- Select Groq Only or OpenAI Only if Ollama is not installed.
- Verify the appropriate key is present.
- Confirm the model name is valid for that provider.
- Check internet access.
- For Ollama, confirm the server and model are available.

### 12.8 Text inserted is the old clipboard content

The application intentionally delays clipboard restoration so the target app
has time to consume the transcript. If the issue returns:

- test in Notes;
- check Accessibility permission;
- make sure no clipboard manager immediately rewrites the pasteboard;
- inspect injection logs;
- increase paste-delivery timing cautiously.

### 12.9 Text appears in the wrong application

The app inserts into the currently focused control. Click the intended text
field immediately before starting dictation. The floating panel is
non-activating and should preserve focus.

### 12.10 Dictated instructions are typed literally

The prompt supports text-formatting commands, not arbitrary Mac automation.
Examples such as “new paragraph” and “scratch that” should be interpreted.
Commands such as “open Safari” or “send this email” require a separate
intent/automation subsystem and are intentionally not executed.

### 12.11 Apple Speech stalls

Apple Speech availability varies. Switch to WhisperKit, confirm Speech
Recognition permission, and inspect logs. The current Apple Speech path does
not have a separate explicit recognition timeout, which is a future hardening
opportunity.

### 12.12 Keychain repeatedly asks for the login password

The password requested is the Mac login Keychain password. A changed app
signature or Keychain access-control state may cause repeated prompts. Use a
stable signed build and select **Always Allow** only if you trust the exact
application.

---

## 13. Security and privacy review

### 13.1 Cloud transcript disclosure

Groq and OpenAI receive transcript text when selected. Auto Fallback may cross
from local processing to cloud processing automatically. Sensitive dictation
should use Local Only with a trusted local Ollama model, and local WhisperKit
for speech recognition.

### 13.2 Plaintext `.env` files

The repository `.env` and Application Support mirror are plaintext credentials.
Risks include:

- accidental source-control commits;
- backups;
- other local users or processes with sufficient access;
- screen sharing or support bundles;
- accidental transfer to another computer.

Recommended hardening:

- prefer Keychain after initial setup;
- restrict `.env` permissions to the current user;
- delete unnecessary plaintext mirrors;
- never log key values;
- rotate any key that may have been exposed.

### 13.3 Keychain limitations

Keychain storage is substantially safer than plaintext, but:

- malware running as the user may attempt access;
- the app can read its own keys while the Keychain is unlocked;
- development-signature changes can trigger prompts;
- `ThisDeviceOnly` records do not migrate.

### 13.4 Unsandboxed process

The app is intentionally unsandboxed. This expands its capabilities and its
potential impact if compromised. Keep dependencies updated, minimize
entitlements, validate network responses, and distribute only signed builds.

### 13.5 Accessibility trust

Accessibility allows control of other applications. A compromised dictation app
could read or change focused UI content. WisprClone should:

- request only when required;
- avoid collecting unrelated UI data;
- never transmit focused-field content;
- keep direct Accessibility operations narrowly scoped;
- clearly explain the permission.

### 13.6 Input Monitoring

Input Monitoring can expose keyboard activity. The current implementation
filters for specific hotkey events and should not store typed keys. Future
changes must not add keystroke logging or analytics.

### 13.7 Clipboard exposure

Formatted text temporarily exists on the system pasteboard, where clipboard
managers and other processes may observe it. Highly sensitive workflows should
prefer direct Accessibility insertion where reliable.

### 13.8 Temporary audio

Raw audio is written to a temporary file during each session. Normal cleanup
deletes it, but crashes can leave files behind. Future hardening could add
launch-time cleanup of stale `wispr-*.wav` files and stronger file permissions.

### 13.9 Prompt injection

The formatter treats the transcript as untrusted content inside explicit
`<transcript>` boundaries. A speaker can still dictate adversarial text. The LLM
must never gain tool access or arbitrary system execution solely from formatted
transcript content.

### 13.10 Network security

Groq and OpenAI use HTTPS. Ollama defaults to unencrypted localhost HTTP. Do not
point Ollama at an untrusted remote HTTP host without TLS and authentication.

### 13.11 Broad Apple Events entitlement

The current entitlement file includes Apple Events capabilities that are not
used by the code. Remove them before public release to reduce attack surface and
notarization review complexity.

### 13.12 Usage analytics

Provider analytics are local and contain only provider/timestamp events. Do not
extend this to transcripts, audio, prompts, API keys, or focused application
content without explicit user consent and a documented retention policy.

---

## 14. Known limitations

- No automated test target
- No CI pipeline
- No crash-reporting integration
- No automatic updater
- No Developer ID notarized distribution
- No DMG/PKG installer
- No built-in login-item toggle
- No arbitrary macOS voice-command execution
- No streaming partial transcription
- No automatic language-selection UI
- No user-facing model-download progress
- No explicit Apple Speech timeout/cancellation layer
- Clipboard semantics may vary in specialized applications
- Accessibility fallback behavior differs between target applications
- Provider count tracks successful formatter selection, not provider billing
  tokens or cost

---

## 15. Recommended production-hardening roadmap

1. Remove unused Apple Events entitlements.
2. Stop mirroring API keys to plaintext Application Support once Keychain seeding
   succeeds.
3. Add unit tests for prompt sanitization, configuration, provider fallback,
   usage-window calculations, and hotkey state transitions.
4. Add integration tests for audio cleanup and pasteboard restoration.
5. Add launch-time cleanup for stale temporary recordings.
6. Add explicit cancellation/timeouts to Apple Speech.
7. Add a pass-through formatting mode for offline operation.
8. Add model download/progress and integrity UI.
9. Add a built-in launch-at-login preference using `SMAppService`.
10. Configure Developer ID signing and notarization.
11. Add a signed update mechanism such as Sparkle.
12. Add privacy documentation and a threat model.
13. Add optional direct-insertion mode for sensitive text.
14. Remove the orphan `TextFormatter copy.swift`.
15. Initialize and protect the repository with private version control, ensuring
    `.env`, `.build`, DerivedData, models, and signing material are ignored.

---

## 16. Quick operational reference

### Start and stop dictation

```text
Start: double-tap Left Command
Stop:  tap Left Command once
Toggle: Command + Shift + Space
```

### Open Preferences

```text
Menu bar → Wispr → Preferences…
```

### Standalone application

```text
/Applications/WisprClone.app
```

### Application Support

```text
~/Library/Application Support/WisprClone/
```

### Preferences domain

```text
~/Library/Preferences/com.openwhisper.WisprClone.plist
```

### Inspect recent logs

```bash
/usr/bin/log show --last 10m \
  --predicate 'subsystem == "com.openwhisper.WisprClone"' \
  --info --debug
```

### Confirm one running instance

```bash
pgrep -lx WisprClone
```

---

## 17. Final notes

WisprClone combines security-sensitive macOS capabilities: microphone capture,
global keyboard monitoring, Accessibility control, local model execution,
cloud API access, and clipboard manipulation. These are appropriate for the
product, but they require deliberate permission UX, narrow implementation,
stable code signing, careful credential handling, and transparent privacy
documentation.

For personal use, the current Release application can run independently from
Xcode after installation. For another developer's Mac, build from source and
grant permissions again. For distribution to general users, complete Developer
ID signing, notarization, entitlement reduction, clean-Mac testing, and secure
packaging before sharing the application.
