import AVFoundation
import CoreAudio
import Foundation
import os

/// Captures microphone audio via `AVAudioEngine`, writing a WAV file
/// while streaming PCM buffers to an optional tap handler (VAD / live ASR).
///
/// Critical on macOS: the tap format must match the *hardware* input format
/// (`inputFormat(forBus:)`), not `outputFormat(forBus:)`. A mismatch (e.g.
/// tap at 16/48 kHz while the mic runs at 96 kHz) causes AVAudioEngine to
/// silently drop every buffer — flat meters, empty transcripts, no error.
final class AudioRecorder: @unchecked Sendable {
    typealias BufferHandler = @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void

    enum RecorderError: Error, LocalizedError {
        case engineStartFailed
        case noInput
        case fileCreateFailed

        var errorDescription: String? {
            switch self {
            case .engineStartFailed: return "Could not start audio engine"
            case .noInput: return "No microphone input available"
            case .fileCreateFailed: return "Could not create recording file"
            }
        }
    }

    private let logger = Logger(subsystem: Constants.bundleIdentifier, category: "AudioRecorder")
    private let queue = DispatchQueue(label: "\(Constants.bundleIdentifier).audio", qos: .userInitiated)

    private var engine = AVAudioEngine()
    private var audioFile: AVAudioFile?
    private var outputURL: URL?
    private var isRecording = false
    private var tapInstalled = false
    private var bufferHandler: BufferHandler?
    private var peakRMS: Float = 0
    private var bufferCount: Int = 0
    private var framesCaptured: Int = 0

    var isRunning: Bool { queue.sync { isRecording } }

    /// Peak RMS seen during the current (or last) recording — for diagnostics.
    var lastPeakRMS: Float { queue.sync { peakRMS } }

    func start(onBuffer: BufferHandler? = nil) throws -> URL {
        try queue.sync {
            teardownLocked(keepOutputURL: false)

            bufferHandler = onBuffer
            peakRMS = 0
            bufferCount = 0
            framesCaptured = 0

            engine = AVAudioEngine()
            let input = engine.inputNode

            // Hardware format — never use outputFormat for the tap on macOS.
            var hw = input.inputFormat(forBus: 0)
            let outFmt = input.outputFormat(forBus: 0)
            let coreRate = Self.defaultInputSampleRate()

            // Cold engines sometimes report sampleRate == 0. Prepare once and re-read.
            if hw.sampleRate <= 0 || hw.channelCount == 0 {
                engine.prepare()
                hw = input.inputFormat(forBus: 0)
            }

            // Last resort: synthesize a Float32 format from Core Audio's nominal
            // rate when the node still reports an unusable format.
            if (hw.sampleRate <= 0 || hw.channelCount == 0),
               let coreRate, coreRate > 0,
               let synthesized = AVAudioFormat(
                   commonFormat: .pcmFormatFloat32,
                   sampleRate: coreRate,
                   channels: 1,
                   interleaved: false
               ) {
                logger.warning(
                    "inputFormat unusable — synthesizing tap at \(coreRate, format: .fixed(precision: 0))Hz"
                )
                hw = synthesized
            } else if let coreRate, coreRate > 0, abs(hw.sampleRate - coreRate) > 1 {
                // Log only — inventing a tap format that disagrees with the AU
                // stream also causes silent capture. Prefer the node's inputFormat.
                logger.warning(
                    "inputFormat \(hw.sampleRate, format: .fixed(precision: 0))Hz ≠ CoreAudio \(coreRate, format: .fixed(precision: 0))Hz — keeping inputFormat"
                )
            }

            guard hw.sampleRate > 0, hw.channelCount > 0 else {
                teardownLocked(keepOutputURL: false)
                throw RecorderError.noInput
            }

            // Tap MUST match the hardware stream. Forcing a different rate
            // (e.g. 16 kHz when the mic is 48/96 kHz) silently drops buffers.
            let tapFormat = hw

            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("wispr-\(UUID().uuidString).wav")
            // File format must match tap buffers exactly or every write fails.
            do {
                audioFile = try AVAudioFile(forWriting: url, settings: tapFormat.settings)
            } catch {
                teardownLocked(keepOutputURL: false)
                logger.error("AVAudioFile create failed: \(error.localizedDescription, privacy: .public)")
                throw RecorderError.fileCreateFailed
            }
            outputURL = url

            input.removeTap(onBus: 0)
            // Explicit hardware inputFormat — nil falls back to outputFormat and
            // silently drops buffers when those rates disagree (common on Mac).
            input.installTap(onBus: 0, bufferSize: 4096, format: tapFormat) { [weak self] buffer, time in
                self?.handleTap(buffer: buffer, time: time)
            }
            tapInstalled = true

            engine.prepare()
            do {
                try engine.start()
            } catch {
                teardownLocked(keepOutputURL: false)
                logger.error("Engine start failed: \(error.localizedDescription, privacy: .public)")
                throw RecorderError.engineStartFailed
            }

            isRecording = true
            logger.info(
                "Recording started \(url.lastPathComponent, privacy: .public) tap=\(tapFormat.sampleRate, format: .fixed(precision: 0))Hz ch=\(tapFormat.channelCount)"
            )
            DiagnosticLog.write(
                String(
                    format: "recorder tap in=%.0fHz out=%.0fHz core=%.0fHz ch=%d fmt=%@",
                    tapFormat.sampleRate,
                    outFmt.sampleRate,
                    coreRate ?? -1,
                    tapFormat.channelCount,
                    String(describing: tapFormat.commonFormat.rawValue)
                )
            )
            return url
        }
    }

    @discardableResult
    func stop() -> URL? {
        queue.sync {
            let url = outputURL
            let peak = peakRMS
            let buffers = bufferCount
            let frames = framesCaptured
            teardownLocked(keepOutputURL: true)
            logger.info(
                "Recording stopped peakRMS=\(peak, format: .fixed(precision: 4)) buffers=\(buffers) frames=\(frames)"
            )
            DiagnosticLog.write(
                String(format: "recorder stopped peakRMS=%.4f buffers=%d frames=%d", peak, buffers, frames)
            )
            return url
        }
    }

    // MARK: - Private

    private func teardownLocked(keepOutputURL: Bool) {
        if tapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        } else {
            engine.inputNode.removeTap(onBus: 0)
        }

        if engine.isRunning {
            engine.stop()
        }
        engine.reset()

        audioFile = nil
        bufferHandler = nil
        isRecording = false
        if !keepOutputURL {
            outputURL = nil
        }

        engine = AVAudioEngine()
    }

    private func handleTap(buffer: AVAudioPCMBuffer, time: AVAudioTime) {
        bufferCount += 1
        framesCaptured += Int(buffer.frameLength)

        let rms = VoiceActivityDetector.rms(of: buffer)
        if rms > peakRMS { peakRMS = rms }

        if let audioFile {
            do {
                try audioFile.write(from: buffer)
            } catch {
                logger.error("Buffer write failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        bufferHandler?(buffer, time)
    }

    /// Nominal sample rate of the system default input device (Core Audio).
    private static func defaultInputSampleRate() -> Double? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID = AudioDeviceID()
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &size,
            &deviceID
        ) == noErr, deviceID != kAudioObjectUnknown else {
            return nil
        }

        address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var rate = Float64(0)
        size = UInt32(MemoryLayout<Float64>.size)
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &rate) == noErr else {
            return nil
        }
        return rate > 0 ? rate : nil
    }
}
