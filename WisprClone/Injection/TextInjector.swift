import ApplicationServices
import Foundation
import os

/// Coordinates insertion: prefer Accessibility (near-instant), clipboard ⌘V fallback.
struct TextInjector {
    private let clipboard = ClipboardInjection()
    private let accessibility = AccessibilityInjection()
    private let logger = Logger(subsystem: Constants.bundleIdentifier, category: "TextInjector")

    func inject(
        _ text: String,
        targetBundleID: String? = nil,
        targetAppName: String? = nil
    ) async throws {
        // Without Accessibility trust, macOS silently drops synthesized ⌘V —
        // keep the text on the clipboard and surface the failure instead.
        guard AXIsProcessTrusted() else {
            ClipboardInjection.copyOnly(text)
            let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)
            DiagnosticLog.write("inject blocked: Accessibility not trusted — text left on clipboard")
            throw AppError.injectionFailed("Accessibility off · copied, press ⌘V")
        }

        // Cursor, Chrome, Slack and other Electron/browser apps report a successful
        // Accessibility write while the visible editor never changes. Paste with ⌘V.
        if Self.ignoresAccessibilityInsert(bundleID: targetBundleID, appName: targetAppName) {
            DiagnosticLog.write(
                "inject skip accessibility for \(targetAppName ?? targetBundleID ?? "app") — clipboard ⌘V"
            )
        } else {
            do {
                try accessibility.inject(text)
                logger.info("Injected via Accessibility (\(text.count) chars)")
                DiagnosticLog.write("inject via accessibility chars=\(text.count)")
                return
            } catch {
                logger.info(
                    "Accessibility inject unavailable; clipboard fallback — \(error.localizedDescription, privacy: .public)"
                )
                DiagnosticLog.write("inject accessibility failed: \(error.localizedDescription)")
            }
        }

        do {
            try await clipboard.inject(text)
            DiagnosticLog.write("inject via clipboard ⌘V chars=\(text.count)")
        } catch {
            throw AppError.injectionFailed(error.localizedDescription)
        }
    }

    /// Apps whose focused accessibility element is not the text the user sees.
    private static func ignoresAccessibilityInsert(bundleID: String?, appName: String?) -> Bool {
        let hint = "\((bundleID ?? "").lowercased()) \((appName ?? "").lowercased())"
        let markers = [
            "cursor", "todesktop", "code", "electron", "chrome", "chromium",
            "brave", "edge", "arc", "firefox", "safari", "slack", "discord",
            "notion", "figma", "obsidian", "whatsapp", "telegram", "spotify"
        ]
        return markers.contains { hint.contains($0) }
    }
}
