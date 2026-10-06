# Constants that already work on Mac

Tune later; start here.

## Audio / streaming
| Name | Value | Notes |
|------|-------|-------|
| Sample rate | 16000 | Deepgram linear16 |
| Silence UI pause | 700 ms | Does not auto-stop recording |
| Max listen | 1800 s | Emergency cap |
| Live stream finish wait | 2.0 s | After Finalize |
| HTTP chunk finish wait | 8.0 s | Legacy only |
| Post-roll (streaming) | 200 ms | Keep mic open after stop |
| Post-roll (HTTP fallback) | 450 ms | |
| Preconnect buffer cap | 5 s | Leading speech while WS connects |
| Send frame target | ~40 ms | Avoid tiny WS frames |
| KeepAlive interval | 5 s | |
| Finalize settle | ~280 ms | After last is_final if no from_finalize |

## Hotkey
| Name | Value | Notes |
|------|-------|-------|
| Begin→stop grace | 650 ms | Ignore stop that races after begin |
| Mac gesture | double-Fn begin / single-Fn stop | **Windows: use Ctrl+Win+Space toggle instead** |

## LLM
| Name | Value |
|------|-------|
| Long-form audio threshold | 12 s |
| Long-form min words | 28 |
| Long-form min chars | 160 |
| Progressive max chunks | 1 |
| Progressive min coverage | 0.95 |
| Gemini primary | gemini-3.1-flash-lite |
| Gemini fallback | gemini-3.5-flash |
| Groq | llama-3.1-8b-instant |
| LLM timeout | 8 s |
| Max output tokens | 1024 |

## Injection
| Name | Value |
|------|-------|
| Focus settle | 25 ms |
| Paste delivery settle | 35 ms |
| Clipboard restore delay | 900 ms |

## Deepgram
| Name | Value |
|------|-------|
| Model | nova-3 |
| HTTP timeout | 30 s |
| Max keyterms | 12 |
| Keyterms | Nova-3 / Flux only |
