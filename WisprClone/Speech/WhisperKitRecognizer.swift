import Foundation
import Synchronization

#if canImport(WhisperKit)
import WhisperKit

/// WhisperKit is not `Sendable`. This box lets us store and pass a pipeline
/// reference under Swift 6 without pretending the type itself is safe.
private struct WhisperKitBox: @unchecked Sendable {
    let kit: WhisperKit
}
#endif

/// Primary production engine — Argmax WhisperKit (CoreML).
/// Model download/load happens lazily on first transcription.
final class WhisperKitRecognizer: SpeechRecognizing, @unchecked Sendable {
    private let modelName: String

    #if canImport(WhisperKit)
    private let storage = Mutex<WhisperKitBox?>(nil)
    #endif

    init(modelName: String = "base") {
        self.modelName = modelName
    }

    func transcribe(audioURL: URL) async throws -> String {
        #if canImport(WhisperKit)
        let box = try await ensureLoaded()
        AppLogger.speech.info("WhisperKit transcription started (\(self.modelName, privacy: .public))")
        do {
            let path = audioURL.path
            let results = try await box.kit.transcribe(audioPath: path)
            let text = results
                .map(\.text)
                .joined(separator: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return text
        } catch {
            AppLogger.speech.error("WhisperKit transcription failed: \(error.localizedDescription, privacy: .public)")
            throw AppError.transcriptionFailed(error.localizedDescription)
        }
        #else
        throw AppError.transcriptionFailed("WhisperKit is not linked — select Apple Speech or add the package")
        #endif
    }

    /// Loads the model ahead of time so the first dictation doesn't pay the cost.
    func preload() async {
        #if canImport(WhisperKit)
        _ = try? await ensureLoaded()
        #endif
    }

    #if canImport(WhisperKit)
    /// Models live in Application Support, not the default `~/Documents/huggingface`:
    /// Documents is TCC-protected and access breaks whenever the app's signature changes.
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

        do {
            // prewarm + load so CoreML compilation and Neural Engine
            // specialization happen here (at app launch), not on first dictation.
            let created = try await WhisperKit(
                model: modelName,
                downloadBase: Self.modelsDirectory,
                prewarm: true,
                load: true
            )
            let box = WhisperKitBox(kit: created)
            let ready = storage.withLock { current -> WhisperKitBox in
                if let current { return current }
                current = box
                return box
            }
            AppLogger.speech.info("WhisperKit model loaded: \(self.modelName, privacy: .public)")
            return ready
        } catch {
            AppLogger.speech.error("WhisperKit load failed: \(error.localizedDescription, privacy: .public)")
            throw AppError.transcriptionFailed(error.localizedDescription)
        }
    }
    #endif
}
