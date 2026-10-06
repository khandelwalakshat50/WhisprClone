# Pitfalls already solved on Mac — don't repeat on Windows

## 1. Mic waits on network → first words cut
**Bug:** Await Deepgram WebSocket connect *before* opening the mic (~1–3s).
**Fix:** Start mic first. Buffer PCM until socket connects, then flush.

## 2. Last sentence cut
**Bugs:**
- Speculative LLM reused ~65% of transcript and pasted early text
- Stopped mic instantly with no post-roll
- Abandoned in-flight ASR chunk on a short deadline
**Fix:**
- No speculative paste unless coverage ≥ ~95%
- 200ms post-roll on streaming path
- Finalize + wait for finals; full-file fallback if incomplete

## 3. LLM answers the question
**Bug:** Formatter acted like ChatGPT when transcript was a question.
**Fix:** Hard role-boundary prompts + code guard that rejects expanded “Sure/Here's” answers.

## 4. Corrupted Deepgram model string
**Bug:** Settings field became `re a` → every request HTTP 400.
**Fix:** Sanitize model; force `nova-3` if invalid. Don't use free-text model fields carelessly.
**Also:** `keyterm` only works on Nova-3/Flux.

## 5. Hotkey double-fire / instant stop
**Bug:** Two monitors saw the same key → begin then immediate stop.
**Fix:** Dedupe edges; ignore stop for ~650ms after begin.

## 6. Paste goes into wrong app
**Bug:** Activating our UI stole focus; ⌘V/Ctrl+V hit ourselves.
**Fix:** Capture foreground window on BEGIN. Restore it before paste. Don't activate Settings during dictation.

## 7. Auto-structuring into bullets
**Bug:** LLM turned prose into lists and broke Gmail/chat paste.
**Fix:** Default Level 1 preserve; continuous prose; no auto bullets.

## 8. Full-file fallback on the happy path
**Bug:** Slow demos whenever live path was marked incomplete too aggressively.
**Fix:** Streaming primary; full-file only when live is empty/timed out.

## Windows-specific watches
- Admin rights may be needed for some global hooks — prefer `RegisterHotKey` first
- Some games/apps block synthetic Ctrl+V — may need UI Automation Insert later
- Antivirus can delay tray apps on first launch
- Exclusive-mode audio devices — use shared WASAPI mode
- DPI / multi-monitor overlay positioning
