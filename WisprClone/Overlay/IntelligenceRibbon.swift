import SwiftUI

/// Neon light ribbon — cyan/magenta when listening, swirling when thinking.
struct IntelligenceRibbon: View {
    let mode: OverlayTheme.RibbonMode
    let audioLevel: CGFloat
    let accent: Color
    let secondary: Color

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / OverlayTheme.Motion.ribbonFPS)) { timeline in
            let time = timeline.date.timeIntervalSinceReferenceDate
            Canvas { context, size in
                let amplitude = currentAmplitude(time: time)
                let colors = ribbonColors()
                let path = filamentPath(size: size, time: time, amplitude: amplitude, phase: 0)

                // Single neon ribbon (soft bloom under one stroke — not a second line)
                context.drawLayer { glow in
                    glow.addFilter(.blur(radius: 4))
                    glow.stroke(
                        path,
                        with: .color(colors.first?.opacity(0.45) ?? .white.opacity(0.3)),
                        style: StrokeStyle(lineWidth: 6, lineCap: .round)
                    )
                }

                context.stroke(
                    path,
                    with: .linearGradient(
                        Gradient(colors: colors),
                        startPoint: .zero,
                        endPoint: CGPoint(x: size.width, y: 0)
                    ),
                    style: StrokeStyle(lineWidth: 2.4, lineCap: .round, lineJoin: .round)
                )
            }
        }
        // Intentionally no audio spring animation — keeps chrome from staggering on open.
    }

    private func filamentPath(
        size: CGSize,
        time: TimeInterval,
        amplitude: CGFloat,
        phase: Double
    ) -> Path {
        var path = Path()
        let midY = size.height * 0.5
        let speed: Double
        switch mode {
        case .listening: speed = 1.05
        case .thinking: speed = 2.15
        case .refining: speed = 0.55
        case .injecting: speed = 1.6
        case .settled: speed = 0.35
        case .failed: speed = 0
        }

        let p = time * speed + phase
        let step: CGFloat = 1.5
        let injectPull = mode == .injecting ? 0.55 : 1.0

        for x in stride(from: CGFloat.zero, through: size.width, by: step) {
            let u = x / max(size.width, 1)
            let envelope = pow(sin(u * .pi), 1.2) * injectPull

            let y: CGFloat
            switch mode {
            case .listening:
                let primary = sin(u * .pi * 3.2 + p)
                let detail = sin(u * .pi * 7.4 - p * 0.7) * 0.28
                y = midY + (primary + detail) * amplitude * envelope
            case .thinking:
                // Fast left→right swirl
                let wave = sin(u * .pi * 4.0 - p * 2.2)
                let swirl = sin(u * .pi * 9.0 + p) * 0.22
                y = midY + (wave + swirl) * amplitude * envelope
            case .refining:
                let breath = sin(p * 0.9)
                y = midY + breath * amplitude * envelope * 0.85
            case .injecting:
                // Collapse toward center
                let towardCenter = abs(u - 0.5) * 2
                let wave = sin(u * .pi * 5 - p * 1.5) * (1 - towardCenter * 0.7)
                y = midY + wave * amplitude * envelope
            case .settled:
                y = midY + sin(u * .pi * 2 + p * 0.4) * amplitude * envelope
            case .failed:
                y = midY + sin(u * .pi * 2.2) * amplitude * envelope
            }

            if x == 0 {
                path.move(to: CGPoint(x: x, y: y))
            } else {
                path.addLine(to: CGPoint(x: x, y: y))
            }
        }
        return path
    }

    private func currentAmplitude(time: TimeInterval) -> CGFloat {
        switch mode {
        case .listening:
            return 2.2 + min(max(audioLevel, 0), 1) * 9.5
        case .thinking:
            return 4.2 + CGFloat((sin(time * 1.8) + 1) * 1.4)
        case .refining:
            let breath = (sin(time * (2 * .pi / OverlayTheme.Motion.breathDuration)) + 1) / 2
            return 2.6 + CGFloat(breath) * 2.2
        case .injecting:
            return 3.4
        case .settled:
            return 1.2
        case .failed:
            return 1.6
        }
    }

    private func ribbonColors() -> [Color] {
        switch mode {
        case .listening:
            return [Color.white.opacity(0.95), Color(white: 0.65)]
        case .thinking, .refining, .injecting:
            return [Color.white.opacity(0.85), Color(white: 0.55)]
        case .settled:
            return [Color.white.opacity(0.75), Color(white: 0.45)]
        case .failed:
            return [Color(white: 0.55), Color(white: 0.35)]
        }
    }
}
