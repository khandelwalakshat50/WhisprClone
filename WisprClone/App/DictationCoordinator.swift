import Foundation
import AppKit

/// End-to-end dictation pipeline: hotkey → manual recording → transcribe → format → inject.
@MainActor
final class DictationCoordinator {
    private let recordingState: RecordingStateStore
    private let configurationStore: ConfigurationStore
    private let permissions: PermissionManager
    private let usageStore: LLMUsageStore
    private let historyStore: TranscriptHistoryStore
    private let overlayPresentation: OverlayPresentationModel

    private let recorder = AudioRecorder()
    private let injector = TextInjector()

    private var hotkeys: GlobalHotkeyManager?
    private var activeTask: Task<Void, Never>?
    private var vad: VoiceActivityDetector?
    private var recordingStopContinuation: CheckedContinuation<Void, Never>?
    private var recordingStopRequested = false
    private var speechStartedAt: ContinuousClock.Instant?
    /// When the current dictation session UI started (for ignoring bogus immediate stops).
    private var sessionBeganAt: ContinuousClock.Instant?
    /// App that had focus when dictation started — paste must land there, not in WisprClone.
    private var pasteTargetApp: NSRunningApplication?
    /// Prefetched at session start (local only): Gmail-in-Chrome, session key, profile.
    private var writingContext: FrontmostWritingContext?
    /// Prefetched vocabulary hint for this session (tiny; no prior prose to LLM).
    private var prefetchedVocabularyHint: String?
    /// Progressive Whisper while listening (WhisperKit path only).
    private var liveTranscriber: LiveChunkTranscriber?
    /// Preferred Deepgram path — continuous WebSocket (falls back to HTTP chunks).
    private var liveStreamer: DeepgramLiveStreamer?
    /// Formats each live ASR chunk as it arrives (overlaps LLM with speech).
    private var progressiveFormatter: ProgressiveLLMFormatter?

    /// Cached so the WhisperKit model stays loaded across sessions.
    private var cachedWhisperRecognizer: WhisperKitRecognizer?
    private var cachedWhisperModelName: String?
    private var cachedWhisperVocabularyBias: String?

    init(
        recordingState: RecordingStateStore,
        configurationStore: ConfigurationStore,
        permissions: PermissionManager,
        usageStore: LLMUsageStore,
        historyStore: TranscriptHistoryStore,
        overlayPresentation: OverlayPresentationModel
    ) {
        self.recordingState = recordingState
        self.configurationStore = configurationStore
        self.permissions = permissions
        self.usageStore = usageStore
        self.historyStore = historyStore
        self.overlayPresentation = overlayPresentation
    }

    func start() {
        permissions.requestAccessibility()
        permissions.requestInputMonitoring()
        installHotkeys()

        // Warm up WhisperKit model load only — do NOT run a silence decode here.
        // A warm decode holds the inference gate and delays the first real
        // transcription (and can race the mic while the user is already speaking).
        if configurationStore.configuration.speechEngine == .whisperKit {
            let recognizer = whisperRecognizer(for: configurationStore.configuration.whisperModel)
            Task.detached(priority: .utility) {
                await recognizer.preload()
            }
        }

        AppLogger.pipeline.info("Dictation coordinator started")
    }

    private func whisperRecognizer(for modelName: String) -> WhisperKitRecognizer {
        let bias = configurationStore.configuration.whisperVocabularyBias
        if let cachedWhisperRecognizer,
           cachedWhisperModelName == modelName,
           cachedWhisperVocabularyBias == bias {
            return cachedWhisperRecognizer
        }
        let recognizer = WhisperKitRecognizer(modelName: modelName, vocabularyBias: bias)
        cachedWhisperRecognizer = recognizer
        cachedWhisperModelName = modelName
        cachedWhisperVocabularyBias = bias
        return recognizer
    }

    private func fullFileRecognizer(for config: Configuration) throws -> any SpeechRecognizing {
        let bias = PersonalDictionaryStore.shared
            .allTerms(includingConfiguredBias: config.whisperVocabularyBias)
            .joined(separator: ", ")
        switch config.speechEngine {
        case .deepgram:
            guard let key = configurationStore.resolvedDeepgramKey(), !key.isEmpty else {
                throw AppError.notConfigured("Deepgram API Key Missing — add DEEPGRAM_API_KEY to .env")
            }
            return DeepgramRecognizer(
                apiKey: key,
                model: DeepgramRequestSupport.sanitizedModel(config.deepgramModel),
                vocabularyBias: bias
            )
        case .whisperKit:
            return whisperRecognizer(for: config.whisperModel)
        case .appleSpeech:
            return AppleSpeechRecognizer()
        }
    }

    /// Menu-bar “Start Dictation” entry point (works even when hotkeys are blocked).
    func triggerFromMenu() {
        handleHotkey(.toggle)
    }

    func stop() {
        cancelActiveSession(resetState: false)
        hotkeys?.stop()
        hotkeys = nil
        AppLogger.pipeline.info("Dictation coordinator stopped")
    }

    /// Re-installs the event tap after Input Monitoring is granted.
    func refreshHotkeys() {
        hotkeys?.stop()
        hotkeys = nil
        installHotkeys()
        AppLogger.hotkeys.info("Hotkey tap refreshed")
    }

    // MARK: - Hotkey

    private func installHotkeys() {
        let manager = GlobalHotkeyManager { [weak self] action in
            Task { @MainActor in
                self?.handleHotkey(action)
            }
        }
        manager.start()
        hotkeys = manager
    }

    private func handleHotkey(_ action: GlobalHotkeyManager.Action) {
        DiagnosticLog.write("hotkey action=\(action) state=\(recordingState.state)")
        switch (action, recordingState.state) {
        case (.begin, .idle), (.begin, .success), (.begin, .failure),
             (.toggle, .idle), (.toggle, .success), (.toggle, .failure):
            beginSession()
        case (.stop, .listening), (.stop, .detectingSpeech),
             (.toggle, .listening), (.toggle, .detectingSpeech):
            // Ignore a stop that races in immediately after double-fn begin.
            if let sessionBeganAt,
               AppLogger.elapsedMilliseconds(since: sessionBeganAt) < 650 {
                DiagnosticLog.write("hotkey stop ignored (too soon after begin)")
                return
            }
            requestRecordingStop()
        // Escape hatch when an LLM call hangs on "Refining".
        case (.stop, .formatting), (.stop, .transcribing), (.stop, .injecting),
             (.toggle, .formatting), (.toggle, .transcribing), (.toggle, .injecting):
            DiagnosticLog.write("cancel stuck session from \(recordingState.state)")
            cancelActiveSession(resetState: true)
        case (.begin, .formatting), (.begin, .transcribing), (.begin, .injecting):
            // Don't abort an in-flight refine with a mistaken double-fn —
            // ignore begin until idle/success/failure.
            DiagnosticLog.write("hotkey begin ignored during \(recordingState.state)")
        default:
            DiagnosticLog.write("hotkey ignored for current state")
            break
        }
    }

    private func beginSession() {
        cancelActiveSession(resetState: false)
        recordingStopRequested = false
        sessionBeganAt = .now
        // Remember the user's focused app *before* we do anything that might
        // touch activation — ⌘V must land there, not in Preferences/overlay.
        pasteTargetApp = Self.frontmostAppExcludingSelf()
        // Local-only prefetch (no API tokens): window title → Gmail/Slack/etc + slim vocabulary.
        let resolved = FrontmostWritingContextResolver.resolve(for: pasteTargetApp)
        writingContext = resolved
        let summary = ContextSessionStore.shared.prefetch(sessionKey: resolved.sessionKey)
        prefetchedVocabularyHint = summary.llmVocabularyHint
        DiagnosticLog.write(
            "paste target=\(pasteTargetApp?.localizedName ?? "none") pid=\(pasteTargetApp?.processIdentifier ?? -1) site=\(resolved.profile.id) session=\(resolved.sessionKey) title=\(resolved.windowTitle ?? "-")"
        )

        // Bounce idle → listening so observers always fire even if we were
        // already stuck in `.listening` with a hidden panel.
        recordingState.update(.idle)
        recordingState.update(.listening)
        DiagnosticLog.write("beginSession → overlay listening")

        activeTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.runSession()
            } catch is CancellationError {
                DiagnosticLog.write("session cancelled")
                self.recordingState.update(.idle)
            } catch let error as AppError where error == .cancelled {
                DiagnosticLog.write("session cancelled (AppError)")
                self.recordingState.update(.idle)
            } catch {
                // Task cancellation sometimes bridges as a generic Error.
                if Task.isCancelled || Self.isCancellation(error) {
                    DiagnosticLog.write("session cancelled (bridged)")
                    self.recordingState.update(.idle)
                    return
                }
                AppLogger.pipeline.error("Session failed: \(error.localizedDescription, privacy: .public)")
                DiagnosticLog.write("session failed: \(error.localizedDescription)")
                _ = self.recorder.stop()
                if let app = error as? AppError {
                    self.recordingState.update(.failure(app.localizedDescription))
                } else {
                    self.recordingState.update(.failure(error.localizedDescription))
                }
            }
        }
    }

    private static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        let ns = error as NSError
        if ns.domain == NSURLErrorDomain && ns.code == NSURLErrorCancelled { return true }
        let message = error.localizedDescription.lowercased()
        return message.contains("cancellationerror") || message.contains("cancelled")
    }

    private static func frontmostAppExcludingSelf() -> NSRunningApplication? {
        let front = NSWorkspace.shared.frontmostApplication
        guard let front, front.bundleIdentifier != Bundle.main.bundleIdentifier else {
            return nil
        }
        return front
    }

    /// Give keyboard focus back to the app the user was typing in.
    private func restorePasteTargetFocus() async {
        // Drop key status from any of our windows (Preferences, etc.) without
        // activating ourselves again.
        for window in NSApp.windows where window.isVisible {
            window.resignKey()
            window.resignMain()
        }

        guard let target = pasteTargetApp, !target.isTerminated else {
            DiagnosticLog.write("restore focus skipped — no paste target")
            return
        }
        let ok = target.activate(options: [.activateIgnoringOtherApps])
        DiagnosticLog.write("restored focus → \(target.localizedName ?? "?") ok=\(ok)")
        // Brief settle so the caret is live before we synthesize ⌘V.
        try? await Task.sleep(nanoseconds: Constants.Injection.focusSettleNanoseconds)
    }

    private func cancelActiveSession(resetState: Bool) {
        activeTask?.cancel()
        activeTask = nil
        requestRecordingStop()
        _ = recorder.stop()
        vad = nil
        liveStreamer?.cancel()
        liveStreamer = nil
        liveTranscriber = nil
        progressiveFormatter = nil
        writingContext = nil
        prefetchedVocabularyHint = nil
        sessionBeganAt = nil
        overlayPresentation.resetAudioLevel()
        speechStartedAt = nil
        if resetState {
            recordingState.update(.idle)
        }
    }

    private func runSession() async throws {
        let sessionStart = ContinuousClock.now
        AppLogger.pipeline.info("Dictation session begin")
        DiagnosticLog.write("runSession start")

        // Do NOT activate WisprClone here — that steals the text caret from the
        // app the user is dictating into. Only come forward if we must show a
        // first-time microphone TCC prompt.
        if permissions.status(for: .microphone) == .notDetermined {
            NSApp.activate(ignoringOtherApps: true)
        }

        let mic = await permissions.requestMicrophone()
        DiagnosticLog.write("microphone status=\(mic)")
        guard mic == .granted else { throw AppError.microphonePermissionDenied }

        if configurationStore.configuration.speechEngine == .appleSpeech {
            let speech = await permissions.requestSpeechRecognition()
            guard speech == .granted else { throw AppError.speechPermissionDenied }
        }

        // Ensure listening state (may already be set in beginSession).
        if recordingState.state != .listening && recordingState.state != .detectingSpeech {
            recordingState.update(.listening)
        }

        let config = configurationStore.configuration
        let biasTerms = PersonalDictionaryStore.shared.allTerms(
            includingConfiguredBias: config.whisperVocabularyBias
        )
        let bias = biasTerms.joined(separator: ", ")

        liveStreamer = nil
        liveTranscriber = nil

        // Deepgram: create streamer immediately; connect in the background AFTER
        // the mic starts so the user can speak during the TLS handshake.
        // WhisperKit: HTTP/local chunk path. Apple Speech: full-file only.
        switch config.speechEngine {
        case .deepgram:
            guard let key = configurationStore.resolvedDeepgramKey(), !key.isEmpty else {
                throw AppError.notConfigured("Deepgram API Key Missing — add DEEPGRAM_API_KEY to .env")
            }
            let streamer = DeepgramLiveStreamer(
                apiKey: key,
                model: DeepgramRequestSupport.sanitizedModel(config.deepgramModel),
                vocabularyBias: bias
            )
            liveStreamer = streamer
        case .whisperKit:
            liveTranscriber = LiveChunkTranscriber(
                recognizer: whisperRecognizer(for: config.whisperModel)
            )
        case .appleSpeech:
            break
        }

        // Start LLM work on each ASR chunk while the user is still speaking.
        // Full-transcript formatting remains the fallback if this doesn't cover.
        let earlyFormatter = makeFormattingService(
            config: config,
            utteranceDurationSeconds: 0
        )
        let progressiveBase = FormattingRequest(
            text: "",
            utteranceDurationSeconds: 0,
            asrConfidence: nil,
            targetBundleID: writingContext?.bundleID ?? pasteTargetApp?.bundleIdentifier,
            targetAppName: writingContext?.displayLabel ?? pasteTargetApp?.localizedName,
            targetWindowTitle: writingContext?.windowTitle,
            siteHint: writingContext.map {
                FrontmostWritingContextResolver.detectSite(
                    windowTitle: $0.windowTitle,
                    bundleID: $0.bundleID,
                    appName: $0.appName
                )
            } ?? nil,
            sessionSummary: prefetchedVocabularyHint,
            personalTerms: Array(biasTerms.prefix(12))
        )
        let progressive = ProgressiveLLMFormatter(formatter: earlyFormatter, baseRequest: progressiveBase)
        progressiveFormatter = progressive
        let onChunk: @Sendable (Int, String) -> Void = { [weak progressive] index, text in
            progressive?.ingest(index: index, text: text)
        }
        liveStreamer?.onUsableChunk = onChunk
        liveTranscriber?.onUsableChunk = onChunk

        let detector = VoiceActivityDetector(
            onLevel: { [weak overlayPresentation] rms in
                // Prefer DispatchQueue over Task — lower latency for waveform updates.
                DispatchQueue.main.async {
                    overlayPresentation?.updateAudioLevel(rms: rms)
                }
            },
            onEvent: { [weak self] event in
                Task { @MainActor in
                    self?.handleVAD(event)
                }
            }
        )
        vad = detector
        detector.reset()

        try Task.checkCancellation()

        // Start mic FIRST — leading speech must not wait on Deepgram connect.
        speechStartedAt = ContinuousClock.now
        let url: URL
        do {
            let streamer = liveStreamer
            let live = liveTranscriber
            url = try recorder.start { [weak detector, streamer, live] buffer, _ in
                detector?.process(buffer: buffer)
                if let streamer {
                    streamer.ingest(buffer)
                } else {
                    live?.ingest(buffer)
                }
            }
            DiagnosticLog.write(
                "recorder started liveASR=\(streamer != nil || live != nil) stream=\(streamer != nil) engine=\(config.speechEngine.rawValue)"
            )
        } catch {
            DiagnosticLog.write("recorder start failed: \(error.localizedDescription)")
            throw AppError.microphoneUnavailable
        }

        // Connect WebSocket while the mic is already capturing (audio buffers until ready).
        if let streamer = liveStreamer {
            streamer.beginConnect()
            DiagnosticLog.write("live ASR mode=websocket (connecting in background)")
        }

        await waitForManualStopOrTimeout(seconds: Constants.Audio.maxListenSeconds)
        try Task.checkCancellation()

        // Keep capturing briefly so the last spoken words aren't cut off when
        // the user hits stop mid-phrase. Streaming needs less — Finalize flushes.
        let postRoll = liveStreamer != nil
            ? Constants.Audio.postRollStreamingNanoseconds
            : Constants.Audio.postRollNanoseconds
        try? await Task.sleep(nanoseconds: postRoll)
        if let streamer = liveStreamer {
            await streamer.flushEarly()
        } else if let live = liveTranscriber {
            await live.flushEarly()
        }

        if let speechStartedAt {
            let listenMS = AppLogger.elapsedMilliseconds(since: speechStartedAt)
            AppLogger.audio.info("Speech capture window \(listenMS, format: .fixed(precision: 1)) ms")
        }

        guard let fileURL = recorder.stop() ?? Optional(url) else {
            throw AppError.recordingFailed("No audio file")
        }
        overlayPresentation.resetAudioLevel()

        defer {
            try? FileManager.default.removeItem(at: fileURL)
            liveStreamer?.cancel()
            liveStreamer = nil
            liveTranscriber = nil
            progressiveFormatter = nil
        }

        let processingStart = ContinuousClock.now
        var timing = TranscriptHistoryStore.TimingBreakdown()
        var delayNotes: [String] = []

        // Transcribe — prefer live stream / chunks already processed while speaking.
        recordingState.update(.transcribing)
        let transcriptionLabel = Self.transcriptionModelLabel(for: config)
        let transcriptionStart = ContinuousClock.now

        let transcript: String
        var asrConfidence: Double?
        if liveStreamer != nil || liveTranscriber != nil {
            let liveResult: (text: String, chunkCount: Int, confidence: Double?, timedOut: Bool)
            let pathLabel: String
            if let streamer = liveStreamer {
                liveResult = await streamer.finish()
                pathLabel = "Live stream"
            } else if let live = liveTranscriber {
                liveResult = await live.finish()
                pathLabel = "Live ASR"
            } else {
                liveResult = ("", 0, nil, true)
                pathLabel = "Live ASR"
            }

            let liveUsable = Self.hasMeaningfulSpeech(liveResult.text)
            // Incomplete live join → re-transcribe so the final sentence isn't dropped.
            if liveResult.timedOut || !liveUsable {
                let retained = liveStreamer?.retainedSamples16k()
                DiagnosticLog.write(
                    "\(pathLabel) incomplete timedOut=\(liveResult.timedOut) chars=\(liveResult.text.count) — fallback (\(config.speechEngine.rawValue), \(retained != nil ? "16k pcm" : "wav"))"
                )
                delayNotes.append(
                    liveUsable
                        ? "\(pathLabel) incomplete; re-checked with \(config.speechEngine.rawValue) for trailing speech"
                        : "\(pathLabel) empty; fell back to \(config.speechEngine.rawValue) upload"
                )
                let recognizer = try fullFileRecognizer(for: config)
                let fallback: @Sendable () async throws -> SpeechTranscription = {
                    if let retained, let deepgram = recognizer as? DeepgramRecognizer {
                        return try await deepgram.transcribe(samples: retained, promptContext: nil)
                    }
                    return try await recognizer.transcribe(audioURL: fileURL)
                }

                var result: SpeechTranscription?
                if liveUsable {
                    // Already have text — a slow re-check must not hold the paste hostage.
                    do {
                        result = try await Self.withDeadline(
                            Constants.Speech.fallbackMaxWaitWithLiveTextSeconds,
                            fallback
                        )
                        if result == nil {
                            DiagnosticLog.write("fallback exceeded deadline — using live text")
                        }
                    } catch {
                        DiagnosticLog.write("fallback failed (\(error.localizedDescription)) — using live text")
                    }
                } else {
                    result = try await AppLogger.measure("transcription", logger: AppLogger.speech) {
                        try await fallback()
                    }
                }

                if let result, Self.hasMeaningfulSpeech(result.text),
                   !liveUsable || result.text.count >= liveResult.text.count {
                    transcript = result.text
                    asrConfidence = result.confidence
                } else if liveUsable {
                    transcript = liveResult.text
                    asrConfidence = liveResult.confidence
                    delayNotes.append("\(pathLabel) · \(liveResult.chunkCount) segment(s)")
                } else {
                    transcript = result?.text ?? ""
                    asrConfidence = result?.confidence
                }
            } else {
                transcript = liveResult.text
                asrConfidence = liveResult.confidence
                delayNotes.append("\(pathLabel) · \(liveResult.chunkCount) segment(s)")
                DiagnosticLog.write(
                    "\(pathLabel.lowercased()) transcript segments=\(liveResult.chunkCount) chars=\(transcript.count)"
                )
            }
        } else {
            let recognizer = AppleSpeechRecognizer()
            let result = try await AppLogger.measure("transcription", logger: AppLogger.speech) {
                try await recognizer.transcribe(audioURL: fileURL)
            }
            transcript = result.text
            asrConfidence = result.confidence
        }
        timing.transcriptionSeconds = AppLogger.elapsedMilliseconds(since: transcriptionStart) / 1000

        let cleanedTranscript = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        // Silence / no speech: skip LLM and paste — dismiss quietly.
        guard Self.hasMeaningfulSpeech(cleanedTranscript) else {
            DiagnosticLog.write("empty transcript — skipping LLM and paste")
            AppLogger.pipeline.info("No speech detected; skipping format and inject")
            recordingState.update(.idle)
            return
        }

        let targetBundle = writingContext?.bundleID ?? pasteTargetApp?.bundleIdentifier
        let targetName = writingContext?.displayLabel ?? pasteTargetApp?.localizedName
        let sessionKey = writingContext?.sessionKey ?? (targetBundle ?? "unknown")
        let vocabularyHint = prefetchedVocabularyHint
            ?? ContextSessionStore.shared.summary(forSessionKey: sessionKey).llmVocabularyHint
        let personalTerms = Array(
            PersonalDictionaryStore.shared
                .allTerms(includingConfiguredBias: config.whisperVocabularyBias)
                .prefix(12)
        )

        // Format — prefer progressive LLM that already ran on live ASR chunks.
        recordingState.update(.formatting)
        let listenSeconds = speechStartedAt.map { AppLogger.elapsedMilliseconds(since: $0) / 1000 } ?? 0
        let formattingStart = ContinuousClock.now

        let siteHint = writingContext.map {
            FrontmostWritingContextResolver.detectSite(
                windowTitle: $0.windowTitle,
                bundleID: $0.bundleID,
                appName: $0.appName
            )
        } ?? nil

        var formatResult: FormatResult?
        // Prefer progressive only when it covers essentially the full ASR text.
        // A looser threshold previously pasted truncated speech (last sentence cut).
        if let progressive = progressiveFormatter, progressive.didStart,
           let progressiveResult = await progressive.finish(),
           Self.hasMeaningfulSpeech(progressiveResult.text),
           Self.progressiveCoversTranscript(
            progressive: progressiveResult.text,
            full: cleanedTranscript
           ) {
            formatResult = progressiveResult
            delayNotes.append(contentsOf: progressiveResult.notes)
            DiagnosticLog.write(
                "using progressive LLM chars=\(progressiveResult.text.count) provider=\(progressiveResult.provider.rawValue) chunks=\(progressive.startedCount)"
            )
        } else {
            let formatter = makeFormattingService(
                config: config,
                utteranceDurationSeconds: listenSeconds
            )
            let request = FormattingRequest(
                text: cleanedTranscript,
                utteranceDurationSeconds: listenSeconds,
                asrConfidence: asrConfidence,
                targetBundleID: targetBundle,
                targetAppName: targetName,
                targetWindowTitle: writingContext?.windowTitle,
                siteHint: siteHint,
                sessionSummary: vocabularyHint,
                personalTerms: personalTerms
            )
            formatResult = try await AppLogger.measure("llm.format", logger: AppLogger.llm) {
                try await formatter.formatDetailed(request)
            }
            if let notes = formatResult?.notes {
                delayNotes.append(contentsOf: notes)
            }
        }

        guard let formatResult else {
            throw AppError.llmFailed("Formatting produced no result")
        }
        timing.formattingSeconds = AppLogger.elapsedMilliseconds(since: formattingStart) / 1000

        let formatted = formatResult.text
        DiagnosticLog.write(
            "format done intent=\(formatResult.intent.rawValue) level=\(formatResult.level.rawValue) newlines=\(formatted.filter { $0 == "\n" }.count) chars=\(formatted.count)"
        )

        ContextSessionStore.shared.record(
            sessionKey: sessionKey,
            intent: formatResult.intent,
            transcript: cleanedTranscript,
            formatted: formatted
        )
        PersonalDictionaryStore.shared.learn(from: formatted)

        // Save before injecting so text is recoverable if paste fails.
        historyStore.record(
            formatted,
            provider: formatResult.provider,
            transcriptionModel: transcriptionLabel,
            timing: timing,
            delayNote: nil
        )

        let captureStartedAt = speechStartedAt
        defer {
            timing.processingSeconds = AppLogger.elapsedMilliseconds(since: processingStart) / 1000
            let totalDuration = captureStartedAt.map { AppLogger.elapsedMilliseconds(since: $0) / 1000 }
            let note = Self.buildDelayNote(
                timing: timing,
                transcriptionModel: transcriptionLabel,
                provider: formatResult.provider,
                extraNotes: delayNotes
            )
            historyStore.updateLatestMetrics(
                durationSeconds: totalDuration,
                timing: timing,
                delayNote: note
            )
        }

        let cleanedFormatted = formatted.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.hasMeaningfulSpeech(cleanedFormatted) else {
            DiagnosticLog.write("formatter returned empty — skipping paste")
            AppLogger.pipeline.info("Formatted text empty; skipping inject")
            recordingState.update(.idle)
            return
        }

        // Inject — restore the user's app first so ⌘V hits their caret.
        recordingState.update(.injecting)
        await restorePasteTargetFocus()
        let injectionStart = ContinuousClock.now
        try await AppLogger.measure("injection", logger: AppLogger.injection) {
            try await injector.inject(
                cleanedFormatted,
                targetBundleID: targetBundle,
                targetAppName: targetName
            )
        }
        timing.injectionSeconds = AppLogger.elapsedMilliseconds(since: injectionStart) / 1000

        recordingState.update(.success)
        let totalMS = AppLogger.elapsedMilliseconds(since: sessionStart)
        AppLogger.pipeline.info("Dictation session completed in \(totalMS, format: .fixed(precision: 1)) ms")
    }

    /// Runs `operation`, returning nil if it hasn't finished within `seconds`.
    private nonisolated static func withDeadline<T: Sendable>(
        _ seconds: TimeInterval,
        _ operation: @escaping @Sendable () async throws -> T
    ) async throws -> T? {
        try await withThrowingTaskGroup(of: T?.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                return nil
            }
            defer { group.cancelAll() }
            return try await group.next() ?? nil
        }
    }

    /// True when ASR/LLM text has real content — not blank, punctuation-only,
    /// or common silence hallucinations ("no text", "thank you", etc.).
    private static func hasMeaningfulSpeech(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }

        let normalized = Self.normalizedSpeechContent(trimmed)
        guard !normalized.isEmpty else { return false }

        if Self.emptyHallucinations.contains(normalized) { return false }
        if normalized.hasPrefix("no text") { return false }
        if normalized.hasPrefix("there is no text") { return false }
        if normalized.hasPrefix("no speech") { return false }
        if normalized.hasPrefix("nothing to") { return false }

        return true
    }

    /// Progressive / speculative reuse must be nearly complete — otherwise the
    /// last sentence is silently dropped.
    private static func progressiveCoversTranscript(progressive: String, full: String) -> Bool {
        let p = progressive.trimmingCharacters(in: .whitespacesAndNewlines).count
        let f = full.trimmingCharacters(in: .whitespacesAndNewlines).count
        guard f > 0 else { return false }
        let ratio = Double(p) / Double(f)
        let missing = f - p
        // Require ~full coverage and at most a tiny absolute gap (≈ a short word).
        if ratio < Constants.Formatting.progressiveMinCoverage || missing > 16 {
            DiagnosticLog.write(
                String(format: "progressive coverage low %.0f%% (%d/%d missing=%d); single-shot fallback", ratio * 100, p, f, missing)
            )
            return false
        }
        return true
    }

    /// Lowercase letters/digits only, single spaces — for empty-phrase matching.
    private static func normalizedSpeechContent(_ text: String) -> String {
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

    /// Whisper / LLM often invent these when the mic heard silence.
    private static let emptyHallucinations: Set<String> = [
        "no text",
        "no text to process",
        "there is no text",
        "there is no text to process",
        "no speech",
        "no speech detected",
        "blank",
        "blank audio",
        "silence",
        "silent",
        "empty",
        "nothing",
        "nothing to process",
        "thank you",
        "thanks",
        "thanks for watching",
        "thanks for listening",
        "you",
        "the",
        "a",
        "um",
        "uh",
        "ah",
        "hmm",
        "subtitle",
        "subtitles",
        "music",
        "applause",
        "bye",
        "okay",
        "ok"
    ]

    // MARK: - VAD bridging

    private func handleVAD(_ event: VoiceActivityDetector.Event) {
        switch event {
        case .speechStarted:
            if recordingState.state == .listening {
                recordingState.update(.detectingSpeech)
            }
        case .silenceTimedOut:
            // HTTP-chunk path: commit at phrase boundary. Streaming path: Deepgram
            // endpointing handles this; commit is a no-op.
            liveTranscriber?.commitOnSilence()
            liveStreamer?.commitOnSilence()
            vad?.reset()
        }
    }

    private func waitForManualStopOrTimeout(seconds: TimeInterval) async {
        let timeoutTask = Task { @MainActor [weak self] in
            let nanos = UInt64(seconds * 1_000_000_000)
            try? await Task.sleep(nanoseconds: nanos)
            self?.requestRecordingStop()
        }
        await waitForRecordingStop()
        timeoutTask.cancel()
    }

    private func waitForRecordingStop() async {
        if recordingStopRequested { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            recordingStopContinuation = continuation
        }
    }

    private func requestRecordingStop() {
        // Don't flush here — runSession applies a short post-roll so the last
        // words still reach the live buffer, then flushes and stops the mic.
        recordingStopRequested = true
        recordingStopContinuation?.resume()
        recordingStopContinuation = nil
    }

    private func makeFormattingService(
        config: Configuration,
        utteranceDurationSeconds: TimeInterval
    ) -> LLMFormattingService {
        let geminiKey = configurationStore.resolvedGeminiKey() ?? ""
        let openAIKey = configurationStore.resolvedOpenAIKey() ?? ""
        let groqKey = configurationStore.resolvedGroqKey() ?? ""
        return LLMFormattingService(
            mode: config.formattingMode,
            ollama: OllamaClient(
                model: config.ollamaModel,
                timeout: config.ollamaTimeout
            ),
            gemini: geminiKey.isEmpty
                ? nil
                : GeminiClient(
                    apiKey: geminiKey,
                    model: config.geminiModel,
                    temperature: config.temperature,
                    fallbackModel: config.geminiModel == Constants.LLM.fallbackGeminiModel
                        ? Constants.LLM.defaultGeminiModel
                        : Constants.LLM.fallbackGeminiModel
                ),
            groq: groqKey.isEmpty
                ? nil
                : GroqClient(apiKey: groqKey, model: config.groqModel, temperature: config.temperature),
            openAI: openAIKey.isEmpty
                ? nil
                : OpenAIClient(apiKey: openAIKey, model: config.openAIModel, temperature: config.temperature),
            recordUsage: { [weak usageStore] provider in
                await usageStore?.record(provider)
            },
            utteranceDurationSeconds: utteranceDurationSeconds
        )
    }

    private static func transcriptionModelLabel(for config: Configuration) -> String {
        switch config.speechEngine {
        case .deepgram:
            return "Deepgram · \(config.deepgramModel)"
        case .whisperKit:
            return "WhisperKit · \(config.whisperModel)"
        case .appleSpeech:
            return "Apple Speech"
        }
    }

    /// Builds a short History note explaining what dominated latency.
    private static func buildDelayNote(
        timing: TranscriptHistoryStore.TimingBreakdown,
        transcriptionModel: String,
        provider: LLMProvider,
        extraNotes: [String]
    ) -> String? {
        var parts: [String] = []

        let transcription = timing.transcriptionSeconds ?? 0
        let formatting = timing.formattingSeconds ?? 0
        let injection = timing.injectionSeconds ?? 0

        // Thresholds: local Whisper should usually be < ~2–3s for short clips;
        // cloud LLM usually < ~1.5s; paste overhead is normally < 0.5s.
        if transcription >= 3.0 {
            parts.append(
                String(format: "Transcription was slow (%.1fs via %@)", transcription, transcriptionModel)
            )
        }
        if formatting >= 2.0 {
            parts.append(
                String(format: "%@ API was slow (%.1fs)", provider.displayName, formatting)
            )
        } else if formatting >= 1.2 && provider != .ollama {
            parts.append(
                String(format: "%@ network/API took %.1fs", provider.displayName, formatting)
            )
        }
        if injection >= 0.8 {
            parts.append(String(format: "Paste step was slow (%.1fs)", injection))
        }

        parts.append(contentsOf: extraNotes)

        if parts.isEmpty {
            if let slowest = timing.slowestStage,
               let processing = timing.processingSeconds,
               processing >= 2.5 {
                parts.append(String(format: "Most time in %@ (%.1fs total processing)", slowest, processing))
            } else {
                return nil
            }
        }

        return parts.joined(separator: " · ")
    }
}
