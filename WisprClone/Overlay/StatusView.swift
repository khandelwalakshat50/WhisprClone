import SwiftUI

/// Floating dictation HUD — monochrome, all chrome visible immediately.
struct StatusView: View {
    @ObservedObject var model: OverlayPresentationModel
    let onStopRecording: () -> Void

    private var state: RecordingState { model.state }
    private var accent: Color { OverlayTheme.accent(for: state) }
    private var secondary: Color { OverlayTheme.secondaryAccent(for: state) }

    var body: some View {
        ZStack {
            CrystalGlassSurface(
                accent: accent,
                secondary: secondary,
                cornerRadius: OverlayTheme.cornerRadius
            )

            HStack(spacing: 12) {
                EnergyCoreOrb(state: state, audioLevel: model.audioLevel)

                VStack(alignment: .leading, spacing: 2) {
                    Text({
                        if case .failure(let message) = state {
                            return message.contains("API Key") ? "No API key" : "Failed"
                        }
                        return OverlayTheme.statusWord(for: state)
                    }())
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .foregroundStyle(Color.primary.opacity(0.88))
                        .frame(width: OverlayTheme.statusLabelWidth, alignment: .leading)
                        .lineLimit(1)

                    IntelligenceRibbon(
                        mode: OverlayTheme.ribbonMode(for: state),
                        audioLevel: model.audioLevel,
                        accent: accent,
                        secondary: secondary
                    )
                    .frame(width: OverlayTheme.ribbonWidth, height: OverlayTheme.ribbonHeight)
                }

                // Fixed slot so stop / glyph never animate in late.
                ZStack {
                    SoftStopControl(action: onStopRecording, accent: accent)
                        .opacity(state.isRecording ? 1 : 0)
                        .allowsHitTesting(state.isRecording)

                    StatusGlyph(state: state)
                        .opacity(state.isRecording ? 0 : 1)
                }
                .frame(width: 28, height: 28)
            }
            .padding(.horizontal, OverlayTheme.contentInset)
        }
        .frame(width: OverlayTheme.width, height: OverlayTheme.height)
        .clipShape(Capsule(style: .continuous))
        // No state-driven appearance animation — prevents staggered chrome.
        // Keep audioLevel updates live (do not freeze the waveform).
        .animation(nil, value: state)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(state.statusText)
    }
}
