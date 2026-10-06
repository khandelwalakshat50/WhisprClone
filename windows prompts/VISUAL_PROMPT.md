# Cursor prompt add-on — Visual polish (icon, launch, Mac-like waveform HUD)

Paste this into your Windows Cursor chat. **Do not change transcription / paste / key storage** — those already work. This pass is **visual + launch UX only**.

Mac reference: frosted glass capsule HUD near the **bottom-center** of the screen with a live **silver waveform ribbon** driven by mic RMS.

---

## Goals
1. Proper app / tray **icon**
2. **Easy launch** (Start Menu, desktop/taskbar pin, optional startup)
3. Floating **waveform HUD** that matches Mac placement and feel as closely as Windows allows

---

## 1) App icon + tray icon
- Design/generate a simple monochrome or metallic-silver mic / waveform mark (not a generic .NET icon)
- Set:
  - Window / exe icon (`.ico` with 16, 32, 48, 256)
  - Tray `NotifyIcon` uses the same art at 16/20/32
- Prefer embedding as a resource so published builds keep the icon
- If you generate assets: flat vector vibe, dark-friendly, readable at 16×16

## 2) Easy launch
Make the app discoverable like a normal Windows product:
- Publish / install so it appears in **Start Menu** as `OpenWhisper` (or WisprClone)
- Add tray menu items:
  - **Open Preferences**
  - **Start Dictation**
  - **Quit**
- Optional (Settings toggle, default OFF): **Launch at Windows startup**
- After publish, tell the user how to:
  - Pin to Taskbar
  - Pin to Start
- If currently run only via `dotnet run`, add a one-click **Release publish** script or README step that outputs a folder/exe they can pin

Do **not** require Visual Studio to launch day-to-day.

## 3) Floating waveform HUD (Mac parity)

### Placement (match Mac)
- Capsule / pill HUD
- Size ≈ **296 × 70**
- **Horizontally centered** on the monitor under the mouse (fallback: primary monitor)
- **~52 px above the bottom** of the working area (above taskbar — use work-area bounds, not full screen)
- Always-on-top tool window
- Does **not** activate / steal keyboard focus from the dictation target
- `ShowWithoutActivation` / WS_EX_NOACTIVATE / WS_EX_TOOLWINDOW pattern
- Click-through except the Stop button (if possible); at minimum never take focus on show

### Layout (left → right)
1. **Orb / energy core** (~34×34) — subtle pulse; reacts to audio while listening
2. **Status word** + **waveform ribbon**
   - Status words: Listening / Hearing / Transcribing / Refining / Pasting / Done / Failed
   - Ribbon ≈ **148 × 28**
3. **Stop control** while recording (soft circular stop); otherwise a small status glyph

### Look
- Frosted / translucent dark-glass capsule (acrylic / DWM blur if available; otherwise semi-transparent dark fill + border)
- Metallic **silver / grey** accents — avoid purple neon AI clichés
- Continuous capsule corners (~35 radius on 70 height)
- Soft border + light inner highlight

### Waveform behavior (the important part)
- While `listening` / `detectingSpeech`: live waveform driven by mic RMS
- Smoothing (Mac values):
  - Normalize RMS aggressively into 0…1
  - Fast attack (~0.88 toward louder), quicker release (~0.58 toward quieter)
  - Floor ~0.08 when idle in listening
- Animate a **horizontal silver filament** + soft glow + small beads along the wave (~36 points)
- ~60 FPS while visible
- While transcribing/formatting: calmer motion / lower amplitude (not frozen flat unless idle)
- On success/failure: brief show, then auto-dismiss ~1.0–1.1s back to hidden

### State → visibility
| State | HUD |
|------|-----|
| idle | hidden |
| listening / detectingSpeech | visible + live wave |
| transcribing / formatting / injecting | visible + processing motion |
| success / failure | visible briefly → hide |

### Audio wiring
- Reuse the existing capture RMS / peak you already compute for VAD or levels
- Push smoothed level into the HUD view-model on the UI thread
- Keep waveform updates off the critical STT path (don’t block Deepgram sends)

## Windows constraints (work within them)
- True macOS vibrancy won’t match 1:1 — approximate with Acrylic/Mica/blur + translucent brush
- Some fullscreen games may cover always-on-top HUDs — acceptable
- Multi-monitor: follow cursor screen like Mac
- DPI awareness: position using work-area DIPs correctly

## Non-goals
- Do not refactor Deepgram / LLM / key storage
- Do not move HUD to top-right tray area — keep **bottom-center** like Mac
- Do not replace waveform with a plain progress bar
- Do not use loud multi-color visualizer bars unless as a last resort; prefer the Mac silver ribbon

## Definition of done
1. Published/start-menu exe has a real icon; tray shows the same mark  
2. User can launch without `dotnet run` and can pin to taskbar  
3. On dictation start, bottom-center glass capsule appears with a **live waveform**  
4. Wave reacts to voice in real time; Stop is available while recording  
5. HUD never steals text focus from Notepad/Chrome/Cursor  
6. After paste success, HUD shows Done briefly and disappears  

## Implementation suggestion
- `OverlayWindow` (WPF `Window` with `Topmost`, `ShowActivated=false`, `WindowStyle=None`, transparent background)
- `WaveformRibbon` control using `CompositionTarget.Rendering` or `DispatcherTimer` @ 60fps drawing a Path
- `OverlayViewModel` with `AudioLevel` + `State`
- Keep Preferences dashboard as-is; this is the live HUD only

Start by implementing the HUD shell + placement, then wire audio levels into the ribbon, then icon/launch polish.
