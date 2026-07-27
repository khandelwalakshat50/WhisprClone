import AppKit
import Carbon.HIToolbox

/// System-wide hotkey capture via `CGEventTap`, with an `NSEvent` fallback
/// when Input Monitoring has not been granted yet.
///
/// Supports:
/// 1. ⌘⇧Space to toggle recording
/// 2. Double-tap Fn to begin; single-tap Fn to stop
///
/// Fn single-tap is **deferred** so a double-tap can cancel the pending stop
/// and fire begin instead (avoids “first tap = stop, miss second = no UI”).
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

    /// Window to recognize a second Fn tap as “double”.
    private let doubleTapInterval: CFAbsoluteTime = 0.45
    private var lastFire: (action: Action, time: CFAbsoluteTime)?

    private var lastFnTap: CFAbsoluteTime = 0
    private var fnWasDown = false
    private var pendingStopWorkItem: DispatchWorkItem?
    private let fnQueue = DispatchQueue(label: "\(Constants.bundleIdentifier).fn-hotkey")
    private static let fnKeyCode = Int64(kVK_Function) // 63

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
        fnQueue.sync {
            pendingStopWorkItem?.cancel()
            pendingStopWorkItem = nil
        }

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
        // Keep NSEvent monitors as a backup — Input Monitoring taps can drop
        // modifier-only events (Fn) on some MacBooks.
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        runLoopSource = source
        tapRunLoop = CFRunLoopGetCurrent()
        CFRunLoopAddSource(tapRunLoop, source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        AppLogger.hotkeys.info("CGEventTap installed (NSEvent fallback kept)")
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
            let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
            // Some Macs deliver Fn as flags-only with keycode 0 / other codes.
            // Prefer SecondaryFn flag; also accept the dedicated Fn keycode.
            let fnDown = event.flags.contains(.maskSecondaryFn)
            if keyCode == Self.fnKeyCode || fnDown || fnWasDown {
                handleFnEdge(fnDown: fnDown, sourceKeyCode: keyCode)
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
            let fnDown = event.modifierFlags.contains(.function)
            if Int64(event.keyCode) == Self.fnKeyCode || fnDown || fnWasDown {
                handleFnEdge(fnDown: fnDown, sourceKeyCode: Int64(event.keyCode))
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

    /// Rising edge: schedule stop; second rising edge within the window → begin.
    private func handleFnEdge(fnDown: Bool, sourceKeyCode: Int64) {
        let previouslyDown = fnWasDown
        fnWasDown = fnDown

        // Rising edge only.
        guard fnDown, !previouslyDown else { return }

        fnQueue.async { [weak self] in
            guard let self else { return }
            let now = CFAbsoluteTimeGetCurrent()

            if self.lastFnTap > 0, now - self.lastFnTap <= self.doubleTapInterval {
                // Double-tap — cancel pending single-tap stop and begin.
                self.pendingStopWorkItem?.cancel()
                self.pendingStopWorkItem = nil
                self.lastFnTap = 0
                DiagnosticLog.write("fn double-tap → begin (keycode=\(sourceKeyCode))")
                self.fire(.begin)
                return
            }

            self.lastFnTap = now
            self.pendingStopWorkItem?.cancel()
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                // Only fire stop if no second tap cleared lastFnTap.
                guard self.lastFnTap > 0 else { return }
                self.lastFnTap = 0
                self.pendingStopWorkItem = nil
                DiagnosticLog.write("fn single-tap → stop")
                self.fire(.stop)
            }
            self.pendingStopWorkItem = work
            self.fnQueue.asyncAfter(
                deadline: .now() + self.doubleTapInterval,
                execute: work
            )
        }
    }

    private func fire(_ action: Action) {
        // Debounce near-simultaneous duplicates from event-tap + NSEvent.
        let now = CFAbsoluteTimeGetCurrent()
        if let lastFire,
           now - lastFire.time < 0.12,
           lastFire.action == action {
            return
        }
        // begin should win over a stop that raced from the other monitor.
        if action == .begin,
           let lastFire,
           lastFire.action == .stop,
           now - lastFire.time < 0.2 {
            // Still allow begin.
        } else if action == .stop,
                  let lastFire,
                  lastFire.action == .begin,
                  now - lastFire.time < 0.2 {
            return
        }

        lastFire = (action, now)
        AppLogger.hotkeys.info("Hotkey triggered: \(String(describing: action), privacy: .public)")
        onTrigger(action)
    }
}
