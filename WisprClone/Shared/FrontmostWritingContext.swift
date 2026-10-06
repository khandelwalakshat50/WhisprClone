import AppKit
import ApplicationServices
import Foundation

/// Resolved writing target for app-aware formatting (browser site ≠ bundle alone).
struct FrontmostWritingContext: Sendable {
    var bundleID: String?
    var appName: String?
    var windowTitle: String?
    /// Stable session key, e.g. `com.google.chrome|gmail` vs bare Chrome.
    var sessionKey: String
    /// Human label for prompts, e.g. `Gmail (Chrome)`.
    var displayLabel: String
    var profile: AppFormattingProfile
}

enum FrontmostWritingContextResolver {

    /// Local-only (no network / tokens). Safe to call at dictation start.
    static func resolve(for app: NSRunningApplication?) -> FrontmostWritingContext {
        let bundleID = app?.bundleIdentifier
        let appName = app?.localizedName
        let title = windowTitle(for: app)
        let site = detectSite(windowTitle: title, bundleID: bundleID, appName: appName)
        let profile = AppFormattingProfile.resolve(
            bundleID: bundleID,
            appName: appName,
            windowTitle: title,
            siteHint: site
        )
        let sessionKey = Self.sessionKey(bundleID: bundleID, site: site)
        let displayLabel = Self.displayLabel(appName: appName, site: site)
        return FrontmostWritingContext(
            bundleID: bundleID,
            appName: appName,
            windowTitle: title,
            sessionKey: sessionKey,
            displayLabel: displayLabel,
            profile: profile
        )
    }

    // MARK: - Window title

    private static func windowTitle(for app: NSRunningApplication?) -> String? {
        guard let app else { return nil }
        let pid = app.processIdentifier

        // Prefer Accessibility focused window title.
        let appElement = AXUIElementCreateApplication(pid)
        var focusedRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &focusedRef) == .success,
           let focused = focusedRef {
            var titleRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(
                (focused as! AXUIElement),
                kAXTitleAttribute as CFString,
                &titleRef
            ) == .success,
               let title = titleRef as? String,
               !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return title
            }
        }

        // Fallback: CGWindowList for this PID.
        guard let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]]
        else { return nil }

        let matches = info.filter { ($0[kCGWindowOwnerPID as String] as? pid_t) == pid }
        let best = matches
            .compactMap { entry -> (String, Int)? in
                guard let title = entry[kCGWindowName as String] as? String,
                      !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                else { return nil }
                let layer = entry[kCGWindowLayer as String] as? Int ?? 0
                return (title, layer)
            }
            .sorted { $0.1 < $1.1 }
            .first?
            .0
        return best
    }

    // MARK: - Site detection

    /// Coarse site/workspace from window title (Gmail in Chrome, Slack web, etc.).
    static func detectSite(windowTitle: String?, bundleID: String?, appName: String?) -> String? {
        let title = (windowTitle ?? "").lowercased()
        let bid = (bundleID ?? "").lowercased()
        let name = (appName ?? "").lowercased()

        if title.contains("gmail") || title.contains("mail.google") {
            return "gmail"
        }
        if title.contains("outlook") || title.contains("outlook.office") {
            return "mail"
        }
        if title.contains("slack") { return "slack" }
        if title.contains("notion") { return "notion" }
        if title.contains("obsidian") { return "obsidian" }
        if title.contains("chatgpt") || title.contains("claude.ai") { return "chat-ai" }
        if title.contains("docs.google") || title.contains("google docs") { return "docs" }
        if title.contains("github") { return "github" }

        // Native apps already identified by bundle — no extra site.
        if bid.contains("mail") || name == "mail" { return "mail" }
        if bid.contains("slack") { return "slack" }
        if bid.contains("notion") { return "notion" }
        if bid.contains("cursor") { return "cursor" }
        return nil
    }

    private static func sessionKey(bundleID: String?, site: String?) -> String {
        let base = (bundleID ?? "unknown").lowercased()
        if let site, !site.isEmpty {
            return "\(base)|\(site)"
        }
        return base
    }

    private static func displayLabel(appName: String?, site: String?) -> String {
        let app = appName ?? "App"
        guard let site else { return app }
        switch site {
        case "gmail": return "Gmail (\(app))"
        case "mail": return "Mail (\(app))"
        case "slack": return "Slack (\(app))"
        case "notion": return "Notion (\(app))"
        case "chat-ai": return "Chat AI (\(app))"
        case "docs": return "Docs (\(app))"
        case "cursor": return "Cursor"
        default: return "\(site) (\(app))"
        }
    }
}
