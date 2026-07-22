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
        let normalized = min(max((CGFloat(rms) - 0.003) * 22, 0.04), 1)
        // Fast attack, gentle decay gives the ribbon a natural, confident feel.
        audioLevel = normalized > audioLevel
            ? audioLevel * 0.28 + normalized * 0.72
            : audioLevel * 0.82 + normalized * 0.18
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
        panel.contentView = hosting

        self.panel = panel
        self.hostingView = hosting
    }

    private func showPanel() {
        // Recreate if somehow torn down; also ensures a fresh Space attachment
        // after long idle periods.
        if panel == nil {
            buildPanel()
        }
        guard let panel else { return }

        let wasHiding = isHiding
        isHiding = false

        // Force macOS to re-evaluate which Space owns this window.
        // orderOut → reconfigure → orderFrontRegardless is the reliable way to
        // leave the Desktop Space and join a full-screen Chrome Space.
        if panel.isVisible && wasHiding == false && panel.alphaValue >= 0.95 {
            panel.applyFloatingAppearance()
            position(panel)
            panel.orderFrontRegardless()
            return
        }

        panel.orderOut(nil)
        panel.applyFloatingAppearance()
        position(panel)

        let targetFrame = panel.frame
        let initialFrame = targetFrame.insetBy(dx: 3, dy: 2)
        panel.setFrame(initialFrame, display: false)
        panel.alphaValue = 0
        panel.orderFrontRegardless()

        NSAnimationContext.runAnimationGroup { context in
            context.duration = Constants.Overlay.fadeDuration
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.16, 1, 0.3, 1)
            panel.animator().alphaValue = 1
            panel.animator().setFrame(targetFrame, display: true)
        }
        logger.debug("Overlay shown on \(self.activeScreen()?.localizedName ?? "unknown", privacy: .public)")
    }

    private func hidePanel() {
        guard let panel, panel.isVisible else { return }
        let originalFrame = panel.frame
        let dissolvedFrame = originalFrame.insetBy(dx: 4, dy: 2)
        isHiding = true
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = Constants.Overlay.fadeDuration
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.4, 0, 0.7, 0.2)
            panel.animator().alphaValue = 0
            panel.animator().setFrame(dissolvedFrame, display: true)
        }, completionHandler: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                guard self.isHiding, self.recordingState.state == .idle else { return }
                self.isHiding = false
                panel.orderOut(nil)
                panel.alphaValue = 1
                panel.setFrame(originalFrame, display: false)
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

    /// Prefer the screen under the mouse (where the user is working), then main.
    private func activeScreen() -> NSScreen? {
        let mouse = NSEvent.mouseLocation
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) {
            return screen
        }
        return NSScreen.main ?? NSScreen.screens.first
    }
}
