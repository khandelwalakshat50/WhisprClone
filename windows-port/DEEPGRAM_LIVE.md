# Deepgram live streaming (copy this behavior exactly)

## Why streaming (not HTTP chunks)
Mac originally used HTTP chunk POSTs while speaking. That caused:
- 1–3s delay before mic if connect blocked start
- last sentence drops when final chunk was late
- occasional full-file redo (demo-killing latency)

**Primary path:** one WebSocket for the whole utterance.

## Connect URL
```
wss://api.deepgram.com/v1/listen
  ?model=nova-3
  &encoding=linear16
  &sample_rate=16000
  &channels=1
  &smart_format=true
  &punctuate=true
  &interim_results=true
  &endpointing=300
  &utterance_end_ms=1000
  &vad_events=true
```
Optional: up to ~12 `keyterm=` query params (Nova-3/Flux only). Never send keyterm for other models.

Header:
```
Authorization: Token <DEEPGRAM_API_KEY>
```

## Audio format
- 16-bit little-endian PCM (`linear16`)
- 16_000 Hz mono
- Send ~40ms frames (or mic buffer sized chunks)
- Binary WebSocket messages

## Lifecycle (critical ordering)

```
BEGIN
  1. Start microphone capture NOW
  2. beginConnect() in background (do not block mic)
  3. While !connected: append PCM to preconnect buffer (cap ~5 seconds)
  4. On connected: flush buffer, then stream live
  5. Send KeepAlive JSON every 5s: {"type":"KeepAlive"}

STOP
  1. Post-roll ~200ms (keep mic open)
  2. Flush pending PCM
  3. Send {"type":"Finalize"}
  4. Wait until from_finalize OR ~280ms settle after last is_final OR 2s deadline
  5. Send {"type":"CloseStream"}
  6. Brief settle (~150ms), close socket
```

## Results handling
JSON messages `type=Results`:
- Append `channel.alternatives[0].transcript` when `is_final=true`
- Keep latest interim for finish if needed
- `from_finalize=true` means Finalize completed (not always present — use settle timer too)

Join finals with spaces (Deepgram already punctuates with smart_format).

## Fallbacks
1. If WebSocket connect fails → keep recording to WAV → on stop, HTTP POST full file
2. If live transcript empty/timed out → HTTP POST full file; prefer longer usable text

## HTTP fallback endpoint
```
POST https://api.deepgram.com/v1/listen?model=nova-3&smart_format=true&punctuate=true
Authorization: Token <KEY>
Content-Type: audio/wav   (or audio/raw + encoding/sample_rate/channels for PCM)
```

## Model sanitization
If settings somehow contain garbage (Mac once had model=`re a`), force `nova-3`.
Only allow models starting with `nova-`, `flux`, etc.
