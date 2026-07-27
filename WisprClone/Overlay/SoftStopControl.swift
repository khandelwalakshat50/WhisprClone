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
                    .fill(Color.primary.opacity(hovering ? 0.12 : 0.06))
                    .overlay {
                        Circle()
                            .strokeBorder(Color.primary.opacity(hovering ? 0.35 : 0.18), lineWidth: 0.5)
                    }

                Image(systemName: "stop.fill")
                    .font(.system(size: 7, weight: .bold))
                    .foregroundStyle(Color.primary.opacity(hovering ? 0.9 : 0.5))
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
                    .foregroundStyle(Color.primary.opacity(0.8))
            case .injecting:
                Image(systemName: "arrow.down.to.line.compact")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.primary.opacity(0.8))
            case .success:
                Image(systemName: "checkmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Color.primary.opacity(0.9))
            case .failure:
                Image(systemName: "exclamationmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Color.primary.opacity(0.55))
            default:
                Color.clear.frame(width: 28, height: 28)
            }
        }
        .frame(width: 28, height: 28)
    }
}
