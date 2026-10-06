import AppKit
import Carbon.HIToolbox
import Foundation
import os

/// Preferred insertion path: clipboard swap → synthesize ⌘V → restore clipboard.
///
/// For multi-line text, also publishes HTML so Gmail/Chrome contenteditable
/// keeps real line breaks (plain `\n` is often flattened to spaces there).
struct ClipboardInjection {
    private let logger = Logger(subsystem: Constants.bundleIdentifier, category: "ClipboardInjection")

    func inject(_ text: String) async throws {
        let pasteboard = NSPasteboard.general
        let saved = pasteboard.backup()

        pasteboard.clearContents()
        guard Self.write(text, to: pasteboard) else {
            saved.restore(to: pasteboard)
            throw AppError.injectionFailed("Could not write pasteboard")
        }
        let ourChangeCount = pasteboard.changeCount

        try Self.postCommandV()
        // Only need a short settle before we return; clipboard restore is deferred.
        try await Task.sleep(nanoseconds: Constants.Injection.pasteDeliveryNanoseconds)
        logger.info("Clipboard injection completed (\(text.count) chars, newlines=\(text.filter { $0 == "\n" }.count))")

        // Restore the user's clipboard off the critical path. Chrome/Electron
        // may read the pasteboard asynchronously, so keep a longer restore delay
        // here without blocking the dictation UI.
        let restoreDelay = Self.restoreDelayNanoseconds(forCharacters: text.count)
        let log = logger
        Task.detached(priority: .utility) {
            try? await Task.sleep(nanoseconds: restoreDelay)
            let pb = NSPasteboard.general
            guard pb.changeCount == ourChangeCount else { return }
            saved.restore(to: pb)
            log.info("Original clipboard restored")
        }
    }

    /// Leaves the text on the clipboard (no ⌘V, no restore) so the user can paste manually.
    static func copyOnly(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        _ = write(text, to: pasteboard)
    }

    /// Plain string always; HTML when there are newlines (Gmail / Docs / Slack web).
    private static func write(_ text: String, to pasteboard: NSPasteboard) -> Bool {
        if text.contains("\n") {
            let html = htmlFragment(from: text)
            pasteboard.declareTypes([.html, .string], owner: nil)
            let htmlOK = pasteboard.setString(html, forType: .html)
            let plainOK = pasteboard.setString(text, forType: .string)
            return htmlOK && plainOK
        }
        return pasteboard.setString(text, forType: .string)
    }

    private static func htmlFragment(from text: String) -> String {
        let lines = text.components(separatedBy: "\n")
        let body = lines.map { line -> String in
            if line.isEmpty { return "<div><br></div>" }
            return "<div>\(escapeHTML(line))</div>"
        }.joined()
        return """
        <!DOCTYPE html><html><body><!--StartFragment-->\(body)<!--EndFragment--></body></html>
        """
    }

    private static func escapeHTML(_ string: String) -> String {
        string
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    /// Base delay plus ~1 ms per character, clamped to a sane ceiling so the
    /// user's clipboard is never held hostage for too long.
    private static func restoreDelayNanoseconds(forCharacters count: Int) -> UInt64 {
        let base = Constants.Injection.clipboardRestoreNanoseconds
        let perChar: UInt64 = 1_000_000 // 1 ms / char
        let scaled = base + UInt64(max(0, count)) * perChar
        let ceiling: UInt64 = 6_000_000_000 // 6 s
        return min(scaled, ceiling)
    }

    private static func postCommandV() throws {
        let source = CGEventSource(stateID: .hidSystemState)

        guard
            let keyDown = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: true),
            let keyUp = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: false)
        else {
            throw AppError.injectionFailed("Could not create paste events")
        }

        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
    }
}

// MARK: - Pasteboard snapshot

private struct PasteboardBackup {
    let entries: [(NSPasteboard.PasteboardType, Data)]

    func restore(to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        guard !entries.isEmpty else { return }
        let types = entries.map(\.0)
        pasteboard.declareTypes(types, owner: nil)
        for (type, data) in entries {
            pasteboard.setData(data, forType: type)
        }
    }
}

private extension NSPasteboard {
    func backup() -> PasteboardBackup {
        var entries: [(NSPasteboard.PasteboardType, Data)] = []
        for type in types ?? [] {
            if let data = data(forType: type) {
                entries.append((type, data))
            }
        }
        return PasteboardBackup(entries: entries)
    }
}
