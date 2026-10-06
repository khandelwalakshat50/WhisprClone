import ApplicationServices
import Foundation
import os

/// Coordinates insertion: prefer Accessibility (near-instant), clipboard ⌘V fallback.
struct TextInjector {
    private let clipboard = ClipboardInjection()
    private let accessibility = AccessibilityInjection()
    private let logger = Logger(subsystem: Constants.bundleIdentifier, category: "TextInjector")

    func inject(_ text: String) async throws {
        // Without Accessibility trust, macOS silently drops synthesized ⌘V —
        // keep the text on the clipboard and surface the failure instead.
        guard AXIsProcessTrusted() else {
            ClipboardInjection.copyOnly(text)
            let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)
            DiagnosticLog.write("inject blocked: Accessibility not trusted — text left on clipboard")
            throw AppError.injectionFailed("Accessibility off · copied, press ⌘V")
        }

        // AX set-value has no artificial settle delay — use it when the focused
        // field supports it (Notes, many native apps). Chrome/Gmail often fail AX
        // and fall through to clipboard.
        do {
            try accessibility.inject(text)
            logger.info("Injected via Accessibility (\(text.count) chars)")
            DiagnosticLog.write("inject via accessibility chars=\(text.count)")
            return
        } catch {
            logger.info(
                "Accessibility inject unavailable; clipboard fallback — \(error.localizedDescription, privacy: .public)"
            )
        }

        do {
            try await clipboard.inject(text)
            DiagnosticLog.write("inject via clipboard ⌘V chars=\(text.count)")
        } catch {
            throw AppError.injectionFailed(error.localizedDescription)
        }
    }
}
