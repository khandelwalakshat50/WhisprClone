import Foundation

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

    /// Cached so the WhisperKit model stays loaded across sessions.
    private var cachedWhisperRecognizer: WhisperKitRecognizer?
    private var cachedWhisperModelName: String?

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

        // Warm up the WhisperKit model in the background so the first
        // dictation doesn't stall on download/load.
        if configurationStore.configuration.speechEngine == .whisperKit {
            let recognizer = whisperRecognizer(for: configurationStore.configuration.whisperModel)
            Task.detached(priority: .utility) {
                await recognizer.preload()
            }
        }

        AppLogger.pipeline.info("Dictation coordinator started")
    }

    private func whisperRecognizer(for modelName: String) -> WhisperKitRecognizer {
        if let cachedWhisperRecognizer, cachedWhisperModelName == modelName {
            return cachedWhisperRecognizer
        }
        let recognizer = WhisperKitRecognizer(modelName: modelName)
        cachedWhisperRecognizer = recognizer
        cachedWhisperModelName = modelName
        return recognizer
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
        switch (action, recordingState.state) {
        case (.begin, .idle), (.begin, .success), (.begin, .failure),
             (.toggle, .idle), (.toggle, .success), (.toggle, .failure):
            beginSession()
        case (.stop, .listening), (.stop, .detectingSpeech),
             (.toggle, .listening), (.toggle, .detectingSpeech):
            requestRecordingStop()
        default:
            break
        }
    }

    private func beginSession() {
        cancelActiveSession(resetState: false)
        recordingStopRequested = false

        activeTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.runSession()
            } catch is CancellationError {
                self.recordingState.update(.idle)
            } catch let error as AppError {
                AppLogger.pipeline.error("Session failed: \(error.localizedDescription, privacy: .public)")
                _ = self.recorder.stop()
                self.recordingState.update(.failure(error.localizedDescription))
            } catch {
                AppLogger.pipeline.error("Session failed: \(error.localizedDescription, privacy: .public)")
                _ = self.recorder.stop()
                self.recordingState.update(.failure(error.localizedDescription))
            }
        }
    }

    private func cancelActiveSession(resetState: Bool) {
        activeTask?.cancel()
        activeTask = nil
        requestRecordingStop()
        _ = recorder.stop()
        vad = nil
        overlayPresentation.resetAudioLevel()
        speechStartedAt = nil
        if resetState {
            recordingState.update(.idle)
        }
    }

    private func runSession() async throws {
        let sessionStart = ContinuousClock.now
        AppLogger.pipeline.info("Dictation session begin")

        let mic = await permissions.requestMicrophone()
        guard mic == .granted else { throw AppError.microphonePermissionDenied }

        if configurationStore.configuration.speechEngine == .appleSpeech {
            let speech = await permissions.requestSpeechRecognition()
            guard speech == .granted else { throw AppError.speechPermissionDenied }
        }

        recordingState.update(.listening)
        speechStartedAt = ContinuousClock.now

        let detector = VoiceActivityDetector(
            onLevel: { [weak overlayPresentation] rms in
                Task { @MainActor in
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

        let url: URL
        do {
            url = try recorder.start { [weak detector] buffer, _ in
                detector?.process(buffer: buffer)
            }
        } catch {
            throw AppError.microphoneUnavailable
        }

        await waitForManualStopOrTimeout(seconds: Constants.Audio.maxListenSeconds)
        try Task.checkCancellation()

        if let speechStartedAt {
            let listenMS = AppLogger.elapsedMilliseconds(since: speechStartedAt)
            AppLogger.audio.info("Speech capture window \(listenMS, format: .fixed(precision: 1)) ms")
        }

        guard let fileURL = recorder.stop() ?? Optional(url) else {
            throw AppError.recordingFailed("No audio file")
        }
        overlayPresentation.resetAudioLevel()

        defer { try? FileManager.default.removeItem(at: fileURL) }

        // Transcribe
        recordingState.update(.transcribing)
        let config = configurationStore.configuration
        let recognizer: any SpeechRecognizing
        switch config.speechEngine {
        case .whisperKit:
            recognizer = whisperRecognizer(for: config.whisperModel)
        case .appleSpeech:
            recognizer = AppleSpeechRecognizer()
        }

        let transcript = try await AppLogger.measure("transcription", logger: AppLogger.speech) {
            try await recognizer.transcribe(audioURL: fileURL)
        }

        let cleanedTranscript = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanedTranscript.isEmpty else { throw AppError.emptyTranscript }

        // Format
        recordingState.update(.formatting)
        let openAIKey = configurationStore.resolvedOpenAIKey() ?? ""
        let groqKey = configurationStore.resolvedGroqKey() ?? ""
        let formatter = LLMFormattingService(
            mode: config.formattingMode,
            ollama: OllamaClient(
                model: config.ollamaModel,
                timeout: config.ollamaTimeout
            ),
            groq: groqKey.isEmpty
                ? nil
                : GroqClient(apiKey: groqKey, model: config.groqModel, temperature: config.temperature),
            openAI: openAIKey.isEmpty
                ? nil
                : OpenAIClient(apiKey: openAIKey, model: config.openAIModel, temperature: config.temperature),
            recordUsage: { [weak usageStore] provider in
                await usageStore?.record(provider)
            }
        )
        let formatted = try await AppLogger.measure("llm.format", logger: AppLogger.llm) {
            try await formatter.format(text: cleanedTranscript)
        }
        let formattingProvider = usageStore.mostRecentlyUsedProvider

        // Save before injecting so text is recoverable if paste fails.
        historyStore.record(
            formatted,
            provider: formattingProvider,
            transcriptionModel: Self.transcriptionModelLabel(for: config)
        )

        let captureStartedAt = speechStartedAt
        defer {
            if let captureStartedAt {
                historyStore.updateLatestDuration(AppLogger.elapsedMilliseconds(since: captureStartedAt) / 1000)
            }
        }

        // Inject
        recordingState.update(.injecting)
        try await AppLogger.measure("injection", logger: AppLogger.injection) {
            try await injector.inject(formatted)
        }

        recordingState.update(.success)
        let totalMS = AppLogger.elapsedMilliseconds(since: sessionStart)
        AppLogger.pipeline.info("Dictation session completed in \(totalMS, format: .fixed(precision: 1)) ms")
    }

    // MARK: - VAD bridging

    private func handleVAD(_ event: VoiceActivityDetector.Event) {
        switch event {
        case .speechStarted:
            if recordingState.state == .listening {
                recordingState.update(.detectingSpeech)
            }
        case .silenceTimedOut:
            // Silence changes only the visual activity state. Recording ends
            // exclusively when the user presses the stop hotkey.
            break
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
        recordingStopRequested = true
        recordingStopContinuation?.resume()
        recordingStopContinuation = nil
    }

    private static func transcriptionModelLabel(for config: Configuration) -> String {
        switch config.speechEngine {
        case .whisperKit:
            return "WhisperKit · \(config.whisperModel)"
        case .appleSpeech:
            return "Apple Speech"
        }
    }
}
