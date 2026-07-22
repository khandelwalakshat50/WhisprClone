import SwiftUI

/// Premium, persistent overlay surface. Keeping one observed model alive allows
/// recording → processing → completion to transition instead of being replaced.
struct StatusView: View {
    @ObservedObject var model: OverlayPresentationModel
    let onStopRecording: () -> Void

    private var state: RecordingState { model.state }

    var body: some View {
        ZStack {
            glassBackground
            ambientLight

            HStack(spacing: 11) {
                statusOrb

                VStack(alignment: .leading, spacing: 1) {
                    Text(state.eyebrow)
                        .font(.system(size: 8, weight: .semibold, design: .rounded))
                        .tracking(1.15)
                        .foregroundStyle(.white.opacity(0.48))
                        .contentTransition(.opacity)

                    LiquidEnergyWaveform(
                        mode: state.waveformMode,
                        audioLevel: model.audioLevel
                    )
                    .frame(width: 142, height: 27)
                }

                trailingControl
                    .frame(width: 31, height: 31)
            }
            .padding(.horizontal, 14)
        }
        .frame(width: Constants.Overlay.width, height: Constants.Overlay.height)
        .clipShape(RoundedRectangle(cornerRadius: Constants.Overlay.cornerRadius, style: .continuous))
        .compositingGroup()
        .shadow(color: .black.opacity(0.48), radius: 22, y: 10)
        .shadow(color: state.accentColor.opacity(0.12), radius: 18)
        .animation(.spring(response: 0.52, dampingFraction: 0.84), value: state)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(state.statusText)
    }

    private var glassBackground: some View {
        RoundedRectangle(cornerRadius: Constants.Overlay.cornerRadius, style: .continuous)
            .fill(.ultraThinMaterial)
            .overlay {
                LinearGradient(
                    colors: [
                        Color(red: 0.105, green: 0.115, blue: 0.13).opacity(0.98),
                        Color(red: 0.045, green: 0.05, blue: 0.06).opacity(0.97)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            }
            .overlay {
                RoundedRectangle(cornerRadius: Constants.Overlay.cornerRadius, style: .continuous)
                    .stroke(
                        LinearGradient(
                            colors: [.white.opacity(0.18), .white.opacity(0.035), .clear],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 0.75
                    )
            }
            .overlay(alignment: .top) {
                Capsule()
                    .fill(.white.opacity(0.12))
                    .frame(width: Constants.Overlay.width * 0.56, height: 0.5)
                    .blur(radius: 0.25)
                    .padding(.top, 1)
            }
    }

    private var ambientLight: some View {
        RadialGradient(
            colors: [state.accentColor.opacity(0.13), .clear],
            center: .init(x: 0.43, y: 0.65),
            startRadius: 0,
            endRadius: 105
        )
        .allowsHitTesting(false)
        .animation(.easeInOut(duration: 0.8), value: state)
    }

    @ViewBuilder
    private var statusOrb: some View {
        ZStack {
            Circle()
                .fill(state.accentColor.opacity(0.14))
                .frame(width: 19, height: 19)
                .blur(radius: 3)

            Circle()
                .fill(
                    RadialGradient(
                        colors: [.white.opacity(0.95), state.accentColor],
                        center: .topLeading,
                        startRadius: 0,
                        endRadius: 7
                    )
                )
                .frame(width: 7, height: 7)
                .shadow(color: state.accentColor.opacity(0.9), radius: 6)
        }
        .scaleEffect(state.isRecording ? 1.06 : 0.9)
        .opacity(state == .idle ? 0 : 1)
        .animation(
            state.isRecording
                ? .easeInOut(duration: 1.35).repeatForever(autoreverses: true)
                : .spring(response: 0.45, dampingFraction: 0.8),
            value: state
        )
    }

    @ViewBuilder
    private var trailingControl: some View {
        if state.isRecording {
            Button(action: onStopRecording) {
                Image(systemName: "stop.fill")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.white.opacity(0.88))
                    .frame(width: 27, height: 27)
                    .background {
                        Circle()
                            .fill(.white.opacity(0.075))
                            .overlay {
                                Circle().stroke(.white.opacity(0.1), lineWidth: 0.5)
                            }
                    }
            }
            .buttonStyle(PremiumCircleButtonStyle())
            .help("Stop and transcribe")
            .transition(.scale(scale: 0.72).combined(with: .opacity))
        } else {
            stateSymbol
                .transition(.scale(scale: 0.72).combined(with: .opacity))
        }
    }

    @ViewBuilder
    private var stateSymbol: some View {
        switch state {
        case .transcribing, .formatting:
            Image(systemName: "sparkles")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.68))
                .symbolEffect(.variableColor.iterative, options: .repeating)
        case .injecting:
            Image(systemName: "arrow.down.doc")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.68))
        case .success:
            Image(systemName: "checkmark")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color(red: 0.4, green: 0.9, blue: 0.76))
                .symbolEffect(.bounce)
        case .failure:
            Image(systemName: "exclamationmark")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color(red: 0.58, green: 0.72, blue: 0.9))
        case .idle, .listening, .detectingSpeech:
            EmptyView()
        }
    }
}

// MARK: - Liquid energy ribbon

struct LiquidEnergyWaveform: View {
    enum Mode {
        case recording
        case processing
        case settled
        case failed
    }

    let mode: Mode
    let audioLevel: CGFloat

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 45.0, paused: mode == .settled)) { timeline in
            Canvas { context, size in
                let time = timeline.date.timeIntervalSinceReferenceDate
                drawBaseline(in: &context, size: size)

                for layer in 0..<3 {
                    let path = ribbonPath(
                        size: size,
                        time: time,
                        layer: layer
                    )
                    let gradient = GraphicsContext.Shading.linearGradient(
                        Gradient(colors: colors.map {
                            $0.opacity(0.92 - Double(layer) * 0.22)
                        }),
                        startPoint: .zero,
                        endPoint: CGPoint(x: size.width, y: 0)
                    )

                    if layer == 0 {
                        context.drawLayer { glow in
                            glow.addFilter(.blur(radius: 5.5))
                            glow.stroke(path, with: gradient, lineWidth: 4.2)
                        }
                    }

                    context.stroke(
                        path,
                        with: gradient,
                        style: StrokeStyle(
                            lineWidth: layer == 0 ? 1.8 : 1.05,
                            lineCap: .round,
                            lineJoin: .round
                        )
                    )
                }
            }
        }
        .animation(.spring(response: 0.24, dampingFraction: 0.72), value: audioLevel)
        .transition(.opacity.combined(with: .scale(scale: 0.94)))
    }

    private func ribbonPath(size: CGSize, time: TimeInterval, layer: Int) -> Path {
        var path = Path()
        let layerOffset = Double(layer) * 1.65
        let speed = mode == .processing ? 1.65 : 1.15
        let phase = time * speed + layerOffset
        let amplitude = currentAmplitude(time: time) * (1 - CGFloat(layer) * 0.16)

        for x in stride(from: CGFloat.zero, through: size.width, by: 1) {
            let progress = x / max(size.width, 1)
            let envelope = pow(sin(progress * .pi), 0.72)
            let primary = sin(progress * .pi * 4.0 + phase)
            let detail = sin(progress * .pi * 7.3 - phase * 0.62 + layerOffset) * 0.22
            let drift = sin(progress * .pi * 1.2 + phase * 0.35) * 0.14
            let y = size.height / 2 + (primary + detail + drift) * amplitude * envelope

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
        case .recording:
            return 2.3 + min(audioLevel, 1) * 9.4
        case .processing:
            let breath = (sin(time * 1.7) + 1) / 2
            return 4.8 + CGFloat(breath) * 2.2
        case .settled:
            return 1.1
        case .failed:
            return 2
        }
    }

    private var colors: [Color] {
        switch mode {
        case .recording:
            return [
                Color(red: 0.2, green: 0.94, blue: 0.94),
                Color(red: 0.2, green: 0.67, blue: 1),
                Color(red: 0.25, green: 0.88, blue: 0.76)
            ]
        case .processing:
            return [
                Color(red: 0.25, green: 0.9, blue: 0.98),
                Color(red: 0.3, green: 0.52, blue: 1),
                Color(red: 0.58, green: 0.38, blue: 0.96)
            ]
        case .settled:
            return [
                Color(red: 0.35, green: 0.86, blue: 0.76),
                Color(red: 0.3, green: 0.67, blue: 0.92)
            ]
        case .failed:
            return [
                Color(red: 0.44, green: 0.62, blue: 0.86),
                Color(red: 0.48, green: 0.4, blue: 0.7)
            ]
        }
    }

    private func drawBaseline(in context: inout GraphicsContext, size: CGSize) {
        var baseline = Path()
        baseline.move(to: CGPoint(x: 0, y: size.height / 2))
        baseline.addLine(to: CGPoint(x: size.width, y: size.height / 2))
        context.stroke(baseline, with: .color(.white.opacity(0.055)), lineWidth: 0.5)
    }
}

// MARK: - Tactile control

private struct PremiumCircleButtonStyle: ButtonStyle {
    @State private var hovering = false

    func makeBody(configuration: ButtonStyleConfiguration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.88 : hovering ? 1.04 : 1)
            .brightness(hovering ? 0.08 : 0)
            .shadow(color: .cyan.opacity(hovering ? 0.16 : 0), radius: 7)
            .animation(.spring(response: 0.24, dampingFraction: 0.72), value: configuration.isPressed)
            .animation(.spring(response: 0.3, dampingFraction: 0.8), value: hovering)
            .onHover { hovering = $0 }
    }
}

// MARK: - State presentation

extension RecordingState {
    var isRecording: Bool {
        self == .listening || self == .detectingSpeech
    }

    var waveformMode: LiquidEnergyWaveform.Mode {
        switch self {
        case .listening, .detectingSpeech: return .recording
        case .transcribing, .formatting, .injecting: return .processing
        case .success, .idle: return .settled
        case .failure: return .failed
        }
    }

    var eyebrow: String {
        switch self {
        case .idle: return ""
        case .listening, .detectingSpeech: return "LISTENING"
        case .transcribing: return "TRANSCRIBING"
        case .formatting: return "REFINING"
        case .injecting: return "INSERTING"
        case .success: return "INSERTED"
        case .failure: return "UNAVAILABLE"
        }
    }

    var accentColor: Color {
        switch self {
        case .listening, .detectingSpeech:
            return Color(red: 0.2, green: 0.9, blue: 0.94)
        case .transcribing, .formatting, .injecting:
            return Color(red: 0.38, green: 0.57, blue: 1)
        case .success:
            return Color(red: 0.4, green: 0.88, blue: 0.75)
        case .failure:
            return Color(red: 0.5, green: 0.58, blue: 0.78)
        case .idle:
            return .clear
        }
    }

    var shouldPresentOverlay: Bool {
        self != .idle
    }
}
