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
        hasShadow = true
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        isMovable = false
        isMovableByWindowBackground = false
        becomesKeyOnlyIfNeeded = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        worksWhenModal = true

        applyFloatingAppearance()

        // The non-activating panel preserves focus in the target app while
        // allowing the compact stop control to remain tactile.
        ignoresMouseEvents = false
    }

    /// Re-assert Space membership. Must be called every time the panel is
    /// ordered front — otherwise macOS can leave it stranded on the Desktop
    /// Space while Chrome (or any full-screen app) owns the active Space.
    func applyFloatingAppearance() {
        // Do NOT use `.stationary` — it pins the window to the Space where it
        // was created (usually Desktop), which is exactly the "only on desktop"
        // failure mode.
        //
        // `.moveToActiveSpace` pulls the HUD onto whatever Space is frontmost
        // when we order front, including full-screen Spaces.
        // `.fullScreenAuxiliary` is required to appear over a full-screen app.
        // `.canJoinAllSpaces` keeps it visible across normal Spaces too.
        collectionBehavior = [
            .canJoinAllSpaces,
            .moveToActiveSpace,
            .fullScreenAuxiliary,
            .ignoresCycle,
            .transient
        ]
        level = .screenSaver
    }
}
