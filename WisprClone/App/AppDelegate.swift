import AppKit

/// Application lifecycle owner. Owns menu bar, overlay, settings, and dictation pipeline.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var menuBarController: MenuBarController?
    private var overlayManager: OverlayManager?
    private var settingsController: SettingsWindowController?
    private var dictationCoordinator: DictationCoordinator?

    let recordingState = RecordingStateStore()
    let configurationStore = ConfigurationStore()
    let permissionManager = PermissionManager()
    let usageStore = LLMUsageStore()
    let historyStore = TranscriptHistoryStore()
    let overlayPresentation = OverlayPresentationModel()

    private var launchInstant: ContinuousClock.Instant?

    func applicationDidFinishLaunching(_ notification: Notification) {
        launchInstant = .now
        AppLogger.app.info("Application finished launching")
        DiagnosticLog.write("app launched from \(Bundle.main.bundlePath)")

        applyTheme(configurationStore.configuration.theme)

        // Menu bar FIRST so the icon always appears even if permissions/hotkeys fail.
        let controller = MenuBarController(
            recordingState: recordingState,
            preferencesAction: { [weak self] in
                self?.showPreferences()
            },
            startDictationAction: { [weak self] in
                self?.dictationCoordinator?.triggerFromMenu()
            }
        )
        controller.install()
        menuBarController = controller

        let overlay = OverlayManager(
            recordingState: recordingState,
            presentation: overlayPresentation,
            onStopRecording: { [weak self] in
                self?.dictationCoordinator?.triggerFromMenu()
            }
        )
        overlay.start()
        overlayManager = overlay
        DiagnosticLog.write("AppDelegate overlayManager retained")

        settingsController = SettingsWindowController(
            store: configurationStore,
            permissions: permissionManager,
            usageStore: usageStore,
            historyStore: historyStore,
            onPermissionsChanged: { [weak self] in
                self?.dictationCoordinator?.refreshHotkeys()
            }
        )

        let coordinator = DictationCoordinator(
            recordingState: recordingState,
            configurationStore: configurationStore,
            permissions: permissionManager,
            usageStore: usageStore,
            historyStore: historyStore,
            overlayPresentation: overlayPresentation
        )
        coordinator.start()
        dictationCoordinator = coordinator

        // Menu-bar apps look "broken" if nothing visible appears on launch.
        // Open Preferences so double-clicking the app always shows a window.
        DispatchQueue.main.async { [weak self] in
            self?.showPreferences()
            self?.nudgePermissionsIfNeeded()
        }

        if let launchInstant {
            let ms = AppLogger.elapsedMilliseconds(since: launchInstant)
            AppLogger.app.info("Startup complete in \(ms, format: .fixed(precision: 1)) ms")
        }
    }

    /// Finder / Dock re-click while already running.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showPreferences()
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        AppLogger.app.info("Application will terminate")
        dictationCoordinator?.stop()
        dictationCoordinator = nil
        overlayManager?.stop()
        overlayManager = nil
        menuBarController?.tearDown()
        menuBarController = nil
        settingsController = nil
        configurationStore.saveAPIKeysFromUI()
    }

    private func showPreferences() {
        settingsController?.show()
    }

    private func nudgePermissionsIfNeeded() {
        let needsInput = permissionManager.status(for: .inputMonitoring) != .granted
        let needsAX = permissionManager.status(for: .accessibility) != .granted
        guard needsInput || needsAX else { return }

        let alert = NSAlert()
        alert.messageText = "Permissions Needed"
        alert.informativeText = """
        WisprClone needs these Mac permissions to work:

        • Input Monitoring — for ⌘⇧Space
        • Accessibility — to paste into other apps
        • Microphone — to hear you (asked when you dictate)

        Click “Open Settings”, enable WisprClone (or Xcode), then quit and run the app again.
        """
        alert.addButton(withTitle: "Open Settings")
        alert.addButton(withTitle: "Later")
        NSApp.activate(ignoringOtherApps: true)
        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            if needsInput {
                permissionManager.openSystemSettings(for: .inputMonitoring)
            } else {
                permissionManager.openSystemSettings(for: .accessibility)
            }
            settingsController?.show()
        }
    }

    private func applyTheme(_ theme: AppTheme) {
        switch theme {
        case .system:
            NSApp.appearance = nil
        case .light:
            NSApp.appearance = NSAppearance(named: .aqua)
        case .dark:
            NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }
}

/// Observable holder for the single app-wide `RecordingState`.
@MainActor
final class RecordingStateStore {
    private(set) var state: RecordingState = .idle {
        didSet {
            guard state != oldValue else { return }
            DiagnosticLog.write("RecordingStateStore \(oldValue) → \(state) observers=\(observers.count)")
            for observer in observers.values {
                observer(state)
            }
        }
    }

    private var observers: [UUID: (RecordingState) -> Void] = [:]

    @discardableResult
    func addObserver(_ handler: @escaping (RecordingState) -> Void) -> UUID {
        let id = UUID()
        observers[id] = handler
        DiagnosticLog.write("RecordingStateStore addObserver → \(observers.count) total")
        return id
    }

    func removeObserver(_ id: UUID) {
        observers.removeValue(forKey: id)
    }

    func update(_ newState: RecordingState) {
        state = newState
    }
}
