import AppKit

/// Owns the status-item icon and its menu.
@MainActor
final class MenuBarController: NSObject {
    private let recordingState: RecordingStateStore
    private let preferencesAction: () -> Void
    private let startDictationAction: () -> Void

    private var statusItem: NSStatusItem?
    private var stateObserverID: UUID?

    init(
        recordingState: RecordingStateStore,
        preferencesAction: @escaping () -> Void,
        startDictationAction: @escaping () -> Void = {}
    ) {
        self.recordingState = recordingState
        self.preferencesAction = preferencesAction
        self.startDictationAction = startDictationAction
        super.init()
    }

    func install() {
        // Fixed square length keeps the item visible even if the image fails.
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.isVisible = true
        statusItem = item

        if let button = item.button {
            button.image = Self.menuBarImage()
            button.title = " Wispr"
            button.imagePosition = .imageLeading
            button.toolTip = "\(Constants.appName) — click for menu"
            button.setAccessibilityTitle(Constants.appName)
            button.appearsDisabled = false
        }

        // Keep the item out of the overflow menu when possible.
        if #available(macOS 11.0, *) {
            item.behavior = [.removalAllowed]
            item.autosaveName = "WisprCloneStatusItem"
        }

        item.menu = buildMenu()
        AppLogger.menuBar.info("Status item installed (look for “Wispr” in the menu bar)")
        // Force a redraw — occasionally the first install paints blank.
        item.isVisible = true
        statusItem = item

        stateObserverID = recordingState.addObserver { [weak self] state in
            self?.applyStatusAppearance(for: state)
        }
        applyStatusAppearance(for: recordingState.state)
    }

    func tearDown() {
        if let stateObserverID {
            recordingState.removeObserver(stateObserverID)
            self.stateObserverID = nil
        }
        if let statusItem {
            NSStatusBar.system.removeStatusItem(statusItem)
            self.statusItem = nil
        }
        AppLogger.menuBar.info("Status item removed")
    }

    // MARK: - Menu

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false

        let start = NSMenuItem(
            title: "Start Dictation",
            action: #selector(startDictationClicked(_:)),
            keyEquivalent: "d"
        )
        start.keyEquivalentModifierMask = [.command, .shift]
        start.target = self
        start.isEnabled = true
        menu.addItem(start)

        menu.addItem(.separator())

        let preferences = NSMenuItem(
            title: "Preferences…",
            action: #selector(preferencesClicked(_:)),
            keyEquivalent: ","
        )
        preferences.keyEquivalentModifierMask = .command
        preferences.target = self
        preferences.isEnabled = true
        menu.addItem(preferences)

        menu.addItem(.separator())
        let preview = NSMenuItem(
            title: "Preview Overlay",
            action: #selector(previewOverlayClicked(_:)),
            keyEquivalent: ""
        )
        preview.target = self
        preview.isEnabled = true
        menu.addItem(preview)

        menu.addItem(.separator())

        let about = NSMenuItem(
            title: "About \(Constants.appName)",
            action: #selector(aboutClicked(_:)),
            keyEquivalent: ""
        )
        about.target = self
        about.isEnabled = true
        menu.addItem(about)

        menu.addItem(.separator())

        let quit = NSMenuItem(
            title: "Quit \(Constants.appName)",
            action: #selector(quitClicked(_:)),
            keyEquivalent: "q"
        )
        quit.keyEquivalentModifierMask = .command
        quit.target = self
        quit.isEnabled = true
        menu.addItem(quit)

        return menu
    }

    @objc private func startDictationClicked(_ sender: Any?) {
        DiagnosticLog.write("menu Start Dictation clicked")
        startDictationAction()
    }

    @objc private func preferencesClicked(_ sender: Any?) {
        preferencesAction()
    }

    @objc private func previewOverlayClicked(_ sender: Any?) {
        let next: RecordingState
        switch recordingState.state {
        case .idle:
            next = .listening
        case .listening, .detectingSpeech:
            next = .formatting
        case .formatting, .transcribing, .injecting:
            next = .success
        case .success:
            next = .failure("Microphone Unavailable")
        case .failure:
            next = .idle
        }
        DiagnosticLog.write("Preview Overlay → \(next)")
        AppLogger.menuBar.debug("Overlay preview → \(String(describing: next), privacy: .public)")
        recordingState.update(next)
    }

    @objc private func aboutClicked(_ sender: Any?) {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: Constants.appName,
            .applicationVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        ])
    }

    @objc private func quitClicked(_ sender: Any?) {
        NSApp.terminate(nil)
    }

    // MARK: - State

    private func applyStatusAppearance(for state: RecordingState) {
        statusItem?.button?.toolTip = state == .idle
            ? "\(Constants.appName) — click for menu"
            : "\(Constants.appName) — \(state.statusText)"
    }

    // MARK: - Image

    private static func menuBarImage() -> NSImage {
        let config = NSImage.SymbolConfiguration(pointSize: 13, weight: .semibold)
        let names = ["mic.fill", "waveform", "ellipsis.bubble.fill"]
        for name in names {
            if let image = NSImage(systemSymbolName: name, accessibilityDescription: Constants.appName)?
                .withSymbolConfiguration(config) {
                image.isTemplate = true
                return image
            }
        }
        // Last resort: draw a simple filled circle so something always shows.
        let size = NSSize(width: 16, height: 16)
        let image = NSImage(size: size, flipped: false) { rect in
            NSColor.labelColor.setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 2, dy: 2)).fill()
            return true
        }
        image.isTemplate = true
        return image
    }
}
