import AppKit

/// Borderless, non-activating HUD panel that never steals focus from the
/// frontmost application. Hosts SwiftUI content via `contentView`.
final class FloatingPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        isOpaque = false
        backgroundColor = .clear
        // AppKit window shadow is rectangular — soft glow comes from SwiftUI instead.
        hasShadow = false
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        isMovable = false
        isMovableByWindowBackground = false
        becomesKeyOnlyIfNeeded = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        worksWhenModal = true
        ignoresMouseEvents = false

        // Set floating BEFORE level — toggling `isFloatingPanel` resets level
        // to `.floating` (raw 3), which sits under normal app windows.
        isFloatingPanel = true
        applyFloatingAppearance()
    }

    func applyFloatingAppearance() {
        hidesOnDeactivate = false
        isFloatingPanel = true
        // MUST be after isFloatingPanel — that property resets level to 3.
        level = .screenSaver
        collectionBehavior = [
            .canJoinAllSpaces,
            .fullScreenAuxiliary,
            .ignoresCycle
        ]
    }
}
