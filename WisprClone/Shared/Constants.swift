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
        /// Cumulative silence after speech before auto-stop (Phase 6).
        static let silenceDurationMilliseconds: UInt64 = 700
        /// Emergency cap only; normal recording ends via the manual stop hotkey.
        /// Longer clips take proportionally longer to transcribe (Whisper runs
        /// once on the full recording when you stop).
        static let maxListenSeconds: TimeInterval = 1800 // 30 minutes
    }

    enum LLM {
        static let ollamaBaseURL = URL(string: "http://localhost:11434")!
        static let ollamaTimeoutSeconds: TimeInterval = 5
        static let defaultOllamaModel = "qwen3:8b"
        static let fallbackOllamaModel = "llama3.2"
        static let defaultGroqModel = "llama-3.3-70b-versatile"
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
        static let width: CGFloat = 244
        static let height: CGFloat = 58
        static let cornerRadius: CGFloat = 19
        /// Distance from the bottom of the visible screen frame.
        static let bottomMargin: CGFloat = 48
        static let fadeDuration: TimeInterval = 0.36
        /// Auto-return to `.idle` after success / failure so the HUD dismisses.
        static let autoDismissSeconds: TimeInterval = 0.95
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
