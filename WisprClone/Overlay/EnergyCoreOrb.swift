import SwiftUI

/// Compact monochrome orb — reacts to mic level.
struct EnergyCoreOrb: View {
    let state: RecordingState
    let audioLevel: CGFloat

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
            orbContent(at: timeline.date.timeIntervalSinceReferenceDate)
        }
        .frame(width: OverlayTheme.orbSize + 10, height: OverlayTheme.orbSize + 10)
    }

    @ViewBuilder
    private func orbContent(at t: TimeInterval) -> some View {
        let breath = 0.5 + 0.5 * sin(t * (2 * .pi / OverlayTheme.Motion.breathDuration))
        let listenBoost = state.isRecording ? audioLevel * 0.28 : 0
        let scale = 0.94 + CGFloat(breath) * 0.06 + listenBoost
        let frozen: Bool = {
            if case .failure = state { return true }
            return false
        }()

        ZStack {
            Circle()
                .fill(Color.white.opacity(0.12 + breath * 0.06))
                .frame(width: OverlayTheme.orbSize + 12, height: OverlayTheme.orbSize + 12)
                .blur(radius: 6)

            Circle()
                .fill(
                    RadialGradient(
                        colors: [
                            Color.white.opacity(0.95),
                            Color(white: 0.72),
                            Color(white: 0.35),
                            Color(white: 0.18)
                        ],
                        center: UnitPoint(x: 0.35, y: 0.32),
                        startRadius: 0,
                        endRadius: 14
                    )
                )
                .frame(width: OverlayTheme.orbSize, height: OverlayTheme.orbSize)

            Circle()
                .fill(Color.white.opacity(0.55))
                .frame(width: 6, height: 4)
                .offset(x: -3, y: -4)
                .blur(radius: 0.8)
        }
        .scaleEffect(frozen ? 0.96 : scale)
        .opacity(orbOpacity(frozen: frozen))
    }

    private func orbOpacity(frozen: Bool) -> Double {
        if case .idle = state { return 0 }
        if frozen { return 0.7 }
        return 1
    }
}
