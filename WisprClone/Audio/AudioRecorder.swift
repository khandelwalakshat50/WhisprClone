import AVFoundation
import Foundation
import os

/// Captures microphone audio via `AVAudioEngine`, writing a mono WAV file
/// while streaming PCM buffers to an optional tap handler (VAD).
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
    private let engine = AVAudioEngine()
    private let queue = DispatchQueue(label: "\(Constants.bundleIdentifier).audio", qos: .userInitiated)

    private var audioFile: AVAudioFile?
    private var outputURL: URL?
    private var isRecording = false
    private var bufferHandler: BufferHandler?

    var isRunning: Bool { queue.sync { isRecording } }

    /// Starts capture. Buffers are forwarded to `onBuffer` on the audio render thread.
    func start(onBuffer: BufferHandler? = nil) throws -> URL {
        try queue.sync {
            guard !isRecording else {
                guard let outputURL else { throw RecorderError.fileCreateFailed }
                return outputURL
            }

            bufferHandler = onBuffer

            let input = engine.inputNode
            let format = input.outputFormat(forBus: 0)
            guard format.sampleRate > 0, format.channelCount > 0 else {
                throw RecorderError.noInput
            }

            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("wispr-\(UUID().uuidString).wav")

            do {
                audioFile = try AVAudioFile(forWriting: url, settings: format.settings)
            } catch {
                logger.error("AVAudioFile create failed: \(error.localizedDescription, privacy: .public)")
                throw RecorderError.fileCreateFailed
            }
            outputURL = url

            input.removeTap(onBus: 0)
            input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, time in
                self?.handleTap(buffer: buffer, time: time)
            }

            engine.prepare()
            do {
                try engine.start()
            } catch {
                input.removeTap(onBus: 0)
                audioFile = nil
                outputURL = nil
                logger.error("Engine start failed: \(error.localizedDescription, privacy: .public)")
                throw RecorderError.engineStartFailed
            }

            isRecording = true
            logger.info("Recording started → \(url.lastPathComponent, privacy: .public)")
            return url
        }
    }

    /// Stops capture and returns the written file URL.
    @discardableResult
    func stop() -> URL? {
        queue.sync {
            guard isRecording else { return outputURL }
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
            audioFile = nil
            bufferHandler = nil
            isRecording = false
            logger.info("Recording stopped")
            return outputURL
        }
    }

    private func handleTap(buffer: AVAudioPCMBuffer, time: AVAudioTime) {
        if let audioFile {
            do {
                try audioFile.write(from: buffer)
            } catch {
                logger.error("Buffer write failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        bufferHandler?(buffer, time)
    }
}
