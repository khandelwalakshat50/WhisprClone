# OpenWhisper (WisprClone) — Interview Prep

**Use this for:** “Describe an AI tool you geeked out about” / system design / ML product / engineering depth.

**One-line hook:** I built a macOS AI dictation app that turns speech into polished writing and pastes it into whatever app you’re in — and I obsessed over making it fast, cheap, and not behave like a chatbot.

---

## How to tell the story (pick one length)

### 30 seconds
> I built **OpenWhisper**, a native macOS dictation app inspired by Wispr Flow. You double-tap Fn, speak, stop — it transcribes with **Deepgram Nova-3**, optionally polishes with an LLM (**Groq** for speed, **Gemini** for longer text), and pastes into the focused app without stealing focus. What I geeked out on was the **pipeline design**: live streaming ASR, overlapping LLM with speech, skipping the LLM when STT is already good, and hard prompts so the model **never answers your questions** — it only cleans up what you said.

### 2 minutes
> Most voice tools feel like “record → wait → fix in another window.” I wanted **OS-level writing**: invisible, fast, context-aware.
>
> Architecturally it’s a menu-bar agent: global hotkeys → mic capture → **live ASR** → **intent-aware LLM formatting** → **Accessibility/clipboard paste**. Default ASR is **Deepgram Nova-3 over WebSocket** (we moved off HTTP chunks because latency and trailing words were killing demos). Formatting is not one giant ChatGPT prompt — it’s a **router** with preserve/structure/rewrite levels, app profiles (Gmail vs Cursor vs Slack), and heuristics so we **don’t pay for an extra classification LLM call**.
>
> The fun hard problems were: **(1)** last sentence getting cut off — fixed with Finalize on the stream, post-roll, and disabling speculative LLM reuse at 65% coverage; **(2)** LLM answering dictated questions — fixed with role-boundary prompts plus a code guard; **(3)** perceived latency — Groq for ~≤12s utterances, Gemini for longer, progressive formatting on the first live chunk, skip LLM when Deepgram confidence is high; **(4)** Mac integration — CGEventTap hotkeys, non-activating overlay, Keychain for keys.
>
> I also ported the product to **Windows** (WPF + same cloud brain) and documented distribution so friends/family can run it without cloning the repo.

---

## What the product does (fundamentals)

| Step | What happens |
|------|----------------|
| **Trigger** | Double-tap **Fn** (start) / single-tap **Fn** (stop), or **⌘⇧Space** toggle |
| **Capture** | `AVAudioEngine` → 16 kHz mono PCM + WAV sidecar for fallback |
| **Live feedback** | Frosted HUD at bottom-center: orb + **silver waveform** driven by mic RMS |
| **Transcribe** | **Deepgram Nova-3** live WebSocket (primary); HTTP full-file fallback |
| **Intelligence** | Heuristic intent + app profile → specialized **preserve** prompt (default) |
| **Format** | Groq / Gemini / OpenAI / Ollama with auto-routing and fallbacks |
| **Inject** | Restore focus to target app → clipboard + **⌘V** (Accessibility path too) |
| **Memory** | Per-app vocabulary hints + personal dictionary (not full chat history) |

**Important distinction:** The LLM is a **transcript post-processor**, not an assistant. Input is `<transcript>`; output is polished text only.

---

## Architecture (technical)

```
GlobalHotkeyManager (CGEventTap)
        ↓
DictationCoordinator  ← session state machine
        ├─ AudioRecorder + VoiceActivityDetector (RMS)
        ├─ DeepgramLiveStreamer (WebSocket)  OR  LiveChunkTranscriber (HTTP chunks)
        ├─ ProgressiveLLMFormatter (Groq, ≤1 short chunk while speaking)
        ├─ LLMFormattingService
        │     ├─ DictationIntelligence (intent, level, skip-LLM)
        │     └─ LLMLibrary (compact system prompts)
        ├─ ContextSessionStore / PersonalDictionaryStore
        └─ TextInjector (focus restore + paste)
OverlayManager → StatusView (waveform HUD)
ConfigurationStore → Keychain + UserDefaults
```

### State machine
`idle → listening → detectingSpeech → transcribing → formatting → injecting → success | failure → idle`

### Key files (if they ask “where is X?”)
| Concern | File(s) |
|---------|---------|
| Orchestration | `DictationCoordinator.swift` |
| Live Deepgram WS | `DeepgramLiveStreamer.swift` |
| HTTP ASR fallback | `DeepgramRecognizer.swift` |
| LLM routing | `LLMFormattingService.swift` |
| Prompts / anti-answer | `LLMPromptLibrary.swift` |
| Intent / skip LLM | `DictationIntelligence.swift` |
| Hotkeys | `GlobalHotkeyManager.swift` |
| Timings | `Constants.swift` |

---

## AI / ML stack (be precise in interviews)

### Speech-to-text (ASR)
- **Primary:** Deepgram **Nova-3**, **live WebSocket** (`wss://api.deepgram.com/v1/listen`)
  - `linear16`, 16 kHz mono, `interim_results`, `endpointing`, `Finalize` on stop
- **Fallback:** Same model, HTTP POST on full WAV if stream incomplete
- **Optional local:** WhisperKit (Core ML), Apple Speech
- **Signal used:** `confidence` (0–1) for skip-LLM and routing

### LLM formatting (not generation)
- **Role:** punctuation, caps, paragraphs, light filler removal — **preserve wording**
- **Providers:** Groq `llama-3.1-8b-instant`, Gemini `gemini-3.1-flash-lite` (+ 3.5 fallback), OpenAI, Ollama
- **Auto routing:**
  - Short (~≤12s / ~28 words) → **Groq first** (latency)
  - Longer → **Gemini first** (quality); may split into ≤700 char parallel chunks
- **Skip LLM:** high ASR confidence + already looks like clean prose
- **Progressive:** one Groq pass on first live chunk; abandon if multi-chunk → full Gemini at end

### “Intelligence” without extra model calls
- **FormattingLevel:** preserve (default) | structure | rewrite (explicit only)
- **DictationIntent:** email, chat, technical, meeting notes, etc. — **regex/heuristics**
- **AppFormattingProfile:** bundle ID + window title (e.g. Gmail in Chrome, Cursor, Slack)
- **ContextSessionStore:** slim **vocabulary-only** hint per app session — avoids polluting LLM with prior paragraphs

### Prompt engineering (talk about this — it’s AI-relevant)
- Small specialized system prompts, not one universal blob
- **Role boundary:** “You are a cleanup filter, NOT a chatbot”
- User message wraps `<context>` + `<transcript>`; explicit “if question, return question”
- **Post-guard in code:** if output expands a question into an answer (“Sure, here’s…”), revert to light local polish

---

## Hard problems I solved (good “geek out” material)

| Problem | Root cause | Fix |
|---------|------------|-----|
| **Last sentence cut off** | Speculative LLM at ~65% coverage; HTTP chunk deadline; mic stopped before WS ready | Disable speculative reuse; Finalize + post-roll; mic **before** WebSocket connect + buffer leading audio |
| **Slow demos** | Full-file ASR redo on happy path; 8s waits | Live WebSocket; shorter finalize wait; overlap formatting where safe |
| **LLM answers questions** | Models treat transcript as chat prompt | Strong prompts + output length/heuristic guard |
| **Instant stop after double-Fn** | Duplicate hotkey edges | Edge dedupe; ignore stop &lt;650ms after begin |
| **Paste into wrong app** | Our UI stole focus | Capture frontmost app **before** session; restore before ⌘V |
| **API cost** | LLM on every utterance | Skip when clean; Groq for short; heuristics not second LLM for intent |
| **Windows port** | Different OS primitives | Same cloud pipeline; WPF tray; DPAPI keys; documented prompt kit |

---

## Numbers you can cite (from `Constants.swift`)

- Live stream finish wait: **~2s** after Finalize  
- Post-roll (streaming): **~200ms**  
- Progressive min coverage for reuse: **95%** (was 65% — caused truncation)  
- Long-form threshold for Gemini-first: **~12s** / **28 words**  
- LLM timeout: **8s**; max output tokens: **1024**  
- History: last **10** transcripts local only  

---

## Tech stack summary

| Layer | Technology |
|-------|------------|
| Language | Swift 6 |
| UI | SwiftUI + AppKit (menu bar, Preferences, HUD) |
| Audio | AVAudioEngine, VAD on RMS |
| ASR | Deepgram Nova-3 (WebSocket + HTTP) |
| LLM | Groq, Gemini, OpenAI, Ollama |
| Secrets | Keychain, `.env` seed (gitignored) |
| Injection | Accessibility API + NSPasteboard + synthetic ⌘V |
| Hotkeys | CGEventTap (sandbox off — required) |
| Also built | Windows WPF port, same Deepgram/LLM behavior |

---

## Interview Q&A

### Product & motivation

**Q: Why build this instead of using Wispr Flow or built-in dictation?**  
**A:** I wanted to understand the full stack — streaming ASR, LLM routing, OS integration — and control latency/cost/privacy tradeoffs. Built-in dictation doesn’t give me app-aware formatting, multi-provider fallback, or a programmable intelligence layer. Commercial tools also hide the failure modes (truncation, LLM drift) that are interesting to engineer around.

**Q: What makes this an “AI” product vs a voice recorder?**  
**A:** The product value is the **pipeline**: streaming STT + confidence-aware **decision layer** (skip vs Groq vs Gemini) + **constrained** LLM transformation with app/intent context — not open-ended chat. The AI is in routing, prompts, and reliability guards as much as in the models.

**Q: Who is it for?**  
**A:** Personal/prosumer use — developers, writers, anyone who lives in email/Slack/IDEs. I use it for dictating into Cursor, Gmail, Notes. Also packaged for family on Windows.

---

### Architecture & system design

**Q: Walk me through one dictation end-to-end.**  
**A:** Hotkey fires → coordinator stores frontmost app → mic starts **immediately** → Deepgram WebSocket connects in background while PCM buffers → user speaks → on stop, post-roll + `Finalize` → joined transcript → `DictationIntelligence` picks level/intent and maybe skips LLM → else `LLMFormattingService` routes to Groq or Gemini → anti-answer guard → restore focus → paste → history entry with timing breakdown.

**Q: Why WebSocket instead of batch HTTP for ASR?**  
**A:** Batch adds round-trips per chunk and made **trailing words** and **demo latency** worse. Streaming keeps one session, Finalize flushes the tail in hundreds of ms, and we still HTTP-fallback the WAV if the stream is incomplete — safety without making fallback the happy path.

**Q: Why multiple LLM providers?**  
**A:** **Latency vs quality vs availability.** Groq is sub-second for short polish; Gemini is better on long messy speech. Auto fallback handles 429s/overload (Gemini lite ↔ 3.5). Ollama last for offline. It’s classic **tiered serving**.

**Q: How do you avoid the LLM changing what the user said?**  
**A:** Default **preserve** level, specialized prompts, no auto-bullets/lists (they caused paste bugs), vocabulary hints only — never prior prose. Plus code-level rejection if output looks like an assistant answer.

**Q: How does app-aware formatting work without sending the whole screen to the LLM?**  
**A:** We read **bundle ID + window title** locally (e.g. “Gmail”, “Cursor”) → pick an `AppFormattingProfile` → adjust prompt tone (technical vs email vs chat). Session store keeps a **short vocabulary summary** per app, not full transcripts.

---

### ML / AI depth

**Q: Why not fine-tune a model?**  
**A:** For this use case, **prompting + routing + skip logic** got 90% of the value at 1% of the cost. Fine-tuning would help domain vocabulary but adds deployment burden; we already bias ASR with keyterms and a personal dictionary.

**Q: How do you evaluate quality?**  
**A:** Mostly **human-in-the-loop** dogfooding: trailing word retention, time-to-paste, “did it answer my question,” paste into Gmail/Slack/Cursor. Logs capture stage timings (`debug.log`) and delay notes in History. Formal metrics would be WER + edit distance — good next step.

**Q: What is your approach to prompt engineering here?**  
**A:** Decomposed prompts by **level × intent × app**; hard **role boundary**; structured user message with XML-like tags; minimal tokens; capped output. Treat LLM as a **function** `(transcript, context) → text`, not a conversation.

**Q: How do you handle hallucinations?**  
**A:** In preserve mode we **forbid** adding facts; prompts say “if unsure, keep original.” ASR is source of truth. If LLM expands length on a question, we **discard** and use light local polish. Structure/rewrite only on explicit cues.

**Q: Confidence scores — how used?**  
**A:** Deepgram returns confidence per chunk; we can **skip LLM** when confidence is high (~≥0.92) and text already looks clean (capitalization, punctuation, no fillers). Saves cost and latency.

---

### Engineering & tradeoffs

**Q: Biggest technical challenge?**  
**A:** **Correctness under latency pressure** — especially last-sentence retention while still feeling instant. That forced moving to streaming ASR, killing speculative paste, and starting the mic before network handshake.

**Q: Why native Swift vs Electron?**  
**A:** Global hotkeys, low-latency audio, non-activating overlay, and Accessibility injection need tight OS integration. A menu-bar agent belongs native.

**Q: Security / privacy?**  
**A:** Keys in Keychain; audio goes to Deepgram when using cloud ASR; **only transcript text** goes to LLM providers user configures. History local. Sandbox disabled for CGEventTap — conscious tradeoff for a personal tool.

**Q: What would you do differently?**  
**A:** Earlier WebSocket-first design; formal eval harness; optional on-device LLM for preserve-only; code signing/notarization for wider Mac distribution; unified telemetry with privacy budget.

**Q: How did you port to Windows?**  
**A:** Kept cloud pipeline identical; rewrote shell (WPF, WASAPI, DPAPI, Ctrl+Win+Space). Documented in a `windows prompts/` kit so another Cursor session could rebuild behavior without Swift.

---

### Behavioral / “geek out”

**Q: What did you geek out about most?**  
**A:** The **latency budget** — overlapping speech with ASR and ASR with formatting, and knowing when **not** to call an LLM. Also the **failure archaeology**: logs showed speculative format at 163/227 chars — that one line explained truncated demos.

**Q: Tell me about a time you changed approach based on data.**  
**A:** User reported last sentence missing; logs showed `speculative format reusable` at ~70% coverage. Raised threshold to **95%**, added Finalize/post-roll, mic-before-connect. Reliability went up; occasional full-file fallback added ~1s but only on failure — acceptable tradeoff.

**Q: How do you balance speed vs quality?**  
**A:** Explicit policy in code: short → Groq; long → Gemini; never reuse partial progressive output; skip LLM when STT is already good. Product principle: **slightly imperfect now beats perfect in 5 seconds**.

---

## Additional interview Q&A (requested topics)

### Q: What format is used for sending audio to Deepgram?

**A:** It depends on the path, but everything is normalized to what Deepgram expects:

| Path | Wire format | Details |
|------|-------------|---------|
| **Live WebSocket** (primary) | **Binary PCM** on the socket | **16-bit linear PCM (`linear16`)**, **little-endian**, **16 kHz**, **mono** (1 channel). We send ~40 ms frames as raw bytes after converting mic audio. |
| **HTTP live chunks** (fallback) | `audio/raw` POST body | Same PCM: `encoding=linear16`, `sample_rate=16000`, `channels=1` in query params. |
| **Full-file fallback** | `audio/wav` POST body | The session WAV from `AVAudioRecorder` (same underlying PCM, wrapped in WAV). |

**On the Mac before Deepgram:**
- Mic capture uses hardware rate (often 44.1/48 kHz) **float32** via `AVAudioEngine`.
- We **resample to 16 kHz mono floats** (`AVAudioConverter`), then **encode to int16 linear16** for Deepgram.
- We also keep a **WAV sidecar** on disk for full-file retry if streaming is incomplete.

**Interview sound bite:** “We don’t send MP3 or AAC — we stream **raw linear16 at 16 kHz mono**, which is Deepgram’s low-latency path, plus WAV for the safety fallback.”

---

### Q: What is WhisperKit, and why wasn’t it good enough as the default?

**A:** **WhisperKit** is an open-source Swift package (from Argmax) that runs **OpenAI Whisper** on Apple devices using **Core ML** — so inference stays on-device, no cloud STT bill.

**What it does in our app:**
- Loads a Whisper model (e.g. `openai_whisper-base`) into `~/Library/Application Support/WisprClone/Models/`
- Full-file transcription from WAV
- **Live chunk** transcription on 16 kHz float buffers (with prompt context for continuity)
- Inference is **serialized** through an actor gate — concurrent Core ML calls hurt latency

**Why we moved the default to Deepgram Nova-3:**

1. **Latency for “dictation feel”** — Local Whisper on chunks is CPU/GPU-heavy; each chunk is a full decode pass. Cloud **streaming Nova-3** gives ~200–500 ms class responsiveness and a clean **Finalize** on stop for trailing words.
2. **Live pipeline fit** — Our product needs **continuous streaming + stop flush**. WhisperKit was built around batch/chunk decode; we had to stitch chunks and fight boundary drift and missing last phrases.
3. **First-run / ops cost** — Large model download, Core ML specialization, slow cold start. Bad for demos and “just install and talk.”
4. **Confidence signal** — Deepgram returns **confidence** per result; we use that for **skip-LLM** and routing. WhisperKit path doesn’t give the same cheap quality gate.
5. **Apple Speech** — Even lighter but less control and weaker for technical vocabulary / long-form dictation.

**How to say it without dismissing WhisperKit:**  
“It’s still in Preferences for privacy/offline — but for a **Wispr-like daily driver**, cloud streaming ASR won the latency and reliability tradeoff. WhisperKit is great for local/offline; it wasn’t the best default for **low-latency system-wide dictation**.”

---

### Q: List important Python libraries used.

**A (honest answer — important for interviews):**  
**The macOS app is not written in Python.** Core implementation is **Swift 6** with native Apple frameworks and Swift packages. There are **no Python files** in the OpenWhisper/WisprClone repo.

**What we use instead:**

| Concern | Mac stack | Windows port |
|---------|-----------|----------------|
| App / UI | SwiftUI, AppKit | C# WPF |
| Audio | AVFoundation (`AVAudioEngine`) | NAudio (WASAPI) |
| HTTP / WebSocket | `URLSession`, `URLSessionWebSocketTask` | `HttpClient`, `ClientWebSocket` |
| Local ASR | WhisperKit (Swift package) | — (Deepgram cloud) |
| Secrets | Keychain | DPAPI / Credential Manager |
| LLM APIs | REST via Swift (`Gemini`, Groq, OpenAI clients) | Same via .NET |

**If they expected Python because it’s “AI”:**  
“I chose **native code** for global hotkeys, mic tap, and paste injection. Python would be fine for a CLI prototype, but the **OS integration layer** is Swift/C#. Cloud AI is just **HTTP APIs** — no Python SDK required.”

**Python analogues (only if they push):** you’d use `sounddevice`/`pyaudio` for mic, `websockets` or Deepgram SDK for streaming, `httpx` for LLM calls — but that’s not what shipped.

---

### Q: Why did you not productionize it?

**A:** Be clear it’s a **serious personal / portfolio-grade build**, not a commercial release yet.

**What “productionize” would mean vs what exists today:**

| Gap | Current state |
|-----|----------------|
| **Distribution** | Manual zip of `/Applications/WisprClone.app` or Windows `publish\` folder — not App Store / notarized MSIX |
| **Signing** | Dev-signed / unsigned → Gatekeeper / SmartScreen warnings |
| **Sandbox** | **Disabled on Mac** (needed for `CGEventTap`, cross-app paste) — expands attack surface; needs careful review for public release |
| **Support & SLAs** | No on-call, no crash analytics pipeline, no formal QA matrix |
| **Multi-tenant / billing** | Each user brings their own API keys — no centralized billing or abuse controls |
| **Privacy / compliance** | Transcripts in local History; audio to Deepgram; text to LLM providers — would need privacy policy, DPA, enterprise review |
| **Cross-machine Mac installs** | Release build works on the building Mac; **other Macs** need Developer ID + **notarization** (documented in `PROJECT_HANDBOOK.md` but not done) |

**Why that was OK for my goals:**  
I built it to **dogfood** the full AI dictation stack, ship to friends/family, and port to Windows — not to run a hosted SaaS. Productionizing is mostly **GTM + security + ops**, which I deliberately scoped out.

**Positive spin:** “The **architecture** is production-shaped — state machine, fallbacks, Keychain, logging, History — but I stopped before notarization and store distribution because it’s a personal tool I’m iterating on.”

---

### Q: What tech stack is used, and why is it a good choice?

**A:**

**Mac (primary)**
- **Swift 6** + **SwiftUI/AppKit** — menu-bar agent, Preferences, floating HUD
- **AVAudioEngine** — low-latency mic; must match hardware tap format on macOS
- **CGEventTap** — global Fn / ⌘⇧Space hotkeys
- **Accessibility + NSPasteboard** — paste into any app without owning focus
- **Deepgram Nova-3** (WebSocket + HTTP) — streaming ASR
- **Groq / Gemini / OpenAI / Ollama** — formatting layer
- **Keychain** — API secrets

**Windows (port)**
- **C# / .NET 8, WPF** — tray app + Preferences dashboard
- **NAudio** — capture
- Same **Deepgram + LLM** cloud brain

**Why this is a good choice for *this* product:**

1. **OS-level integration** — Dictation is a **system utility**, not a web page. Native code gets hotkeys, mic, and focus restore reliably.
2. **Latency** — No Electron overhead; audio pipeline runs on dedicated queues; WebSocket STT direct to cloud.
3. **Swift on Mac** — WhisperKit/Core ML only exists in the Apple ecosystem; AppKit is the right surface for menu-bar + non-activating panels.
4. **Provider flexibility** — LLM layer is thin HTTP; swapping Groq ↔ Gemini is routing, not a rewrite.
5. **Cost control** — Heuristic skip-LLM + short-prompt routing works best when you own the whole client.

**When it would be the *wrong* choice:** cross-platform single codebase (would consider Flutter/RN + platform modules), or server-only batch transcription (Python + GPU farm).

---

### Q: Alternative choices to Deepgram — and why you preferred Deepgram?

**A:**

| Alternative | Pros | Why we didn’t default to it |
|-------------|------|------------------------------|
| **WhisperKit (local Whisper)** | Private, no STT API cost, on-device | Higher latency, chunk stitching, cold start, weaker “live stop” UX (see above) |
| **Apple Speech** | Built-in, simple | Less control, variable quality, not ideal for technical vocab / long dictation |
| **OpenAI Whisper API** | Strong accuracy | Batch-oriented; streaming story weaker than Deepgram for live dictation; pricing/latency profile different |
| **Google Cloud Speech-to-Text** | Mature, streaming | More enterprise setup; we optimized prompts/docs around Nova-3 |
| **Azure Speech** | Enterprise, custom speech | Same — heavier ops for a personal menu-bar tool |
| **AssemblyAI / Gladia** | Streaming APIs | Credible; chose Deepgram for **Nova-3 quality + simple WS API + keyterm prompting** |
| **AWS Transcribe** | AWS ecosystem | More complex auth/setup for a side project |

**Why Deepgram (Nova-3) for the default:**
- **Streaming-first API** (`wss://` + `Finalize`) matches our stop→flush UX
- **Smart format + punctuate** reduces LLM work
- **Keyterms** for personal dictionary / vocabulary bias on Nova-3
- **Confidence scores** for skip-LLM
- **Predictable latency** for demos vs local Whisper chunk RTT
- **One integration** for both live and batch fallback

**Honest tradeoff:** Cloud STT costs money and sends audio off-device — we keep WhisperKit as an **optional** engine for privacy-sensitive users.

---

### Q: How can you share it with other people?

**A:**

**Mac friends (non-developers) — recommended**
1. Zip **`/Applications/WisprClone.app`** (the installed Release app).
2. Send via AirDrop, Drive, or USB.
3. They drag to **Applications**, **Right-click → Open** first time (Gatekeeper).
4. Grant **Microphone**, **Accessibility**, **Input Monitoring**.
5. **Preferences** → paste **their own** Deepgram key (required) + optional LLM keys.
6. Use from **menu bar** (“Wispr”) — double-tap **Fn** to dictate.

**Do not share:** your `.env`, Keychain, or `~/Library/Application Support/WisprClone/` (history + secrets).

**Windows friends / family**
1. Run `.\publish.ps1` → zip **`publish\OpenWhisper\`**.
2. Send zip; they install **.NET 8 Desktop Runtime** if needed.
3. Run `OpenWhisper.exe`, add keys in Preferences, pin to taskbar.
4. Keys live in **their** `%AppData%\OpenWhisper\secrets\` (DPAPI) — not in the zip.

**Developers**
- Private **git** repo + `README.md` / `SETUP_FOR_BEGINNERS.md` — they build with Xcode or `dotnet publish`.
- Still **no shared API keys**.

**What we did *not* do (yet)**
- App Store / Mac notarization for strangers
- Signed Windows installer (MSIX)
- Auto-update channel

**One-liner for interview:** “I treat it like handing someone a **Release build**, not the repo — each person owns their API keys locally, same model we used for my dad’s Windows laptop.”

---

## Questions to ask them (shows depth)

1. How do you measure **end-to-end latency** for voice products (VAD vs endpointing vs LLM TTFT)?
2. Do you use **cascaded models** (small formatter + large fallback) in production?
3. How do you prevent **instruction drift** when LLMs post-process user content?
4. What’s your stance on **on-device vs cloud** ASR for privacy-first enterprise?

---

## Red flags to avoid in the interview

- Don’t say the LLM “understands” the user — it **formats** transcript.
- Don’t claim App Store / notarized distribution unless you’ve done it.
- Don’t say “real-time” without qualifying (~200–500ms STT + LLM adds more).
- Acknowledge sandbox/hotkey tradeoffs on Mac honestly.

---

## Quick glossary

| Term | Meaning here |
|------|----------------|
| **ASR** | Automatic speech recognition (Deepgram) |
| **Preserve level** | Minimal LLM edit — wording stays |
| **Finalize** | Deepgram WS message to flush trailing audio |
| **Progressive LLM** | Start formatting before user stops speaking |
| **Skip LLM** | Paste STT output when already clean |
| **Keyterm** | Deepgram vocabulary bias (Nova-3) |

---

## Files in this repo for deeper reading

- `system design.md` — architecture overview  
- `RESUME_PROJECT.md` — resume bullets  
- `PROJECT_HANDBOOK.md` — full product/security/deploy  
- `windows prompts/PITFALLS.md` — bugs we hit (great story fodder)  

Good luck tomorrow.
