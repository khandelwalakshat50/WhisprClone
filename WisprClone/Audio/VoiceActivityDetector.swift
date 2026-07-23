import AVFoundation
import Foundation
import os

/// Real-time RMS energy VAD.
///
/// After speech is first detected, recording should stop once cumulative
/// silence below the RMS threshold reaches ~700 ms.
final class VoiceActivityDetector: @unchecked Sendable {
    struct Configuration: Sendable {
        /// RMS below this is treated as silence (linear float amplitude).
        var silenceThreshold: Float = 0.006
        /// Required consecutive silence after speech before stop.
        var silenceDuration: TimeInterval = 0.7
        /// Minimum speech duration before silence can end the utterance.
        var minimumSpeechDuration: TimeInterval = 0.15
    }

    enum Event: Sendable {
        case speechStarted
        case silenceTimedOut
    }

    typealias EventHandler = @Sendable (Event) -> Void
    typealias LevelHandler = @Sendable (Float) -> Void

    private let logger = Logger(subsystem: Constants.bundleIdentifier, category: "VAD")
    private let config: Configuration
    private let onLevel: LevelHandler
    private let onEvent: EventHandler
    private let lock = NSLock()

    private var hasDetectedSpeech = false
    private var cumulativeSilence: TimeInterval = 0
    private var speechDuration: TimeInterval = 0
    private var didFireTimeout = false

    init(
        configuration: Configuration = Configuration(
            silenceDuration: TimeInterval(Constants.Audio.silenceDurationMilliseconds) / 1000
        ),
        onLevel: @escaping LevelHandler = { _ in },
        onEvent: @escaping EventHandler
    ) {
        self.config = configuration
        self.onLevel = onLevel
        self.onEvent = onEvent
    }

    func reset() {
        lock.lock()
        defer { lock.unlock() }
        hasDetectedSpeech = false
        cumulativeSilence = 0
        speechDuration = 0
        didFireTimeout = false
    }

    /// Process one PCM buffer. Safe to call from the audio render thread.
    func process(buffer: AVAudioPCMBuffer) {
        let rms = Self.rms(of: buffer)
        onLevel(rms)
        let frameDuration = Double(buffer.frameLength) / buffer.format.sampleRate

        lock.lock()
        defer { lock.unlock() }
        guard !didFireTimeout else { return }

        if rms >= config.silenceThreshold {
            if !hasDetectedSpeech {
                hasDetectedSpeech = true
                logger.debug("Speech detected (rms=\(rms, format: .fixed(precision: 4)))")
                onEvent(.speechStarted)
            }
            speechDuration += frameDuration
            cumulativeSilence = 0
        } else if hasDetectedSpeech {
            cumulativeSilence += frameDuration
            if speechDuration >= config.minimumSpeechDuration,
               cumulativeSilence >= config.silenceDuration {
                didFireTimeout = true
                logger.debug("Silence timeout (\(self.cumulativeSilence, format: .fixed(precision: 3))s)")
                onEvent(.silenceTimedOut)
            }
        }
    }

    // MARK: - RMS

    static func rms(of buffer: AVAudioPCMBuffer) -> Float {
        let channelCount = Int(buffer.format.channelCount)
        let frameLength = Int(buffer.frameLength)
        guard channelCount > 0, frameLength > 0 else { return 0 }

        var sum: Float = 0
        var count: Float = 0

        if let channelData = buffer.floatChannelData {
            for channel in 0..<channelCount {
                let samples = channelData[channel]
                for i in 0..<frameLength {
                    let sample = samples[i]
                    sum += sample * sample
                }
            }
            count = Float(frameLength * channelCount)
        } else if let channelData = buffer.int16ChannelData {
            let scale: Float = 1.0 / Float(Int16.max)
            for channel in 0..<channelCount {
                let samples = channelData[channel]
                for i in 0..<frameLength {
                    let sample = Float(samples[i]) * scale
                    sum += sample * sample
                }
            }
            count = Float(frameLength * channelCount)
        } else {
            return 0
        }

        guard count > 0 else { return 0 }
        return sqrt(sum / count)
    }
}
