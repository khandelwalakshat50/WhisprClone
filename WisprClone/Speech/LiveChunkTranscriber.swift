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
    private let recognizer: any LiveChunkASREngine
    private let queue = DispatchQueue(label: "\(Constants.bundleIdentifier).liveasr", qos: .userInitiated)

    private var converter: AVAudioConverter?
    private var converterInputFormat: AVAudioFormat?
    private var pending16k: [Float] = []
    private var chunkTextsByIndex: [Int: String] = [:]
    private var chunkConfidenceByIndex: [Int: Double] = [:]
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

    init(recognizer: any LiveChunkASREngine) {
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

    /// Commit any leftover audio. Awaited so stop/finish don't race ahead.
    func flushEarly() async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            queue.async { [weak self] in
                defer { cont.resume() }
                guard let self, !self.closed else { return }
                // Always keep the trailing buffer — skipping it cuts off last words.
                guard !self.pending16k.isEmpty else { return }
                self.commitPending(force: true, reason: "early-stop", keepOverlap: false)
            }
        }
    }

    /// Currently joined transcript without waiting for in-flight Deepgram.
    func snapshot() -> (text: String, chunkCount: Int, confidence: Double?) {
        queue.sync { self.joinedState() }
    }

    /// Close recording and return joined text. Waits for trailing Deepgram RTTs.
    /// `timedOut` is true if we had to return before every chunk finished — caller
    /// should prefer a full-file fallback so the last sentence isn't dropped.
    func finish(maxWaitSeconds: TimeInterval = Constants.Audio.liveFinishWaitSeconds) async -> (text: String, chunkCount: Int, confidence: Double?, timedOut: Bool) {
        // Mark closed + always commit leftover audio (even short tails).
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            queue.async { [weak self] in
                guard let self else {
                    cont.resume()
                    return
                }
                self.closed = true
                if !self.pending16k.isEmpty {
                    self.commitPending(force: true, reason: "final", keepOverlap: false)
                }
                cont.resume()
            }
        }

        var timedOut = false
        let inflightAtStop: Int = queue.sync { self.inflight }
        if inflightAtStop > 0, maxWaitSeconds > 0 {
            await withTaskGroup(of: String.self) { group in
                group.addTask { [weak self] in
                    await self?.waitUntilIdle()
                    return "idle"
                }
                group.addTask {
                    try? await Task.sleep(nanoseconds: UInt64(maxWaitSeconds * 1_000_000_000))
                    return "deadline"
                }
                let winner = await group.next() ?? "idle"
                group.cancelAll()
                if winner == "deadline" {
                    timedOut = true
                    // Don't wake finishWaiters early — let late chunks still land in
                    // chunkTextsByIndex if they finish before we read joinedState.
                    // Give a brief grace so an almost-done RTT can land.
                    try? await Task.sleep(nanoseconds: 400_000_000)
                    DiagnosticLog.write(
                        String(format: "live finish deadline %.2fs inflight≈%d — may need full-file fallback", maxWaitSeconds, inflightAtStop)
                    )
                }
            }
        } else if inflightAtStop > 0 {
            await waitUntilIdle()
        }

        let state = queue.sync { self.joinedState() }
        // Missing chunk slots mean the last phrase never came back from Deepgram.
        let missingSlots = queue.sync { () -> Bool in
            guard self.chunksCommitted > 0 else { return false }
            return (1...self.chunksCommitted).contains { self.chunkTextsByIndex[$0] == nil }
        }
        return (state.text, state.chunkCount, state.confidence, timedOut || missingSlots)
    }

    private func waitUntilIdle() async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            queue.async { [weak self] in
                guard let self else {
                    cont.resume()
                    return
                }
                if self.inflight == 0 {
                    cont.resume()
                } else {
                    self.finishWaiters.append(cont)
                }
            }
        }
    }

    private func joinedState() -> (text: String, chunkCount: Int, confidence: Double?) {
        guard chunksCommitted > 0 else {
            return ("", 0, nil)
        }
        let pieces = (1...chunksCommitted)
            .compactMap { chunkTextsByIndex[$0] }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { Self.isUsableChunk($0) }
        let confidences = (1...chunksCommitted).compactMap { chunkConfidenceByIndex[$0] }
        let avg: Double? = confidences.isEmpty
            ? nil
            : confidences.reduce(0, +) / Double(confidences.count)
        return (Self.joinDedupingBoundaries(pieces), chunksCommitted, avg)
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
            var confidence: Double?
            do {
                let result = try await recognizer.transcribe(
                    samples: chunk,
                    promptContext: promptContext.isEmpty ? nil : promptContext
                )
                text = result.text
                confidence = result.confidence
            } catch {
                AppLogger.speech.error(
                    "Live ASR chunk #\(index) failed: \(error.localizedDescription, privacy: .public)"
                )
                text = ""
            }
            self.queue.async {
                self.chunkTextsByIndex[index] = text
                if let confidence {
                    self.chunkConfidenceByIndex[index] = confidence
                }
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
