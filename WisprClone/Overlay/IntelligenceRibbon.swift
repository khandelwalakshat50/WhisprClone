import SwiftUI

/// Metallic silver waveform ribbon — matches the glass / ring language.
struct IntelligenceRibbon: View {
    let mode: OverlayTheme.RibbonMode
    let audioLevel: CGFloat
    let accent: Color
    let secondary: Color

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / OverlayTheme.Motion.ribbonFPS)) { timeline in
            let time = timeline.date.timeIntervalSinceReferenceDate
            Canvas { context, size in
                drawRibbon(context: &context, size: size, time: time)
            }
        }
    }

    private func drawRibbon(context: inout GraphicsContext, size: CGSize, time: TimeInterval) {
        let amplitude = currentAmplitude(time: time)
        let colors = ribbonColors()

        let glowPath = filamentPath(size: size, time: time, amplitude: amplitude * 1.05, phase: 0.15)
        context.drawLayer { glow in
            glow.addFilter(.blur(radius: 4))
            glow.stroke(
                glowPath,
                with: .linearGradient(
                    Gradient(colors: colors.map { $0.opacity(0.35) }),
                    startPoint: .zero,
                    endPoint: CGPoint(x: size.width, y: 0)
                ),
                style: StrokeStyle(lineWidth: 6, lineCap: .round)
            )
        }

        let path = filamentPath(size: size, time: time, amplitude: amplitude, phase: 0)
        context.stroke(
            path,
            with: .linearGradient(
                Gradient(colors: colors),
                startPoint: .zero,
                endPoint: CGPoint(x: size.width, y: 0)
            ),
            style: StrokeStyle(lineWidth: 1.8, lineCap: .round, lineJoin: .round)
        )

        drawBeads(context: &context, size: size, time: time, amplitude: amplitude)
    }

    private func drawBeads(
        context: inout GraphicsContext,
        size: CGSize,
        time: TimeInterval,
        amplitude: CGFloat
    ) {
        let midY = size.height * 0.5
        let count = 36
        for i in 0..<count {
            let u = CGFloat(i) / CGFloat(count - 1)
            let y = sampleY(u: u, midY: midY, time: time, amplitude: amplitude)
            let x = u * size.width
            let peak = abs(y - midY) / max(amplitude, 1)
            let color = beadColor(peak: min(peak, 1))
            let r: CGFloat = 1.0 + peak * 1.2 + (mode == .listening ? audioLevel * 0.7 : 0)
            var ctx = context
            ctx.opacity = 0.45 + Double(peak) * 0.4
            ctx.fill(
                Path(ellipseIn: CGRect(x: x - r * 0.5, y: y - r * 0.5, width: r, height: r)),
                with: .color(color)
            )
        }
    }

    private func beadColor(peak: CGFloat) -> Color {
        if peak < 0.45 {
            return OverlayTheme.lerp(OverlayTheme.silverDark, OverlayTheme.silver, peak / 0.45)
        }
        return OverlayTheme.lerp(OverlayTheme.silver, OverlayTheme.silverBright, (peak - 0.45) / 0.55)
    }

    private func filamentPath(
        size: CGSize,
        time: TimeInterval,
        amplitude: CGFloat,
        phase: Double
    ) -> Path {
        var path = Path()
        let midY = size.height * 0.5
        let step: CGFloat = 1.5
        for x in stride(from: CGFloat.zero, through: size.width, by: step) {
            let u = x / max(size.width, 1)
            let y = sampleY(u: u, midY: midY, time: time + phase, amplitude: amplitude)
            if x == 0 {
                path.move(to: CGPoint(x: x, y: y))
            } else {
                path.addLine(to: CGPoint(x: x, y: y))
            }
        }
        return path
    }

    private func sampleY(u: CGFloat, midY: CGFloat, time: TimeInterval, amplitude: CGFloat) -> CGFloat {
        let speed: Double
        switch mode {
        case .listening: speed = 1.15
        case .thinking: speed = 2.25
        case .refining: speed = 0.55
        case .injecting: speed = 1.7
        case .settled: speed = 0.35
        case .failed: speed = 0
        }

        let p = time * speed
        let envelope = pow(sin(Double(u) * .pi), 1.15)
        let injectPull = mode == .injecting ? 0.55 : 1.0

        let wave: Double
        switch mode {
        case .listening:
            let primary = sin(Double(u) * .pi * 3.4 + p)
            let detail = sin(Double(u) * .pi * 8.1 - p * 0.75) * 0.32
            wave = primary + detail
        case .thinking:
            let swirl = sin(Double(u) * .pi * 4.2 - p * 2.3)
            let detail = sin(Double(u) * .pi * 10 + p) * 0.24
            wave = swirl + detail
        case .refining:
            wave = sin(p * 0.9) * 0.9
        case .injecting:
            let towardCenter = abs(Double(u) - 0.5) * 2
            wave = sin(Double(u) * .pi * 5 - p * 1.5) * (1 - towardCenter * 0.7)
        case .settled:
            wave = sin(Double(u) * .pi * 2 + p * 0.4)
        case .failed:
            wave = sin(Double(u) * .pi * 2.2)
        }

        return midY + CGFloat(wave * envelope * injectPull) * amplitude
    }

    private func currentAmplitude(time: TimeInterval) -> CGFloat {
        switch mode {
        case .listening:
            return 2.4 + min(max(audioLevel, 0), 1) * 10.5
        case .thinking:
            return 4.4 + CGFloat((sin(time * 1.8) + 1) * 1.5)
        case .refining:
            let breath = (sin(time * (2 * .pi / OverlayTheme.Motion.breathDuration)) + 1) / 2
            return 2.8 + CGFloat(breath) * 2.4
        case .injecting:
            return 3.6
        case .settled:
            return 1.3
        case .failed:
            return 1.6
        }
    }

    private func ribbonColors() -> [Color] {
        switch mode {
        case .listening, .thinking, .injecting:
            return [
                OverlayTheme.silverBright,
                OverlayTheme.silver,
                OverlayTheme.silverMid,
                OverlayTheme.silver
            ]
        case .refining:
            return [
                OverlayTheme.silver.opacity(0.95),
                OverlayTheme.silverMid.opacity(0.9),
                OverlayTheme.silverBright.opacity(0.75)
            ]
        case .settled:
            return [
                OverlayTheme.silver.opacity(0.7),
                OverlayTheme.silverMid.opacity(0.5)
            ]
        case .failed:
            return [Color(white: 0.45), Color(white: 0.28)]
        }
    }
}
