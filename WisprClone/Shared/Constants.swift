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
        /// Lower than before so medium utterances overlap Whisper with speaking.
        static let liveChunkMaxSeconds: TimeInterval = 5
        /// Ignore silence commits shorter than this (avoids tiny empty chunks).
        static let liveChunkMinSeconds: TimeInterval = 0.55
        /// Clips shorter than this use fast decode options (no VAD chunking).
        static let fastDecodeMaxSeconds: TimeInterval = 12
        /// Keep this much audio at the end of a mid-speech chunk so the next
        /// window still hears word boundaries (reduces “it's” / “I'll” garble).
        static let liveChunkOverlapSeconds: TimeInterval = 0.45
        /// Max tokens for vocabulary / prior-text prompt bias.
        static let whisperPromptTokenLimit: Int = 120
    }

    enum Formatting {
        /// Split long transcripts into sentence-aware pieces before the LLM
        /// so latency stays bounded for lengthy dictation.
        static let maxChunkCharacters: Int = 2_200
        /// Auto mode: utterances longer than this prefer Gemini (accuracy);
        /// shorter ones prefer Groq (speed).
        static let longFormAudioSeconds: TimeInterval = 7
        /// Word-count proxy for ~7s of speech (~150 wpm → ~2.5 words/s).
        static let longFormMinWords: Int = 18
        /// Character-count proxy when word splitting is sparse.
        static let longFormMinCharacters: Int = 110
    }

    enum LLM {
        static let ollamaBaseURL = URL(string: "http://localhost:11434")!
        static let ollamaTimeoutSeconds: TimeInterval = 5
        static let defaultOllamaModel = "qwen3:8b"
        static let fallbackOllamaModel = "llama3.2"
        static let defaultGroqModel = "llama-3.3-70b-versatile"
        static let defaultGeminiModel = "gemini-3.5-flash"
        /// Fast path when 3.5 Flash is overloaded (503) — ~1s in healthy probes.
        static let fallbackGeminiModel = "gemini-3.1-flash-lite"
        static let geminiTimeoutSeconds: TimeInterval = 8
        /// Cap completion length — dictation cleanup rarely needs more.
        static let geminiMaxOutputTokens: Int = 768
    }

    enum Injection {
        /// Delay after posting ⌘V so the target app reads our pasteboard entry
        /// before we consider injection done.
        static let pasteDeliveryNanoseconds: UInt64 = 250_000_000 // 250 ms
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
