import AppKit
import Carbon.HIToolbox
import Foundation
import os

/// Preferred insertion path: clipboard swap → synthesize ⌘V → restore clipboard.
struct ClipboardInjection {
    private let logger = Logger(subsystem: Constants.bundleIdentifier, category: "ClipboardInjection")

    func inject(_ text: String) async throws {
        let pasteboard = NSPasteboard.general
        let saved = pasteboard.backup()

        pasteboard.clearContents()
        guard pasteboard.setString(text, forType: .string) else {
            saved.restore(to: pasteboard)
            throw AppError.injectionFailed("Could not write pasteboard")
        }
        let ourChangeCount = pasteboard.changeCount

        try Self.postCommandV()
        // Give the target app time to service ⌘V while our text is still
        // on the pasteboard; restoring too early pastes the OLD clipboard.
        try await Task.sleep(nanoseconds: Constants.Injection.pasteDeliveryNanoseconds)
        logger.info("Clipboard injection completed (\(text.count) chars)")

        // Restore the user's clipboard off the critical path, and only if
        // nobody has written to the pasteboard since we did. The delay scales
        // with length: large transcripts (and apps like Chrome/Electron that
        // read the pasteboard asynchronously) need longer before restore, or
        // the paste silently lands the OLD clipboard content.
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
