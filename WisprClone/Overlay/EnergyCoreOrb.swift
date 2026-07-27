import SwiftUI

/// Thin metallic 3D ring that revolves around an invisible center.
/// The ring keeps its circular shape (no coin-flip spin) — the whole ring orbits.
struct EnergyCoreOrb: View {
    let state: RecordingState
    let audioLevel: CGFloat

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60.0)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            Canvas { context, size in
                drawOrbitingRing(context: context, size: size, time: t)
            }
        }
        .frame(width: OverlayTheme.orbSize + 10, height: OverlayTheme.orbSize + 10)
        .opacity(orbOpacity)
        .accessibilityHidden(true)
    }

    private var orbOpacity: Double {
        if case .idle = state { return 0 }
        if case .failure = state { return 0.55 }
        return 1
    }

    private func drawOrbitingRing(context: GraphicsContext, size: CGSize, time: TimeInterval) {
        let center = CGPoint(x: size.width * 0.5, y: size.height * 0.5)
        let listening = state.isRecording
        let level = listening ? min(max(audioLevel, 0), 1) : idleDrive(for: state)
        let frozen: Bool = {
            if case .failure = state { return true }
            return false
        }()

        let period = OverlayTheme.Motion.ringOrbitDuration
        // Seamless loop: constant angular velocity; soft ease via subtle orbit ellipticity.
        let phase = frozen ? 0.15 : (time / period).truncatingRemainder(dividingBy: 1.0)
        let theta = phase * 2 * Double.pi

        // Breath on tube brightness / orbit radius (seamless sine).
        let breath = frozen ? 0.4 : 0.5 + 0.5 * sin(time * (2 * .pi / OverlayTheme.Motion.breathDuration))
        let orbitR = 7.5 + CGFloat(breath) * 0.6 + level * 1.8
        let ringR: CGFloat = 8.2 + level * 0.8

        // Fixed ring-plane tilt (3D look without tumbling the ring).
        let ringTilt: Double = 0.92 // ~53°
        let orbitTilt: Double = 0.55 // foreshortened orbital plane

        // Ring center orbits around invisible origin (planet around sun).
        let ox = orbitR * CGFloat(cos(theta))
        let oy = orbitR * CGFloat(sin(theta) * sin(orbitTilt))
        let oz = orbitR * CGFloat(sin(theta) * cos(orbitTilt))

        // Soft silver bloom at the invisible center.
        let bloomR = 11 + level * 4
        context.fill(
            Path(ellipseIn: CGRect(
                x: center.x - bloomR,
                y: center.y - bloomR,
                width: bloomR * 2,
                height: bloomR * 2
            )),
            with: .radialGradient(
                Gradient(colors: [
                    Color.white.opacity(0.14 + Double(level) * 0.12),
                    Color.white.opacity(0.04),
                    .clear
                ]),
                center: center,
                startRadius: 0,
                endRadius: bloomR
            )
        )

        // Sample the thin ring as a tilted circle in local space, then translate to orbit.
        let samples = 72
        var points: [(CGPoint, CGFloat, Double)] = [] // projected, lighting, depth

        for i in 0..<samples {
            let u = Double(i) / Double(samples)
            let phi = u * 2 * Double.pi
            // Local ring circle in XY; apply fixed tilt around X (no coin spin).
            let lx = Double(ringR) * cos(phi)
            let ly = Double(ringR) * sin(phi) * cos(ringTilt)
            let lz = Double(ringR) * sin(phi) * sin(ringTilt)

            let wx = lx + Double(ox)
            let wy = ly + Double(oy)
            let wz = lz + Double(oz)

            // Perspective projection
            let persp = 1.0 / (1.0 - wz * 0.018)
            let p = CGPoint(
                x: center.x + CGFloat(wx * persp),
                y: center.y + CGFloat(wy * persp)
            )

            // Lighting: highlight facing upper-left light.
            let nx = cos(phi)
            let ny = sin(phi) * cos(ringTilt)
            let nz = sin(phi) * sin(ringTilt)
            let light = max(0, nx * -0.35 + ny * -0.55 + nz * 0.75)
            let shade = 0.28 + 0.72 * light

            points.append((p, CGFloat(shade), wz))
        }

        // Soft metallic trail glow under the ring path.
        var glowPath = Path()
        for (idx, item) in points.enumerated() {
            if idx == 0 { glowPath.move(to: item.0) }
            else { glowPath.addLine(to: item.0) }
        }
        glowPath.closeSubpath()
        context.drawLayer { glow in
            glow.addFilter(.blur(radius: 2.2))
            glow.stroke(
                glowPath,
                with: .color(Color.white.opacity(0.22 + Double(level) * 0.15)),
                style: StrokeStyle(lineWidth: 3.2, lineCap: .round)
            )
        }

        // Draw ring segments back-to-front so nearer metal sits on top.
        let ordered = points.indices.sorted { points[$0].2 < points[$1].2 }
        for idx in ordered {
            let (p, shade, z) = points[idx]
            let next = points[(idx + 1) % samples]
            let depthFade = 0.45 + 0.55 * ((z + orbitR + ringR) / max(2 * (orbitR + ringR), 1))
            let brightness = Double(shade) * Double(min(max(depthFade, 0.35), 1))
            let color = OverlayTheme.lerp(
                OverlayTheme.silverDeep,
                OverlayTheme.silverBright,
                CGFloat(brightness)
            )
            var ctx = context
            ctx.opacity = 0.75 + brightness * 0.25
            var seg = Path()
            seg.move(to: p)
            seg.addLine(to: next.0)
            let tube: CGFloat = 1.55 + CGFloat(shade) * 0.55 + level * 0.25
            ctx.stroke(
                seg,
                with: .color(color),
                style: StrokeStyle(lineWidth: tube, lineCap: .round)
            )
        }

        // Specular highlight bead on the brightest near point.
        if let best = points.max(by: { $0.1 * CGFloat($0.2) < $1.1 * CGFloat($1.2) }) {
            let r: CGFloat = 1.4
            context.fill(
                Path(ellipseIn: CGRect(x: best.0.x - r, y: best.0.y - r, width: r * 2, height: r * 2)),
                with: .color(Color.white.opacity(0.85))
            )
        }
    }

    private func idleDrive(for state: RecordingState) -> CGFloat {
        switch state {
        case .transcribing: return 0.35
        case .formatting: return 0.22
        case .injecting: return 0.40
        case .success: return 0.12
        default: return 0.08
        }
    }
}
