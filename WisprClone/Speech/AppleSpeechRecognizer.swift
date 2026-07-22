import Foundation
import Speech
import os

/// Fallback / MVP recognizer using Apple's `SFSpeechRecognizer`.
struct AppleSpeechRecognizer: SpeechRecognizing {
    private let logger = Logger(subsystem: Constants.bundleIdentifier, category: "AppleSpeech")

    func transcribe(audioURL: URL) async throws -> String {
        guard let recognizer = SFSpeechRecognizer(), recognizer.isAvailable else {
            throw AppError.transcriptionFailed("Speech recognizer unavailable")
        }

        let status = SFSpeechRecognizer.authorizationStatus()
        guard status == .authorized else {
            throw AppError.speechPermissionDenied
        }

        let request = SFSpeechURLRecognitionRequest(url: audioURL)
        request.shouldReportPartialResults = false
        request.requiresOnDeviceRecognition = true

        logger.info("Apple Speech transcription started")

        return try await withCheckedThrowingContinuation { continuation in
            let lock = NSLock()
            var hasResumed = false
            func resumeOnce(_ result: Result<String, Error>) {
                lock.lock()
                defer { lock.unlock() }
                guard !hasResumed else { return }
                hasResumed = true
                continuation.resume(with: result)
            }

            recognizer.recognitionTask(with: request) { result, error in
                if let error {
                    resumeOnce(.failure(AppError.transcriptionFailed(error.localizedDescription)))
                    return
                }
                guard let result, result.isFinal else { return }
                let text = result.bestTranscription.formattedString
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                resumeOnce(.success(text))
            }
        }
    }
}
