import AppKit

/// Process entry point.
///
/// `NSApplication.delegate` is weak, so the delegate is retained here for
/// the lifetime of `app.run()`.
@main
enum AppMain {
    @MainActor
    private static var retainedDelegate: AppDelegate?

    static func main() {
        let app = NSApplication.shared

        // NSApplication is always started on the main thread.
        let delegate = MainActor.assumeIsolated {
            let delegate = AppDelegate()
            retainedDelegate = delegate
            return delegate
        }

        app.delegate = delegate

        #if DEBUG
        // Show a Dock icon while developing so it's obvious the app is running.
        // Release builds stay menu-bar-only (`.accessory` + LSUIElement).
        app.setActivationPolicy(.regular)
        #else
        app.setActivationPolicy(.accessory)
        #endif

        app.run()
    }
}
