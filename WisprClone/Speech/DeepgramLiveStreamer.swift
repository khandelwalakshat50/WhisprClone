import AVFoundation
import Foundation

/// Continuous Deepgram Nova live WebSocket transcription while the mic is open.
///
/// Safer / faster than HTTP chunk POSTs:
/// - one socket for the whole utterance
/// - on stop: Finalize → trailing finals in ~hundreds of ms
/// - full-file / HTTP-chunk remain as coordinator fallbacks if connect fails
final class DeepgramLiveStreamer: @unchecked Sendable {
    /// Fired when a finalized phrase segment is ready (progressive LLM hook).
    var onUsableChunk: (@Sendable (Int, String) -> Void)?

    private let apiKey: String
    private let model: String
    private let vocabularyBias: String

    private let queue = DispatchQueue(label: "\(Constants.bundleIdentifier).dgstream", qos: .userInitiated)
    private let session: URLSession
    private var task: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?
    private var keepAliveTimer: DispatchSourceTimer?

    private var converter: AVAudioConverter?
    private var converterInputFormat: AVAudioFormat?
    private var pending16k: [Float] = []
    /// Whole session at 16 kHz — HTTP fallback uploads this (~6× smaller than the 48 kHz float WAV).
    private var retained16k: [Float] = []
    private var retainedOverflow = false

    private var finalPieces: [String] = []
    private var latestInterim = ""
    private var segmentIndex = 0
    private var confidenceSum: Double = 0
    private var confidenceCount = 0

    private var ingestClosed = false
    private var finishSignaled = false
    private var sawFromFinalize = false
    private var socketFailed = false
    private var connected = false
    private var connectTask: Task<Void, Error>?

    private var finishWaiters: [CheckedContinuation<Void, Never>] = []
    private var finalizeSettleWorkItem: DispatchWorkItem?

    private let targetFormat = AVAudioFormat(
        standardFormatWithSampleRate: Constants.Audio.whisperSampleRate,
        channels: 1
    )!

    /// Accumulate ~40 ms before sending to avoid tiny frames.
    private let sendEverySamples = Int(Constants.Audio.whisperSampleRate * 0.04)
    /// Keep mic audio while the socket is still opening (covers a slow first attempt + retry).
    private let maxPreconnectSamples = Int(Constants.Audio.whisperSampleRate * 30)
    private let maxRetainedSamples = Int(Constants.Audio.whisperSampleRate * Constants.Speech.maxRetainedFallbackSeconds)

    init(apiKey: String, model: String, vocabularyBias: String = "") {
        self.apiKey = apiKey
        self.model = model
        self.vocabularyBias = vocabularyBias
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 60
        config.waitsForConnectivity = false
        self.session = URLSession(configuration: config)
    }

    /// Open the live socket. Safe to call after `ingest` has already started —
    /// early mic audio is buffered and flushed once the socket is ready.
    func connect(timeoutSeconds: TimeInterval = Constants.Speech.liveConnectTimeoutSeconds) async throws {
        guard !apiKey.isEmpty else {
            throw AppError.notConfigured("Deepgram API Key Missing")
        }
        guard let url = Self.listenURL(model: model, vocabularyBias: vocabularyBias) else {
            throw AppError.transcriptionFailed("Invalid Deepgram stream URL")
        }

        var request = URLRequest(url: url)
        request.setValue("Token \(apiKey)", forHTTPHeaderField: "Authorization")

        let ws = session.webSocketTask(with: request)
        queue.sync {
            self.task = ws
            self.ingestClosed = false
            self.finishSignaled = false
            self.sawFromFinalize = false
            self.socketFailed = false
            self.connected = false
            self.finalPieces.removeAll()
            self.latestInterim = ""
            self.segmentIndex = 0
            self.confidenceSum = 0
            self.confidenceCount = 0
            // Keep pending16k — may already hold leading speech from the mic.
        }
        ws.resume()

        receiveTask = Task { [weak self] in
            await self?.receiveLoop(ws: ws)
        }

        // Confirm the socket accepts traffic (auth failures close immediately).
        try await waitUntilReady(ws: ws, timeoutSeconds: timeoutSeconds)
        queue.sync {
            self.connected = true
            self.startKeepAliveLocked()
            // Push any audio captured while the handshake was in flight.
            self.flushPendingLocked(force: true)
        }
        DiagnosticLog.write("deepgram live stream connected model=\(DeepgramRequestSupport.sanitizedModel(model))")
        AppLogger.speech.info("Deepgram live stream connected")
    }

    /// Start connecting without blocking the mic. Retries once while the user is still speaking.
    func beginConnect(timeoutSeconds: TimeInterval = Constants.Speech.liveConnectTimeoutSeconds) {
        let existing = queue.sync { self.connectTask }
        if existing != nil { return }
        let task = Task { [weak self] in
            guard let self else { return }
            let started = ContinuousClock.now
            do {
                try await self.connect(timeoutSeconds: timeoutSeconds)
            } catch {
                let stillRecording = self.queue.sync { !self.ingestClosed }
                guard !Task.isCancelled, stillRecording else { throw error }
                DiagnosticLog.write(
                    String(
                        format: "deepgram live connect attempt 1 failed after %.2fs (%@); retrying",
                        AppLogger.elapsedMilliseconds(since: started) / 1000,
                        error.localizedDescription
                    )
                )
                self.dropSocketForRetry()
                try await self.connect(timeoutSeconds: timeoutSeconds)
            }
            DiagnosticLog.write(
                String(format: "deepgram live connect took %.2fs", AppLogger.elapsedMilliseconds(since: started) / 1000)
            )
        }
        queue.sync { self.connectTask = task }
    }

    /// Waits for the background connect. With `maxWaitSeconds`, gives up early so a dead
    /// socket can't hold the paste hostage — the caller falls back to HTTP.
    @discardableResult
    func awaitConnection(maxWaitSeconds: TimeInterval? = nil) async -> Bool {
        enum Outcome: Sendable {
            case connected
            case failed(String)
            case stillPending
        }
        let task = queue.sync { self.connectTask }
        if let task {
            let outcome: Outcome = await withTaskGroup(of: Outcome.self) { group in
                group.addTask {
                    do {
                        try await task.value
                        return .connected
                    } catch {
                        return .failed(error.localizedDescription)
                    }
                }
                if let maxWaitSeconds {
                    group.addTask {
                        try? await Task.sleep(nanoseconds: UInt64(maxWaitSeconds * 1_000_000_000))
                        return .stillPending
                    }
                }
                let first = await group.next() ?? .stillPending
                group.cancelAll()
                return first
            }
            switch outcome {
            case .connected:
                break
            case .failed(let reason):
                DiagnosticLog.write("deepgram live connect failed: \(reason)")
                return false
            case .stillPending:
                DiagnosticLog.write("deepgram live connect still pending at stop — using HTTP")
                return false
            }
        }
        return queue.sync { self.connected && !self.socketFailed }
    }

    /// 16 kHz mono samples for the whole session, or nil if the session outgrew the buffer.
    func retainedSamples16k() -> [Float]? {
        queue.sync { retainedOverflow || retained16k.isEmpty ? nil : retained16k }
    }

    private func dropSocketForRetry() {
        receiveTask?.cancel()
        receiveTask = nil
        queue.sync {
            self.stopKeepAliveLocked()
            self.task?.cancel(with: .goingAway, reason: nil)
            self.task = nil
            self.connected = false
        }
    }

    func ingest(_ buffer: AVAudioPCMBuffer) {
        guard let copy = Self.copyBuffer(buffer) else { return }
        queue.async { [weak self] in
            self?.appendAndSend(copy)
        }
    }

    /// No-op — streaming doesn't use silence-based HTTP commits.
    func commitOnSilence() {}

    /// Drain pending PCM onto the socket before mic teardown.
    func flushEarly() async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            queue.async { [weak self] in
                defer { cont.resume() }
                guard let self, !self.ingestClosed else { return }
                self.flushPendingLocked(force: true)
            }
        }
    }

    /// Stop ingest, Finalize, wait briefly for trailing finals, CloseStream.
    func finish(
        maxWaitSeconds: TimeInterval = Constants.Audio.liveStreamFinishWaitSeconds
    ) async -> (text: String, chunkCount: Int, confidence: Double?, timedOut: Bool) {
        // Socket never opened: don't wait out the retry — HTTP fallback is faster.
        guard await awaitConnection(maxWaitSeconds: Constants.Speech.liveConnectGraceAtStopSeconds) else {
            cancel()
            return ("", 0, nil, true)
        }

        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            queue.async { [weak self] in
                guard let self else {
                    cont.resume()
                    return
                }
                self.ingestClosed = true
                self.flushPendingLocked(force: true)
                self.sendJSONLocked(["type": "Finalize"])
                self.finishSignaled = true
                // If speech already finalized before stop, don't wait the full deadline.
                if !self.finalPieces.isEmpty {
                    self.scheduleFinalizeSettleLocked()
                }
                cont.resume()
            }
        }

        var timedOut = false
        if !queue.sync(execute: { self.sawFromFinalize || self.socketFailed }) {
            timedOut = await waitForFinalizeOrDeadline(maxWaitSeconds: maxWaitSeconds)
        }

        queue.sync {
            self.sendJSONLocked(["type": "CloseStream"])
            self.stopKeepAliveLocked()
        }

        // Brief settle for last Results after CloseStream.
        try? await Task.sleep(nanoseconds: 150_000_000)

        receiveTask?.cancel()
        queue.sync {
            self.task?.cancel(with: .goingAway, reason: nil)
            self.task = nil
        }

        let state = queue.sync { self.joinedState() }
        let failed = queue.sync { self.socketFailed || !self.connected }
        if failed && state.text.isEmpty {
            return ("", 0, nil, true)
        }
        DiagnosticLog.write(
            "deepgram live finish chars=\(state.text.count) segments=\(state.chunkCount) timedOut=\(timedOut || failed)"
        )
        return (state.text, state.chunkCount, state.confidence, timedOut || failed)
    }

    func cancel() {
        receiveTask?.cancel()
        queue.sync {
            self.connectTask?.cancel()
            self.connectTask = nil
            self.ingestClosed = true
            self.stopKeepAliveLocked()
            self.task?.cancel(with: .goingAway, reason: nil)
            self.task = nil
            let waiters = self.finishWaiters
            self.finishWaiters.removeAll()
            waiters.forEach { $0.resume() }
        }
    }

    // MARK: - Private

    private func waitUntilReady(ws: URLSessionWebSocketTask, timeoutSeconds: TimeInterval) async throws {
        // Tiny silent frame proves the socket accepts binary.
        let silence = Data(count: Int(Constants.Audio.whisperSampleRate * 0.02) * 2) // 20 ms linear16
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                try await ws.send(.data(silence))
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeoutSeconds * 1_000_000_000))
                throw AppError.transcriptionFailed("Deepgram live connect timed out")
            }
            do {
                try await group.next()
                group.cancelAll()
            } catch {
                group.cancelAll()
                if self.queue.sync(execute: { self.socketFailed }) {
                    throw AppError.transcriptionFailed("Deepgram live stream failed to open")
                }
                throw error
            }
        }
        if queue.sync(execute: { self.socketFailed }) {
            throw AppError.transcriptionFailed("Deepgram live stream rejected")
        }
    }

    private func waitForFinalizeOrDeadline(maxWaitSeconds: TimeInterval) async -> Bool {
        await withTaskGroup(of: String.self) { group in
            group.addTask { [weak self] in
                await self?.waitUntilFinalizeSignal()
                return "done"
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(maxWaitSeconds * 1_000_000_000))
                return "deadline"
            }
            let winner = await group.next() ?? "done"
            group.cancelAll()
            return winner == "deadline"
        }
    }

    private func waitUntilFinalizeSignal() async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            queue.async { [weak self] in
                guard let self else {
                    cont.resume()
                    return
                }
                if self.sawFromFinalize || self.socketFailed {
                    cont.resume()
                } else {
                    self.finishWaiters.append(cont)
                }
            }
        }
    }

    private func receiveLoop(ws: URLSessionWebSocketTask) async {
        while !Task.isCancelled {
            // A retry replaces the socket; the abandoned one must not flag the new stream as failed.
            guard queue.sync(execute: { self.task === ws }) else { break }
            do {
                let message = try await ws.receive()
                handle(message: message)
            } catch {
                queue.async { [weak self] in
                    guard let self, self.task === ws else { return }
                    if !self.ingestClosed || !self.finishSignaled {
                        self.socketFailed = true
                        DiagnosticLog.write("deepgram live receive error: \(error.localizedDescription)")
                    }
                    self.resumeFinishWaitersLocked()
                }
                break
            }
        }
    }

    private func handle(message: URLSessionWebSocketTask.Message) {
        let data: Data?
        switch message {
        case .string(let text):
            data = text.data(using: .utf8)
        case .data(let d):
            data = d
        @unknown default:
            data = nil
        }
        guard let data,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["type"] as? String
        else { return }

        queue.async { [weak self] in
            self?.handleJSONLocked(type: type, json: json)
        }
    }

    private func handleJSONLocked(type: String, json: [String: Any]) {
        switch type {
        case "Results":
            let isFinal = json["is_final"] as? Bool ?? false
            let fromFinalize = json["from_finalize"] as? Bool ?? false
            guard
                let channel = json["channel"] as? [String: Any],
                let alternatives = channel["alternatives"] as? [[String: Any]],
                let best = alternatives.first
            else { return }

            let transcript = (best["transcript"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if let confidence = best["confidence"] as? Double {
                confidenceSum += confidence
                confidenceCount += 1
            }

            if isFinal {
                if !transcript.isEmpty {
                    finalPieces.append(transcript)
                    latestInterim = ""
                    segmentIndex += 1
                    let index = segmentIndex
                    let text = transcript
                    onUsableChunk?(index, text)
                }
                if finishSignaled {
                    // Finalize responses aren't always tagged from_finalize — settle
                    // shortly after the last final so demos don't wait the full deadline.
                    scheduleFinalizeSettleLocked()
                }
                if fromFinalize {
                    sawFromFinalize = true
                    finalizeSettleWorkItem?.cancel()
                    resumeFinishWaitersLocked()
                }
            } else if !transcript.isEmpty {
                latestInterim = transcript
            }

            if fromFinalize {
                sawFromFinalize = true
                finalizeSettleWorkItem?.cancel()
                resumeFinishWaitersLocked()
            }

        case "UtteranceEnd":
            // Phrase boundary — useful signal after stop as well.
            if finishSignaled {
                scheduleFinalizeSettleLocked()
            }

        case "Error":
            socketFailed = true
            let message = json["message"] as? String ?? "unknown"
            DiagnosticLog.write("deepgram live error: \(message)")
            resumeFinishWaitersLocked()

        case "Metadata":
            break

        default:
            break
        }
    }

    private func scheduleFinalizeSettleLocked() {
        finalizeSettleWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.sawFromFinalize = true
            self.resumeFinishWaitersLocked()
        }
        finalizeSettleWorkItem = work
        queue.asyncAfter(deadline: .now() + 0.28, execute: work)
    }

    private func resumeFinishWaitersLocked() {
        let waiters = finishWaiters
        finishWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    private func joinedState() -> (text: String, chunkCount: Int, confidence: Double?) {
        var text = finalPieces
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        let interim = latestInterim.trimmingCharacters(in: .whitespacesAndNewlines)
        if !interim.isEmpty {
            // After Finalize, include trailing interim only if not already covered.
            if text.isEmpty {
                text = interim
            } else if !text.lowercased().hasSuffix(interim.lowercased()) {
                text = text + " " + interim
            }
        }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let avg: Double? = confidenceCount > 0 ? confidenceSum / Double(confidenceCount) : nil
        return (text, finalPieces.count, avg)
    }

    private func appendAndSend(_ buffer: AVAudioPCMBuffer) {
        guard !ingestClosed else { return }
        guard let samples = convertTo16kMono(buffer), !samples.isEmpty else { return }
        if !retainedOverflow {
            if retained16k.count + samples.count > maxRetainedSamples {
                retainedOverflow = true
                retained16k.removeAll()
            } else {
                retained16k.append(contentsOf: samples)
            }
        }
        guard !socketFailed else { return }
        pending16k.append(contentsOf: samples)
        if !connected {
            // Mic is already open while TLS/WebSocket handshake finishes —
            // keep leading speech so the first words aren't lost.
            if pending16k.count > maxPreconnectSamples {
                let overflow = pending16k.count - maxPreconnectSamples
                pending16k.removeFirst(overflow)
            }
            return
        }
        guard task != nil else { return }
        if pending16k.count >= sendEverySamples {
            flushPendingLocked(force: false)
        }
    }

    private func flushPendingLocked(force: Bool) {
        guard connected, task != nil, !pending16k.isEmpty else { return }
        if !force && pending16k.count < sendEverySamples { return }
        let chunk = pending16k
        pending16k.removeAll(keepingCapacity: true)
        let pcm = Self.floatToLinear16(chunk)
        sendDataLocked(pcm)
    }

    private func sendDataLocked(_ data: Data) {
        guard let task, !data.isEmpty else { return }
        task.send(.data(data)) { [weak self] error in
            if let error {
                self?.queue.async {
                    self?.socketFailed = true
                    DiagnosticLog.write("deepgram live send error: \(error.localizedDescription)")
                    self?.resumeFinishWaitersLocked()
                }
            }
        }
    }

    private func sendJSONLocked(_ object: [String: Any]) {
        guard let task,
              let data = try? JSONSerialization.data(withJSONObject: object),
              let text = String(data: data, encoding: .utf8)
        else { return }
        task.send(.string(text)) { [weak self] error in
            if let error {
                self?.queue.async {
                    DiagnosticLog.write("deepgram live control error: \(error.localizedDescription)")
                    self?.socketFailed = true
                    self?.resumeFinishWaitersLocked()
                }
            }
        }
    }

    private func startKeepAliveLocked() {
        stopKeepAliveLocked()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 5, repeating: 5)
        timer.setEventHandler { [weak self] in
            guard let self, !self.ingestClosed, !self.socketFailed else { return }
            self.sendJSONLocked(["type": "KeepAlive"])
        }
        timer.resume()
        keepAliveTimer = timer
    }

    private func stopKeepAliveLocked() {
        keepAliveTimer?.cancel()
        keepAliveTimer = nil
    }

    private static func listenURL(model: String, vocabularyBias: String) -> URL? {
        var components = URLComponents(string: "wss://api.deepgram.com/v1/listen")!
        let model = DeepgramRequestSupport.sanitizedModel(model)
        var items: [URLQueryItem] = [
            URLQueryItem(name: "model", value: model),
            URLQueryItem(name: "encoding", value: "linear16"),
            URLQueryItem(name: "sample_rate", value: "16000"),
            URLQueryItem(name: "channels", value: "1"),
            URLQueryItem(name: "smart_format", value: "true"),
            URLQueryItem(name: "punctuate", value: "true"),
            URLQueryItem(name: "interim_results", value: "true"),
            URLQueryItem(name: "endpointing", value: "300"),
            URLQueryItem(name: "utterance_end_ms", value: "1000"),
            URLQueryItem(name: "vad_events", value: "true")
        ]
        for term in DeepgramRequestSupport.keyterms(from: vocabularyBias, model: model) {
            items.append(URLQueryItem(name: "keyterm", value: term))
        }
        components.queryItems = items
        return components.url
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

    private static func floatToLinear16(_ samples: [Float]) -> Data {
        var data = Data(capacity: samples.count * 2)
        for sample in samples {
            let clamped = max(-1.0, min(1.0, sample))
            var value = Int16((clamped * Float(Int16.max)).rounded())
            withUnsafeBytes(of: &value) { data.append(contentsOf: $0) }
        }
        return data
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
