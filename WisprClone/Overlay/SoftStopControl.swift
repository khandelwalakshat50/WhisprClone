import SwiftUI

/// Soft monochrome stop control.
struct SoftStopControl: View {
    let action: () -> Void
    let accent: Color

    @State private var hovering = false
    @State private var pressing = false

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .fill(Color.white.opacity(hovering ? 0.18 : 0.08))
                    .overlay {
                        Circle()
                            .strokeBorder(Color.white.opacity(hovering ? 0.45 : 0.22), lineWidth: 0.5)
                    }

                Image(systemName: "stop.fill")
                    .font(.system(size: 7, weight: .bold))
                    .foregroundStyle(Color.white.opacity(hovering ? 0.95 : 0.55))
            }
            .frame(width: 28, height: 28)
            .scaleEffect(pressing ? 0.9 : hovering ? 1.06 : 1.0)
        }
        .buttonStyle(.plain)
        .help("Stop and transcribe")
        .onHover { hovering = $0 }
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in pressing = true }
                .onEnded { _ in pressing = false }
        )
        .animation(OverlayTheme.Motion.micro, value: hovering)
        .animation(OverlayTheme.Motion.micro, value: pressing)
    }
}

/// Trailing glyph — monochrome.
struct StatusGlyph: View {
    let state: RecordingState

    var body: some View {
        Group {
            switch state {
            case .transcribing, .formatting:
                Image(systemName: "sparkle")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.85))
            case .injecting:
                Image(systemName: "arrow.down.to.line.compact")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.85))
            case .success:
                Image(systemName: "checkmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Color.white.opacity(0.95))
            case .failure:
                Image(systemName: "exclamationmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Color.white.opacity(0.7))
            default:
                Color.clear.frame(width: 28, height: 28)
            }
        }
        .frame(width: 28, height: 28)
    }
}
