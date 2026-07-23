import SwiftUI

/// Monochrome HUD language — grey, white, black only.
enum OverlayTheme {
    // MARK: Geometry

    static let width: CGFloat = 286
    static let height: CGFloat = 66
    static var panelWidth: CGFloat { width }
    static var panelHeight: CGFloat { height }

    static let cornerRadius: CGFloat = 33
    static let contentInset: CGFloat = 16
    static let orbSize: CGFloat = 22
    static let ribbonWidth: CGFloat = 152
    static let ribbonHeight: CGFloat = 26
    static let statusLabelWidth: CGFloat = 92

    // MARK: Motion

    enum Motion {
        static let micro = Animation.spring(response: 0.28, dampingFraction: 0.82)
        static let audio = Animation.spring(response: 0.24, dampingFraction: 0.78)
        static let breathDuration: TimeInterval = 2.0
        static let ribbonFPS: Double = 60
    }

    // MARK: Monochrome palette

    static let white = Color.white
    static let lightGrey = Color(white: 0.78)
    static let midGrey = Color(white: 0.55)
    static let darkGrey = Color(white: 0.28)
    static let black = Color.black

    static func accent(for state: RecordingState) -> Color {
        switch state {
        case .listening, .detectingSpeech: return lightGrey
        case .transcribing, .formatting, .injecting: return midGrey
        case .success: return white
        case .failure: return midGrey
        case .idle: return .clear
        }
    }

    static func secondaryAccent(for state: RecordingState) -> Color {
        switch state {
        case .idle: return .clear
        default: return darkGrey
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
