import SwiftUI
#if canImport(AppKit)
import AppKit
#endif

/// HUD language — frosted glass capsule with metallic silver accents.
enum OverlayTheme {
    // MARK: Geometry

    static let width: CGFloat = 296
    static let height: CGFloat = 70
    static var panelWidth: CGFloat { width }
    static var panelHeight: CGFloat { height }

    static let cornerRadius: CGFloat = 35
    static let contentInset: CGFloat = 14
    static let orbSize: CGFloat = 34
    static let ribbonWidth: CGFloat = 148
    static let ribbonHeight: CGFloat = 28
    static let statusLabelWidth: CGFloat = 92

    // MARK: Motion

    enum Motion {
        static let micro = Animation.spring(response: 0.28, dampingFraction: 0.82)
        static let audio = Animation.spring(response: 0.24, dampingFraction: 0.78)
        static let breathDuration: TimeInterval = 2.0
        static let ribbonFPS: Double = 60
        /// Full orbit period for the loading ring (seconds).
        static let ringOrbitDuration: TimeInterval = 3.6
    }

    // MARK: Metallic silver palette

    static let silverBright = Color(white: 0.96)
    static let silver = Color(white: 0.78)
    static let silverMid = Color(white: 0.58)
    static let silverDark = Color(white: 0.38)
    static let silverDeep = Color(white: 0.22)

    static let white = Color.white
    static let lightGrey = Color(white: 0.78)
    static let midGrey = Color(white: 0.55)
    static let darkGrey = Color(white: 0.28)
    static let black = Color.black

    static func lerp(_ a: Color, _ b: Color, _ t: CGFloat) -> Color {
        let t = min(max(t, 0), 1)
        #if canImport(AppKit)
        var ar: CGFloat = 0, ag: CGFloat = 0, ab: CGFloat = 0, aa: CGFloat = 0
        var br: CGFloat = 0, bg: CGFloat = 0, bb: CGFloat = 0, ba: CGFloat = 0
        let ans = NSColor(a).usingColorSpace(.deviceRGB) ?? NSColor.white
        let bns = NSColor(b).usingColorSpace(.deviceRGB) ?? NSColor.white
        ans.getRed(&ar, green: &ag, blue: &ab, alpha: &aa)
        bns.getRed(&br, green: &bg, blue: &bb, alpha: &ba)
        return Color(
            red: Double(ar + (br - ar) * t),
            green: Double(ag + (bg - ag) * t),
            blue: Double(ab + (bb - ab) * t),
            opacity: Double(aa + (ba - aa) * t)
        )
        #else
        return t < 0.5 ? a : b
        #endif
    }

    static func accent(for state: RecordingState) -> Color {
        switch state {
        case .listening, .detectingSpeech: return silverBright
        case .transcribing: return silver
        case .formatting: return silverMid
        case .injecting: return silverBright
        case .success: return silverBright
        case .failure: return midGrey
        case .idle: return .clear
        }
    }

    static func secondaryAccent(for state: RecordingState) -> Color {
        switch state {
        case .idle: return .clear
        case .listening, .detectingSpeech: return silver
        case .transcribing, .formatting: return silverDark
        case .injecting, .success: return silverMid
        case .failure: return darkGrey
        }
    }

    static func tertiaryAccent(for state: RecordingState) -> Color {
        secondaryAccent(for: state)
    }

    static func statusWord(for state: RecordingState) -> String {
        switch state {
        case .idle: return ""
        case .listening, .detectingSpeech: return "Listening"
        case .transcribing: return "Thinking"
        case .formatting: return "Refining"
        case .injecting: return "Writing"
        case .success: return "Done"
        case .failure: return "Unavailable"
        }
    }

    enum RibbonMode {
        case listening
        case thinking
        case refining
        case injecting
        case settled
        case failed
    }

    static func ribbonMode(for state: RecordingState) -> RibbonMode {
        switch state {
        case .listening, .detectingSpeech: return .listening
        case .transcribing: return .thinking
        case .formatting: return .refining
        case .injecting: return .injecting
        case .success, .idle: return .settled
        case .failure: return .failed
        }
    }
}

extension RecordingState {
    var isRecording: Bool {
        self == .listening || self == .detectingSpeech
    }

    var shouldPresentOverlay: Bool {
        self != .idle
    }

    var eyebrow: String { OverlayTheme.statusWord(for: self) }
    var accentColor: Color { OverlayTheme.accent(for: self) }
    var waveformMode: OverlayTheme.RibbonMode { OverlayTheme.ribbonMode(for: self) }
}
