import Foundation
import os

/// Coordinates preferred clipboard paste with Accessibility fallback.
struct TextInjector {
    private let clipboard = ClipboardInjection()
    private let accessibility = AccessibilityInjection()
    private let logger = Logger(subsystem: Constants.bundleIdentifier, category: "TextInjector")

    func inject(_ text: String) async throws {
        do {
            try await clipboard.inject(text)
        } catch {
            logger.warning("Clipboard injection failed; trying Accessibility — \(error.localizedDescription, privacy: .public)")
            do {
                try accessibility.inject(text)
            } catch {
                throw AppError.injectionFailed(error.localizedDescription)
            }
        }
    }
}
