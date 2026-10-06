import Foundation
import Synchronization

#if canImport(WhisperKit)
import WhisperKit

/// WhisperKit is not `Sendable`. This box lets us store and pass a pipeline
/// reference under Swift 6 without pretending the type itself is safe.
private struct WhisperKitBox: @unchecked Sendable {
    let kit: WhisperKit
}

/// Serializes Whisper inference — concurrent CoreML calls thrash and add latency.
private actor WhisperInferenceGate {
    func run<T: Sendable>(_ work: @Sendable () async throws -> T) async rethrows -> T {
        try await work()
    }
}
#endif

/// Primary production engine — Argmax WhisperKit (CoreML).
/// Model download/load happens lazily on first transcription.
final class WhisperKitRecognizer: SpeechRecognizing, LiveChunkASREngine, @unchecked Sendable {
    private let modelName: String
    /// Domain terms that bias decoding (names, jargon, places).
    private let vocabularyBias: String

    #if canImport(WhisperKit)
    private let storage = Mutex<WhisperKitBox?>(nil)
    private let gate = WhisperInferenceGate()
    #endif

    init(modelName: String = "base", vocabularyBias: String = "") {
        self.modelName = modelName
        self.vocabularyBias = vocabularyBias
    }

    func transcribe(audioURL: URL) async throws -> SpeechTranscription {
        try await transcribe(audioURL: audioURL, promptContext: nil)
    }

    func transcribe(audioURL: URL, promptContext: String?) async throws -> SpeechTranscription {
        #if canImport(WhisperKit)
        let box = try await ensureLoaded()
        AppLogger.speech.info("WhisperKit transcription started (\(self.modelName, privacy: .public))")
        return try await gate.run {
            do {
                let options = Self.decodeOptions(
                    sampleCount: nil,
                    vocabularyBias: self.vocabularyBias,
                    promptContext: promptContext,
                    tokenizer: box.kit.tokenizer
                )
                let results = try await box.kit.transcribe(
                    audioPath: audioURL.path,
                    decodeOptions: options
                )
                return SpeechTranscription(text: Self.join(results))
            } catch {
                AppLogger.speech.error("WhisperKit transcription failed: \(error.localizedDescription, privacy: .public)")
                throw AppError.transcriptionFailed(error.localizedDescription)
            }
        }
        #else
        throw AppError.transcriptionFailed("WhisperKit is not linked — select Apple Speech or add the package")
        #endif
    }

    /// Transcribe pre-resampled 16 kHz mono float samples (live chunk path).
    func transcribe(samples: [Float], promptContext: String? = nil) async throws -> SpeechTranscription {
        #if canImport(WhisperKit)
        guard !samples.isEmpty else { return SpeechTranscription(text: "") }
        let box = try await ensureLoaded()
        let count = samples.count
        return try await gate.run {
            do {
                let options = Self.decodeOptions(
                    sampleCount: count,
                    vocabularyBias: self.vocabularyBias,
                    promptContext: promptContext,
                    tokenizer: box.kit.tokenizer
                )
                let results = try await box.kit.transcribe(
                    audioArray: samples,
                    decodeOptions: options
                )
                return SpeechTranscription(text: Self.join(results))
            } catch {
                AppLogger.speech.error("WhisperKit sample transcription failed: \(error.localizedDescription, privacy: .public)")
                throw AppError.transcriptionFailed(error.localizedDescription)
            }
        }
        #else
        throw AppError.transcriptionFailed("WhisperKit is not linked — select Apple Speech or add the package")
        #endif
    }

    /// Runs a tiny silent decode so the first real utterance isn't paying
    /// Neural Engine / graph warm-up latency after stop.
    func warmInference() async {
        #if canImport(WhisperKit)
        let silence = [Float](repeating: 0, count: Int(Constants.Audio.whisperSampleRate * 0.35))
        _ = try? await transcribe(samples: silence)
        AppLogger.speech.info("WhisperKit inference warmed")
        DiagnosticLog.write("whisper inference warmed")
        #endif
    }

    #if canImport(WhisperKit)
    private static func join(_ results: [TranscriptionResult]) -> String {
        results
            .map(\.text)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Balanced options: keep short-clip speed, allow one extra fallback retry,
    /// and bias with vocabulary / prior chunk text when available.
    private static func decodeOptions(
        sampleCount: Int?,
        vocabularyBias: String,
        promptContext: String?,
        tokenizer: (any WhisperTokenizer)?
    ) -> DecodingOptions {
        let rate = Constants.Audio.whisperSampleRate
        let seconds = sampleCount.map { Double($0) / rate }
        let useFast = seconds.map { $0 < Constants.Audio.fastDecodeMaxSeconds } ?? false
        let promptTokens = Self.promptTokenIDs(
            vocabularyBias: vocabularyBias,
            promptContext: promptContext,
            tokenizer: tokenizer
        )

        if useFast {
            return DecodingOptions(
                temperature: 0,
                temperatureFallbackCount: 2,
                usePrefillPrompt: true,
                usePrefillCache: true,
                detectLanguage: false,
                skipSpecialTokens: true,
                withoutTimestamps: true,
                wordTimestamps: false,
                promptTokens: promptTokens,
                compressionRatioThreshold: 2.4,
                logProbThreshold: -0.8,
                noSpeechThreshold: 0.6,
                concurrentWorkerCount: 2,
                chunkingStrategy: .none
            )
        }

        return DecodingOptions(
            temperature: 0,
            temperatureFallbackCount: 3,
            usePrefillPrompt: true,
            usePrefillCache: true,
            detectLanguage: false,
            skipSpecialTokens: true,
            withoutTimestamps: true,
            wordTimestamps: false,
            promptTokens: promptTokens,
            compressionRatioThreshold: 2.4,
            logProbThreshold: -0.8,
            noSpeechThreshold: 0.6,
            concurrentWorkerCount: 4,
            chunkingStrategy: .vad
        )
    }

    private static func promptTokenIDs(
        vocabularyBias: String,
        promptContext: String?,
        tokenizer: (any WhisperTokenizer)?
    ) -> [Int]? {
        guard let tokenizer else { return nil }

        var parts: [String] = []
        let vocab = vocabularyBias
            .split { $0 == "," || $0 == "\n" || $0 == ";" }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        if !vocab.isEmpty {
            parts.append(vocab.joined(separator: ", "))
        }
        if let promptContext {
            let trimmed = promptContext.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                // Prefer the recent tail — Whisper's prompt window is small.
                let words = trimmed.split(separator: " ")
                let tail = words.suffix(24).joined(separator: " ")
                parts.append(tail)
            }
        }
        guard !parts.isEmpty else { return nil }

        let prompt = parts.joined(separator: ". ")
        var tokens = tokenizer.encode(text: prompt)
        let limit = Constants.Audio.whisperPromptTokenLimit
        if tokens.count > limit {
            tokens = Array(tokens.suffix(limit))
        }
        return tokens.isEmpty ? nil : tokens
    }
    #endif

    /// Loads the model ahead of time so the first dictation doesn't pay the cost.
    func preload() async {
        #if canImport(WhisperKit)
        _ = try? await ensureLoaded()
        #endif
    }

    #if canImport(WhisperKit)
    private static var modelsDirectory: URL {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(Constants.appName, isDirectory: true)
            .appendingPathComponent("Models", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    private func ensureLoaded() async throws -> WhisperKitBox {
        if let existing = storage.withLock({ $0 }) {
            return existing
        }

        let resolved = Self.resolveModelName(modelName)
        DiagnosticLog.write("whisper load model=\(modelName) resolved=\(resolved)")

        do {
            let created: WhisperKit
            if let localFolder = Self.localModelFolder(for: resolved) {
                // Skip Hub search — "base" matches multiple remote folders and throws.
                AppLogger.speech.info(
                    "WhisperKit loading local model at \(localFolder.lastPathComponent, privacy: .public)"
                )
                created = try await WhisperKit(
                    downloadBase: Self.modelsDirectory,
                    modelFolder: localFolder.path,
                    tokenizerFolder: Self.modelsDirectory,
                    prewarm: true,
                    load: true,
                    download: false
                )
            } else {
                created = try await WhisperKit(
                    model: resolved,
                    downloadBase: Self.modelsDirectory,
                    prewarm: true,
                    load: true
                )
            }
            let box = WhisperKitBox(kit: created)
            let ready = storage.withLock { current -> WhisperKitBox in
                if let current { return current }
                current = box
                return box
            }
            AppLogger.speech.info("WhisperKit model loaded: \(resolved, privacy: .public)")
            return ready
        } catch {
            AppLogger.speech.error("WhisperKit load failed: \(error.localizedDescription, privacy: .public)")
            DiagnosticLog.write("whisper load failed: \(error.localizedDescription)")
            throw AppError.transcriptionFailed(error.localizedDescription)
        }
    }

    /// Map short Preferences names (`base`) to WhisperKit hub folder names.
    private static func resolveModelName(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "openai_whisper-base" }
        if trimmed.hasPrefix("openai_whisper-") { return trimmed }

        switch trimmed.lowercased() {
        case "tiny": return "openai_whisper-tiny"
        case "tiny.en": return "openai_whisper-tiny.en"
        case "base": return "openai_whisper-base"
        case "base.en": return "openai_whisper-base.en"
        case "small": return "openai_whisper-small"
        case "small.en": return "openai_whisper-small.en"
        case "medium": return "openai_whisper-medium"
        case "medium.en": return "openai_whisper-medium.en"
        case "large", "large-v3": return "openai_whisper-large-v3"
        case "large-v3-turbo", "turbo": return "openai_whisper-large-v3-turbo"
        default:
            if trimmed.lowercased().hasPrefix("whisper-") {
                return "openai_\(trimmed.replacingOccurrences(of: " ", with: "-"))"
            }
            return "openai_whisper-\(trimmed)"
        }
    }

    private static func localModelFolder(for resolvedName: String) -> URL? {
        let url = modelsDirectory
            .appendingPathComponent("models", isDirectory: true)
            .appendingPathComponent("argmaxinc", isDirectory: true)
            .appendingPathComponent("whisperkit-coreml", isDirectory: true)
            .appendingPathComponent(resolvedName, isDirectory: true)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else {
            return nil
        }
        let encoder = url.appendingPathComponent("AudioEncoder.mlmodelc", isDirectory: true)
        guard FileManager.default.fileExists(atPath: encoder.path) else { return nil }
        return url
    }
    #endif
}
