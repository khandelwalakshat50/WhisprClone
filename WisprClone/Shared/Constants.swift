import Foundation

enum Constants {
    static let appName = "WisprClone"
    static let bundleIdentifier = "com.openwhisper.WisprClone"

    enum Hotkey {
        /// Default chord: ⌘⇧Space (wired in Phase 4).
        static let defaultKeyCode: UInt16 = 49 // Space
        static let defaultModifiers: UInt = 0x100108 // cmd + shift (carbon-style; refined in Phase 4)
    }

    enum Audio {
        /// Cumulative silence after speech before a live ASR chunk is committed
        /// (and before UI treats the utterance as paused). Recording itself
        /// still ends only via the manual stop hotkey.
        static let silenceDurationMilliseconds: UInt64 = 700
        /// Emergency cap only; normal recording ends via the manual stop hotkey.
        static let maxListenSeconds: TimeInterval = 1800 // 30 minutes

        /// WhisperKit expects 16 kHz mono floats.
        static let whisperSampleRate: Double = 16_000
        /// Force-commit a live chunk after this much buffered speech (no pause).
        static let liveChunkMaxSeconds: TimeInterval = 4
        /// Ignore silence commits shorter than this (avoids tiny empty chunks).
        static let liveChunkMinSeconds: TimeInterval = 0.55
        /// After stop, wait for trailing Deepgram HTTP chunks (legacy path).
        static let liveFinishWaitSeconds: TimeInterval = 8.0
        /// After stop, wait for Deepgram live WebSocket Finalize (primary path).
        static let liveStreamFinishWaitSeconds: TimeInterval = 2.0
        /// Keep mic open briefly after stop (HTTP-chunk fallback).
        static let postRollNanoseconds: UInt64 = 450_000_000 // 450 ms
        /// Shorter post-roll for live WebSocket — Finalize flushes the server buffer.
        static let postRollStreamingNanoseconds: UInt64 = 200_000_000 // 200 ms
        /// Clips shorter than this use fast decode options (no VAD chunking).
        static let fastDecodeMaxSeconds: TimeInterval = 12
        /// Keep this much audio at the end of a mid-speech chunk so the next
        /// window still hears word boundaries (reduces “it's” / “I'll” garble).
        static let liveChunkOverlapSeconds: TimeInterval = 0.45
        /// Max tokens for vocabulary / prior-text prompt bias.
        static let whisperPromptTokenLimit: Int = 120
    }

    enum Speech {
        static let defaultDeepgramModel = "nova-3"
        static let deepgramTimeoutSeconds: TimeInterval = 30
        /// Per-attempt WebSocket open timeout (one retry while still recording).
        static let liveConnectTimeoutSeconds: TimeInterval = 5
        /// At stop, how long to keep waiting for a socket that never opened before using HTTP.
        static let liveConnectGraceAtStopSeconds: TimeInterval = 1.0
        /// When the live stream already has usable text, cap the HTTP re-check at this long.
        static let fallbackMaxWaitWithLiveTextSeconds: TimeInterval = 2.5
        /// Keep 16 kHz audio for a compact HTTP fallback upload (longer sessions use the WAV).
        static let maxRetainedFallbackSeconds: Double = 600
    }

    enum Formatting {
        /// Split long transcripts into sentence-aware pieces for parallel formatting.
        static let maxChunkCharacters: Int = 700
        /// Auto mode: Groq for short/medium captures; longer → OpenAI, then Gemini.
        /// Raised from 5s so typical 6–12s phrases stay on the faster path.
        static let longFormAudioSeconds: TimeInterval = 12
        /// Word-count proxy when duration is unknown (~12s of speech).
        static let longFormMinWords: Int = 28
        /// Character-count proxy when word splitting is sparse.
        static let longFormMinCharacters: Int = 160
        /// Progressive Groq only for a single short live chunk; multi-chunk
        /// abandons and formats with the long-form route at the end.
        static let progressiveMaxChunks: Int = 1
        /// Skip the network when ASR already looks like polished prose.
        static let skipLLMMaxCharacters: Int = 100
        /// Only reuse progressive/speculative text when it is essentially complete.
        /// 0.65 previously accepted truncated speech and dropped the last sentence.
        static let progressiveMinCoverage: Double = 0.95
    }

    enum LLM {
        static let ollamaBaseURL = URL(string: "http://localhost:11434")!
        static let ollamaTimeoutSeconds: TimeInterval = 5
        static let defaultOllamaModel = "qwen3:8b"
        static let fallbackOllamaModel = "llama3.2"
        /// Low-latency Groq SKU for short-form formatting (~0.25s with reasoning off).
        static let defaultGroqModel = "qwen/qwen3.8-27b"
        /// Retired Groq models (404 model_not_found) — migrated to `defaultGroqModel` on load.
        static let retiredGroqModels: Set<String> = ["llama-3.1-8b-instant", "llama-3.3-70b-versatile"]
        /// Groq normally answers in well under 1s; fail over quickly instead of stalling the paste.
        static let groqTimeoutSeconds: TimeInterval = 3
        /// Smallest / lowest-latency OpenAI SKU — first choice for long-form formatting.
        static let defaultOpenAIModel = "gpt-5.4-nano"
        /// Previous stock default — migrated to `defaultOpenAIModel` on load.
        static let legacyDefaultOpenAIModel = "gpt-4o-mini"
        /// Fast primary for dictation (avoids 429 round-trips on 3.5 Flash).
        static let defaultGeminiModel = "gemini-3.1-flash-lite"
        /// Higher-quality fallback when lite fails / is overloaded.
        static let fallbackGeminiModel = "gemini-3.5-flash"
        static let geminiTimeoutSeconds: TimeInterval = 8
        static let chatTimeoutSeconds: TimeInterval = 8
        /// Cap completion length — chunked formatting rarely needs more.
        static let geminiMaxOutputTokens: Int = 1_024
        static let chatMaxOutputTokens: Int = 1_024
    }

    enum Injection {
        /// Brief settle after ⌘V so the target app reads the pasteboard.
        /// Clipboard restore stays off the critical path with a longer delay.
        static let pasteDeliveryNanoseconds: UInt64 = 35_000_000 // 35 ms
        /// Settle after reactivating the target app before synthesizing ⌘V.
        static let focusSettleNanoseconds: UInt64 = 25_000_000 // 25 ms
        /// How long the transcript stays on the clipboard before the user's
        /// original clipboard is restored (off the critical path).
        static let clipboardRestoreNanoseconds: UInt64 = 900_000_000 // 900 ms
    }

    enum Overlay {
        static let width: CGFloat = OverlayTheme.panelWidth
        static let height: CGFloat = OverlayTheme.panelHeight
        static let cornerRadius: CGFloat = OverlayTheme.cornerRadius
        /// Distance from the bottom of the visible screen frame.
        static let bottomMargin: CGFloat = 52
        static let fadeDuration: TimeInterval = 0.48
        /// Auto-return to `.idle` after success / failure so the HUD dismisses.
        static let autoDismissSeconds: TimeInterval = 1.05
    }

    enum Build {
        static var installLabel: String {
            let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
            #if DEBUG
            let kind = "Debug"
            #else
            let kind = "Release"
            #endif
            let path = Bundle.main.bundleURL.path
            let whereFrom: String
            if path.contains("DerivedData") {
                whereFrom = "Xcode build — quit and open /Applications/WisprClone.app for the latest"
            } else if path.hasPrefix("/Applications/") {
                whereFrom = "Applications"
            } else {
                whereFrom = (path as NSString).lastPathComponent
            }
            return "v\(version) · \(kind) · \(whereFrom)"
        }
    }
}
