import ApplicationServices
import Foundation
import os

/// Fallback insertion via Accessibility: mutate the focused element's value.
struct AccessibilityInjection {
    private let logger = Logger(subsystem: Constants.bundleIdentifier, category: "AXInjection")

    func inject(_ text: String) throws {
        guard AXIsProcessTrusted() else {
            throw AppError.accessibilityPermissionDenied
        }

        let system = AXUIElementCreateSystemWide()
        var focusedRef: CFTypeRef?
        let focusStatus = AXUIElementCopyAttributeValue(
            system,
            kAXFocusedUIElementAttribute as CFString,
            &focusedRef
        )
        guard focusStatus == .success, let focusedRef else {
            throw AppError.injectionFailed("No focused element")
        }
        let focused = focusedRef as! AXUIElement

        var selectedRangeRef: CFTypeRef?
        let hasSelection = AXUIElementCopyAttributeValue(
            focused,
            kAXSelectedTextAttribute as CFString,
            &selectedRangeRef
        ) == .success

        if hasSelection {
            let setSelected = AXUIElementSetAttributeValue(
                focused,
                kAXSelectedTextAttribute as CFString,
                text as CFTypeRef
            )
            if setSelected == .success {
                logger.info("Injected via AX selected text")
                return
            }
        }

        var valueRef: CFTypeRef?
        let valueStatus = AXUIElementCopyAttributeValue(
            focused,
            kAXValueAttribute as CFString,
            &valueRef
        )

        if valueStatus == .success, let existing = valueRef as? String {
            let combined = existing + text
            let setStatus = AXUIElementSetAttributeValue(
                focused,
                kAXValueAttribute as CFString,
                combined as CFTypeRef
            )
            guard setStatus == .success else {
                throw AppError.injectionFailed("AX set value failed (\(setStatus.rawValue))")
            }
            logger.info("Injected via AX value append")
            return
        }

        let setStatus = AXUIElementSetAttributeValue(
            focused,
            kAXValueAttribute as CFString,
            text as CFTypeRef
        )
        guard setStatus == .success else {
            throw AppError.injectionFailed("AX insert failed (\(setStatus.rawValue))")
        }
        logger.info("Injected via AX value replace")
    }
}
