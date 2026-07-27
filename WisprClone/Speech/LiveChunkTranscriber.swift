import AVFoundation
import Foundation

/// Progressive Whisper transcription while the user is still speaking.
///
/// Strategy:
/// 1. Convert live mic buffers to 16 kHz mono floats.
/// 2. On phrase pauses (VAD silence) or a max window, commit a chunk.
/// 3. Keep a short audio overlap + prior-text prompt so chunk edges stay coherent.
/// 4. Transcribe in the background; on finish, join chunks with boundary de-dupe.
final class LiveChunkTranscriber: @unchecked Sendable {
    private let recognizer: WhisperKitRecognizer
    private let queue = DispatchQueue(label: "\(Constants.bundleIdentifier).liveasr", qos: .userInitiated)

    private var converter: AVAudioConverter?
    private var converterInputFormat: AVAudioFormat?
    private var pending16k: [Float] = []
    private var chunkTextsByIndex: [Int: String] = [:]
    private var lastCommittedText = ""
    private var inflight = 0
    private var finishWaiters: [CheckedContinuation<Void, Never>] = []
    private var closed = false
    private var chunksCommitted = 0

    /// Fired on the live-ASR queue when a chunk yields usable transcript text.
    /// Used to start LLM formatting while the user is still speaking.
    var onUsableChunk: (@Sendable (Int, String) -> Void)?

    private let targetFormat = AVAudioFormat(
        standardFormatWithSampleRate: Constants.Audio.whisperSampleRate,
        channels: 1
    )!

    private let maxChunkSamples: Int
    private let minChunkSamples: Int
    private let overlapSamples: Int

    init(recognizer: WhisperKitRecognizer) {
        self.recognizer = recognizer
        self.maxChunkSamples = Int(Constants.Audio.whisperSampleRate * Constants.Audio.liveChunkMaxSeconds)
        self.minChunkSamples = Int(Constants.Audio.whisperSampleRate * Constants.Audio.liveChunkMinSeconds)
        self.overlapSamples = Int(Constants.Audio.whisperSampleRate * Constants.Audio.liveChunkOverlapSeconds)
    }

    func ingest(_ buffer: AVAudioPCMBuffer) {
        guard let copy = Self.copyBuffer(buffer) else { return }
        queue.async { [weak self] in
            self?.appendConverted(copy)
        }
    }

    func commitOnSilence() {
        queue.async { [weak self] in
            // Natural phrase end — take the whole buffer, no audio overlap carry.
            self?.commitPending(force: false, reason: "silence", keepOverlap: false)
        }
    }

    func flushEarly() {
        queue.async { [weak self] in
            guard let self, !self.closed else { return }
            self.commitPending(force: true, reason: "early-stop", keepOverlap: false)
        }
    }

    func finish() async -> (text: String, chunkCount: Int) {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            queue.async { [weak self] in
                guard let self else {
                    cont.resume()
                    return
                }
                self.closed = true
                self.commitPending(force: true, reason: "final", keepOverlap: false)
                if self.inflight == 0 {
                    cont.resume()
                } else {
                    self.finishWaiters.append(cont)
                }
            }
        }

        let (text, count): (String, Int) = queue.sync {
            guard self.chunksCommitted > 0 else {
                return ("", 0)
            }
            let pieces = (1...self.chunksCommitted)
                .compactMap { self.chunkTextsByIndex[$0] }
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { Self.isUsableChunk($0) }
            return (Self.joinDedupingBoundaries(pieces), self.chunksCommitted)
        }
        return (text, count)
    }

    private static func isUsableChunk(_ text: String) -> Bool {
        guard !text.isEmpty else { return false }
        let folded = Self.fold(text)
        if folded.isEmpty { return false }
        let junk: Set<String> = [
            "no text", "no text to process", "there is no text",
            "thank you", "thanks", "you", "um", "uh", "blank", "silence",
            "music", "subtitle", "subtitles", "okay", "ok", "bye"
        ]
        if junk.contains(folded) { return false }
        if folded.hasPrefix("no text") || folded.hasPrefix("there is no text") { return false }
        return true
    }

    /// Prefer overlapping word sequences at chunk seams so we don't paste doubles.
    private static func joinDedupingBoundaries(_ chunks: [String]) -> String {
        guard var result = chunks.first else { return "" }
        for next in chunks.dropFirst() {
            result = mergeOverlap(result, next)
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func mergeOverlap(_ left: String, _ right: String) -> String {
        let leftWords = left.split(separator: " ").map(String.init)
        let rightWords = right.split(separator: " ").map(String.init)
        guard !leftWords.isEmpty, !rightWords.isEmpty else {
            return [left, right].filter { !$0.isEmpty }.joined(separator: " ")
        }

        let maxCheck = min(12, leftWords.count, rightWords.count)
        var overlap = 0
        for n in stride(from: maxCheck, through: 1, by: -1) {
            if leftWords.suffix(n).map({ $0.lowercased() })
                == rightWords.prefix(n).map({ $0.lowercased() }) {
                overlap = n
                break
            }
        }
        let mergedRight = rightWords.dropFirst(overlap)
        return (leftWords + mergedRight).joined(separator: " ")
    }

    private static func fold(_ text: String) -> String {
        text
            .lowercased()
            .unicodeScalars
            .map { CharacterSet.alphanumerics.contains($0) ? Character($0) : Character(" ") }
            .reduce(into: "") { partial, ch in
                if ch == " " {
                    if !partial.hasSuffix(" ") && !partial.isEmpty { partial.append(ch) }
                } else {
                    partial.append(ch)
                }
            }
            .trimmingCharacters(in: .whitespaces)
    }

    // MARK: - Private

    private func appendConverted(_ buffer: AVAudioPCMBuffer) {
        guard !closed else { return }
        guard let samples = convertTo16kMono(buffer), !samples.isEmpty else { return }
        pending16k.append(contentsOf: samples)
        if pending16k.count >= maxChunkSamples {
            commitPending(force: true, reason: "max-window", keepOverlap: true)
        }
    }

    private func commitPending(force: Bool, reason: String, keepOverlap: Bool) {
        let count = pending16k.count
        guard count > 0 else { return }
        if !force && count < minChunkSamples { return }

        let chunk: [Float]
        if keepOverlap, count > overlapSamples {
            chunk = Array(pending16k)
            pending16k = Array(pending16k.suffix(overlapSamples))
        } else {
            chunk = pending16k
            pending16k.removeAll(keepingCapacity: true)
        }

        chunksCommitted += 1
        let index = chunksCommitted
        let promptContext = lastCommittedText
        inflight += 1

        AppLogger.speech.info(
            "Live ASR chunk #\(index) (\(reason, privacy: .public), \(chunk.count) samples)"
        )
        DiagnosticLog.write("live chunk #\(index) reason=\(reason) samples=\(chunk.count)")

        Task { [recognizer, chunk, index, promptContext] in
            let text: String
            do {
                text = try await recognizer.transcribe(
                    samples: chunk,
                    promptContext: promptContext.isEmpty ? nil : promptContext
                )
            } catch {
                AppLogger.speech.error(
                    "Live ASR chunk #\(index) failed: \(error.localizedDescription, privacy: .public)"
                )
                text = ""
            }
            self.queue.async {
                self.chunkTextsByIndex[index] = text
                if Self.isUsableChunk(text) {
                    self.lastCommittedText = text
                    self.onUsableChunk?(index, text)
                }
                self.inflight -= 1
                if self.closed, self.inflight == 0 {
                    let waiters = self.finishWaiters
                    self.finishWaiters.removeAll()
                    waiters.forEach { $0.resume() }
                }
            }
        }
    }

    private func convertTo16kMono(_ buffer: AVAudioPCMBuffer) -> [Float]? {
        let inputFormat = buffer.format
        if converter == nil || converterInputFormat != inputFormat {
            converter = AVAudioConverter(from: inputFormat, to: targetFormat)
            converterInputFormat = inputFormat
        }
        guard let converter else { return nil }

        let ratio = targetFormat.sampleRate / max(inputFormat.sampleRate, 1)
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 32
        guard let out = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else {
            return nil
        }

        final class Flag: @unchecked Sendable { var consumed = false }
        let flag = Flag()
        var error: NSError?
        let status = converter.convert(to: out, error: &error) { _, outStatus in
            if flag.consumed {
                outStatus.pointee = .noDataNow
                return nil
            }
            flag.consumed = true
            outStatus.pointee = .haveData
            return buffer
        }
        guard status != .error, error == nil, out.frameLength > 0,
              let channel = out.floatChannelData?[0]
        else {
            return nil
        }
        return Array(UnsafeBufferPointer(start: channel, count: Int(out.frameLength)))
    }

    private static func copyBuffer(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let copy = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameLength)
        else { return nil }
        copy.frameLength = buffer.frameLength
        let channels = Int(buffer.format.channelCount)
        if let src = buffer.floatChannelData, let dst = copy.floatChannelData {
            for c in 0..<channels {
                memcpy(dst[c], src[c], Int(buffer.frameLength) * MemoryLayout<Float>.size)
            }
            return copy
        }
        if let src = buffer.int16ChannelData, let dst = copy.int16ChannelData {
            for c in 0..<channels {
                memcpy(dst[c], src[c], Int(buffer.frameLength) * MemoryLayout<Int16>.size)
            }
            return copy
        }
        return nil
    }
}
