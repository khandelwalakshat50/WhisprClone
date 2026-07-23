import AppKit
import QuartzCore
import SwiftUI
import os

/// Persistent observable model for fluid SwiftUI state transitions.
/// Audio levels are normalized and smoothed before reaching the waveform.
@MainActor
final class OverlayPresentationModel: ObservableObject {
    @Published private(set) var state: RecordingState = .idle
    @Published private(set) var audioLevel: CGFloat = 0.08

    func update(state: RecordingState) {
        self.state = state
        if state != .listening && state != .detectingSpeech {
            audioLevel = 0.08
        }
    }

    func updateAudioLevel(rms: Float) {
        // Slightly more sensitive mapping so quiet laptop mics still move the ribbon.
        let normalized = min(max((CGFloat(rms) - 0.001) * 28, 0.04), 1)
        audioLevel = normalized > audioLevel
            ? audioLevel * 0.22 + normalized * 0.78
            : audioLevel * 0.75 + normalized * 0.25
    }

    func resetAudioLevel() {
        audioLevel = 0.08
    }
}

/// Owns the floating HUD: creates the `FloatingPanel`, hosts `StatusView`,
/// mirrors `RecordingStateStore`, and keeps the panel anchored to the active display.
@MainActor
final class OverlayManager {
    private let logger = Logger(subsystem: Constants.bundleIdentifier, category: "Overlay")
    private let recordingState: RecordingStateStore
    private let presentation: OverlayPresentationModel
    private let onStopRecording: () -> Void

    private var panel: FloatingPanel?
    private var hostingView: NSHostingView<StatusView>?
    private var stateObserverID: UUID?
    private var dismissTask: Task<Void, Never>?
    private var screenObserver: NSObjectProtocol?
    private var spaceObserver: NSObjectProtocol?
    private var isHiding = false

    init(
        recordingState: RecordingStateStore,
        presentation: OverlayPresentationModel,
        onStopRecording: @escaping () -> Void
    ) {
        self.recordingState = recordingState
        self.presentation = presentation
        self.onStopRecording = onStopRecording
    }

    func start() {
        guard panel == nil else { return }

        buildPanel()

        stateObserverID = recordingState.addObserver { [weak self] state in
            self?.handleStateChange(state)
        }

        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.repositionIfVisible()
            }
        }

        // When the user switches Spaces / enters full-screen, re-order so the
        // HUD follows onto the newly active Space instead of staying on Desktop.
        spaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.reassertOnActiveSpaceIfNeeded()
            }
        }

        handleStateChange(recordingState.state)
        logger.info("Overlay manager started")
        DiagnosticLog.write("OverlayManager.start complete, observers wired, panel=\(panel != nil)")
    }

    func stop() {
        dismissTask?.cancel()
        dismissTask = nil

        if let stateObserverID {
            recordingState.removeObserver(stateObserverID)
            self.stateObserverID = nil
        }

        if let screenObserver {
            NotificationCenter.default.removeObserver(screenObserver)
            self.screenObserver = nil
        }

        if let spaceObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(spaceObserver)
            self.spaceObserver = nil
        }

        panel?.orderOut(nil)
        panel = nil
        hostingView = nil
        logger.info("Overlay manager stopped")
    }

    // MARK: - State

    private func handleStateChange(_ state: RecordingState) {
        presentation.update(state: state)
        DiagnosticLog.write("overlay state → \(state)")

        guard state.shouldPresentOverlay else {
            dismissTask?.cancel()
            dismissTask = nil
            hidePanel()
            return
        }

        showPanel()

        switch state {
        case .success, .failure:
            scheduleAutoDismiss()
        default:
            dismissTask?.cancel()
            dismissTask = nil
        }
    }

    private func scheduleAutoDismiss() {
        dismissTask?.cancel()
        dismissTask = Task { [weak self] in
            let nanoseconds = UInt64(Constants.Overlay.autoDismissSeconds * 1_000_000_000)
            try? await Task.sleep(nanoseconds: nanoseconds)
            guard !Task.isCancelled else { return }
            self?.recordingState.update(.idle)
        }
    }

    // MARK: - Presentation

    private func buildPanel() {
        let panel = FloatingPanel(
            contentRect: NSRect(
                x: 0,
                y: 0,
                width: Constants.Overlay.width,
                height: Constants.Overlay.height
            )
        )

        let rootView = StatusView(model: presentation, onStopRecording: onStopRecording)
        let hosting = NSHostingView(rootView: rootView)
        hosting.frame = panel.contentView?.bounds ?? .zero
        hosting.autoresizingMask = [.width, .height]
        // Prevent a light system rect from showing behind the capsule.
        hosting.wantsLayer = true
        hosting.layer?.backgroundColor = NSColor.clear.cgColor
        panel.contentView = hosting

        self.panel = panel
        self.hostingView = hosting
    }

    private func showPanel() {
        if panel == nil {
            buildPanel()
        }
        guard let panel else {
            DiagnosticLog.write("overlay showPanel FAILED — panel nil")
            return
        }

        isHiding = false
        // Refresh SwiftUI root in case hosting view got stuck.
        let rootView = StatusView(model: presentation, onStopRecording: onStopRecording)
        if let hosting = hostingView {
            hosting.rootView = rootView
            hosting.wantsLayer = true
            hosting.layer?.backgroundColor = NSColor.clear.cgColor
        } else {
            let hosting = NSHostingView(rootView: rootView)
            hosting.frame = NSRect(origin: .zero, size: NSSize(width: Constants.Overlay.width, height: Constants.Overlay.height))
            hosting.autoresizingMask = [.width, .height]
            hosting.wantsLayer = true
            hosting.layer?.backgroundColor = NSColor.clear.cgColor
            panel.contentView = hosting
            hostingView = hosting
        }

        panel.applyFloatingAppearance()
        // Re-assert level after any AppKit side effects.
        panel.level = .screenSaver
        position(panel)
        panel.alphaValue = 1
        panel.orderFrontRegardless()

        DiagnosticLog.write(
            "overlay showPanel frame=\(NSStringFromRect(panel.frame)) visible=\(panel.isVisible) level=\(panel.level.rawValue) screen=\(activeScreen()?.localizedName ?? "?")"
        )
        logger.info("Overlay shown")
    }

    private func hidePanel() {
        guard let panel, panel.isVisible else { return }
        isHiding = true
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = Constants.Overlay.fadeDuration
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.4, 0, 0.7, 0.2)
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                guard self.isHiding, self.recordingState.state == .idle else { return }
                self.isHiding = false
                panel.orderOut(nil)
                panel.alphaValue = 1
                self.logger.debug("Overlay hidden")
            }
        })
    }

    private func reassertOnActiveSpaceIfNeeded() {
        guard recordingState.state.shouldPresentOverlay, let panel else { return }
        panel.applyFloatingAppearance()
        position(panel)
        panel.orderFrontRegardless()
    }

    private func repositionIfVisible() {
        guard let panel, panel.isVisible else { return }
        position(panel)
    }

    /// Centers the panel near the bottom of the display with keyboard focus.
    private func position(_ panel: FloatingPanel) {
        guard let screen = activeScreen() else { return }

        let visible = screen.visibleFrame
        let size = NSSize(width: Constants.Overlay.width, height: Constants.Overlay.height)
        let x = visible.midX - size.width / 2
        let y = visible.minY + Constants.Overlay.bottomMargin
        panel.setFrame(NSRect(origin: NSPoint(x: x, y: y), size: size), display: false)
    }

    /// Prefer the screen under the mouse, then the main screen.
    private func activeScreen() -> NSScreen? {
        let mouse = NSEvent.mouseLocation
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) {
            return screen
        }
        return NSScreen.main ?? NSScreen.screens.first
    }
}
