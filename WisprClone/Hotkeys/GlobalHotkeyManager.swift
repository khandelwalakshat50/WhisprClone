import AppKit
import Carbon.HIToolbox

/// System-wide hotkey capture via `CGEventTap`, with an `NSEvent` fallback
/// when Input Monitoring has not been granted yet.
///
/// Supports:
/// 1. ⌘⇧Space to toggle recording
/// 2. Double-tap Left Command to begin, then tap it once to stop
final class GlobalHotkeyManager: @unchecked Sendable {
    enum Action: Equatable, Sendable {
        case toggle
        case begin
        case stop
    }

    typealias TriggerHandler = @Sendable (Action) -> Void

    private let onTrigger: TriggerHandler

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var tapThread: Thread?
    private var tapRunLoop: CFRunLoop?

    private var globalMonitor: Any?
    private var localMonitor: Any?

    private var lastLeftCommandTap: CFAbsoluteTime = 0
    private let doubleTapInterval: CFAbsoluteTime = 0.4
    private var leftCommandWasDown = false
    private var lastFire: (action: Action, time: CFAbsoluteTime)?

    init(onTrigger: @escaping TriggerHandler) {
        self.onTrigger = onTrigger
    }

    func start() {
        installNSEventFallbackOnMain()

        guard eventTap == nil, tapThread == nil else { return }
        let thread = Thread { [weak self] in
            self?.installTapAndRun()
        }
        thread.name = "WisprClone.HotkeyTap"
        thread.qualityOfService = .userInteractive
        tapThread = thread
        thread.start()
        AppLogger.hotkeys.info("Hotkey manager started (event tap + NSEvent fallback)")
    }

    func stop() {
        if let runLoop = tapRunLoop {
            CFRunLoopStop(runLoop)
        }
        if let source = runLoopSource {
            if let runLoop = tapRunLoop {
                CFRunLoopRemoveSource(runLoop, source, .commonModes)
            }
            runLoopSource = nil
        }
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            eventTap = nil
        }
        tapRunLoop = nil
        tapThread = nil

        if let globalMonitor {
            NSEvent.removeMonitor(globalMonitor)
            self.globalMonitor = nil
        }
        if let localMonitor {
            NSEvent.removeMonitor(localMonitor)
            self.localMonitor = nil
        }

        AppLogger.hotkeys.info("Hotkey manager stopped")
    }

    // MARK: - CGEventTap

    private func installTapAndRun() {
        let mask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.flagsChanged.rawValue)

        let callback: CGEventTapCallBack = { _, type, event, userInfo in
            guard let userInfo else { return Unmanaged.passUnretained(event) }
            let manager = Unmanaged<GlobalHotkeyManager>.fromOpaque(userInfo).takeUnretainedValue()
            return manager.handle(type: type, event: event)
        }

        // Prefer session tap; fall back to HID tap if unavailable.
        let tap =
            CGEvent.tapCreate(
                tap: .cgSessionEventTap,
                place: .headInsertEventTap,
                options: .defaultTap,
                eventsOfInterest: CGEventMask(mask),
                callback: callback,
                userInfo: Unmanaged.passUnretained(self).toOpaque()
            )
            ?? CGEvent.tapCreate(
                tap: .cghidEventTap,
                place: .headInsertEventTap,
                options: .defaultTap,
                eventsOfInterest: CGEventMask(mask),
                callback: callback,
                userInfo: Unmanaged.passUnretained(self).toOpaque()
            )

        guard let tap else {
            AppLogger.hotkeys.error("CGEventTap failed — using NSEvent fallback. Enable Input Monitoring.")
            return
        }

        eventTap = tap
        removeNSEventFallbackOnMain()
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        runLoopSource = source
        tapRunLoop = CFRunLoopGetCurrent()
        CFRunLoopAddSource(tapRunLoop, source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        AppLogger.hotkeys.info("CGEventTap installed")
        CFRunLoopRun()
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = eventTap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            return Unmanaged.passUnretained(event)
        }

        switch type {
        case .keyDown:
            if shouldTriggerShortcut(event) {
                fire(.toggle)
                return nil
            }
        case .flagsChanged:
            if let action = handleLeftCommand(
                keyCode: event.getIntegerValueField(.keyboardEventKeycode),
                commandDown: event.flags.contains(.maskCommand)
            ) {
                fire(action)
            }
        default:
            break
        }

        return Unmanaged.passUnretained(event)
    }

    // MARK: - NSEvent fallback (main thread)

    private func installNSEventFallbackOnMain() {
        let install = { [weak self] in
            guard let self else { return }
            guard self.globalMonitor == nil else { return }

            self.globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] event in
                self?.handleNSEvent(event)
            }
            self.localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] event in
                self?.handleNSEvent(event)
                return event
            }
            AppLogger.hotkeys.info("NSEvent monitors installed")
        }

        if Thread.isMainThread {
            install()
        } else {
            DispatchQueue.main.async(execute: install)
        }
    }

    private func handleNSEvent(_ event: NSEvent) {
        switch event.type {
        case .keyDown:
            if event.keyCode == UInt16(kVK_Space),
               event.modifierFlags.contains(.command),
               event.modifierFlags.contains(.shift),
               !event.modifierFlags.contains(.option),
               !event.modifierFlags.contains(.control) {
                fire(.toggle)
            }
        case .flagsChanged:
            let commandDown = event.modifierFlags.contains(.command)
            if let action = handleLeftCommand(keyCode: Int64(event.keyCode), commandDown: commandDown) {
                fire(action)
            }
        default:
            break
        }
    }

    // MARK: - Matching

    private func shouldTriggerShortcut(_ event: CGEvent) -> Bool {
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        guard keyCode == Int64(kVK_Space) else { return false }

        let flags = event.flags
        let hasCommand = flags.contains(.maskCommand)
        let hasShift = flags.contains(.maskShift)
        let hasOption = flags.contains(.maskAlternate)
        let hasControl = flags.contains(.maskControl)
        return hasCommand && hasShift && !hasOption && !hasControl
    }

    private func handleLeftCommand(keyCode: Int64, commandDown: Bool) -> Action? {
        guard keyCode == Int64(kVK_Command) else { return nil }

        let wasDown = leftCommandWasDown
        leftCommandWasDown = commandDown

        // Rising edge only.
        guard commandDown, !wasDown else { return nil }

        let now = CFAbsoluteTimeGetCurrent()
        if now - lastLeftCommandTap <= doubleTapInterval {
            lastLeftCommandTap = 0
            return .begin
        }

        lastLeftCommandTap = now
        return .stop
    }

    private func fire(_ action: Action) {
        // Suppress only near-simultaneous duplicates while the event tap
        // replaces the NSEvent fallback. A normal double-tap must get through.
        let now = CFAbsoluteTimeGetCurrent()
        if let lastFire,
           now - lastFire.time < 0.05,
           lastFire.action == action {
            return
        }
        lastFire = (action, now)
        AppLogger.hotkeys.info("Hotkey triggered: \(String(describing: action), privacy: .public)")
        onTrigger(action)
    }

    private func removeNSEventFallbackOnMain() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if let globalMonitor {
                NSEvent.removeMonitor(globalMonitor)
                self.globalMonitor = nil
            }
            if let localMonitor {
                NSEvent.removeMonitor(localMonitor)
                self.localMonitor = nil
            }
            AppLogger.hotkeys.info("CGEventTap active; NSEvent fallback removed")
        }
    }
}
