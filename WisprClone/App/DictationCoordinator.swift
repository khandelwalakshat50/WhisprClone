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
    /// App that had focus when dictation started — paste must land there, not in WisprClone.
    private var pasteTargetApp: NSRunningApplication?
    /// Progressive Whisper while listening (WhisperKit path only).
    private var liveTranscriber: LiveChunkTranscriber?

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
            requestRecordingStop()
        default:
            DiagnosticLog.write("hotkey ignored for current state")
            break
        }
    }

    private func beginSession() {
        cancelActiveSession(resetState: false)
        recordingStopRequested = false
        // Remember the user's focused app *before* we do anything that might
        // touch activation — ⌘V must land there, not in Preferences/overlay.
        pasteTargetApp = Self.frontmostAppExcludingSelf()
        DiagnosticLog.write(
            "paste target=\(pasteTargetApp?.localizedName ?? "none") pid=\(pasteTargetApp?.processIdentifier ?? -1)"
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
                self.recordingState.update(.idle)
            } catch let error as AppError {
                AppLogger.pipeline.error("Session failed: \(error.localizedDescription, privacy: .public)")
                DiagnosticLog.write("session failed: \(error.localizedDescription)")
                _ = self.recorder.stop()
                self.recordingState.update(.failure(error.localizedDescription))
            } catch {
                AppLogger.pipeline.error("Session failed: \(error.localizedDescription, privacy: .public)")
                DiagnosticLog.write("session failed: \(error.localizedDescription)")
                _ = self.recorder.stop()
                self.recordingState.update(.failure(error.localizedDescription))
            }
        }
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
        try? await Task.sleep(nanoseconds: 80_000_000)
    }

    private func cancelActiveSession(resetState: Bool) {
        activeTask?.cancel()
        activeTask = nil
        requestRecordingStop()
        _ = recorder.stop()
        vad = nil
        liveTranscriber = nil
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
        speechStartedAt = ContinuousClock.now

        let config = configurationStore.configuration
        let useLiveWhisper = config.speechEngine == .whisperKit
        let whisper = useLiveWhisper ? whisperRecognizer(for: config.whisperModel) : nil
        let live = whisper.map { LiveChunkTranscriber(recognizer: $0) }
        liveTranscriber = live

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

        try Task.checkCancellation()

        let url: URL
        do {
            url = try recorder.start { [weak detector, live] buffer, _ in
                detector?.process(buffer: buffer)
                live?.ingest(buffer)
            }
            DiagnosticLog.write("recorder started liveASR=\(useLiveWhisper)")
        } catch {
            DiagnosticLog.write("recorder start failed: \(error.localizedDescription)")
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

        defer {
            try? FileManager.default.removeItem(at: fileURL)
            liveTranscriber = nil
        }

        let processingStart = ContinuousClock.now
        var timing = TranscriptHistoryStore.TimingBreakdown()
        var delayNotes: [String] = []

        // Transcribe — prefer live chunks already processed while speaking.
        recordingState.update(.transcribing)
        let transcriptionLabel = Self.transcriptionModelLabel(for: config)
        let transcriptionStart = ContinuousClock.now

        let transcript: String
        if let live {
            let liveResult = await live.finish()
            if Self.hasMeaningfulSpeech(liveResult.text) {
                transcript = liveResult.text
                delayNotes.append("Live ASR · \(liveResult.chunkCount) chunk(s) while speaking")
                DiagnosticLog.write("live transcript chunks=\(liveResult.chunkCount) chars=\(transcript.count)")
            } else {
                // Fallback: full-file Whisper with internal VAD chunking.
                DiagnosticLog.write("live ASR empty — falling back to full file")
                delayNotes.append("Live ASR empty; fell back to full-file Whisper")
                transcript = try await AppLogger.measure("transcription", logger: AppLogger.speech) {
                    try await whisperRecognizer(for: config.whisperModel).transcribe(audioURL: fileURL)
                }
            }
        } else {
            let recognizer = AppleSpeechRecognizer()
            transcript = try await AppLogger.measure("transcription", logger: AppLogger.speech) {
                try await recognizer.transcribe(audioURL: fileURL)
            }
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
        let formattingStart = ContinuousClock.now
        let formatResult = try await AppLogger.measure("llm.format", logger: AppLogger.llm) {
            try await formatter.formatDetailed(text: cleanedTranscript)
        }
        timing.formattingSeconds = AppLogger.elapsedMilliseconds(since: formattingStart) / 1000
        delayNotes.append(contentsOf: formatResult.notes)

        let formatted = formatResult.text

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
            try await injector.inject(cleanedFormatted)
        }
        timing.injectionSeconds = AppLogger.elapsedMilliseconds(since: injectionStart) / 1000

        recordingState.update(.success)
        let totalMS = AppLogger.elapsedMilliseconds(since: sessionStart)
        AppLogger.pipeline.info("Dictation session completed in \(totalMS, format: .fixed(precision: 1)) ms")
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
            // Commit a live ASR chunk at the phrase boundary, then re-arm VAD
            // so the next phrase can commit again. Recording still ends only
            // when the user presses stop.
            liveTranscriber?.commitOnSilence()
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
        // Kick Whisper on buffered audio before recorder teardown so short
        // utterances don't sit idle for hundreds of ms before decode starts.
        liveTranscriber?.flushEarly()
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
