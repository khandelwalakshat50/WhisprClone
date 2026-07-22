import AppKit
import AVFoundation
import ApplicationServices
import Speech
import os

/// Central authorization surface for microphone, speech recognition,
/// Accessibility, and Input Monitoring.
@MainActor
final class PermissionManager {
    enum Permission: String, CaseIterable, Sendable {
        case microphone
        case speechRecognition
        case accessibility
        case inputMonitoring
    }

    enum Status: Equatable, Sendable {
        case granted
        case denied
        case notDetermined
        case restricted
    }

    private let logger = Logger(subsystem: Constants.bundleIdentifier, category: "Permissions")

    func status(for permission: Permission) -> Status {
        switch permission {
        case .microphone:
            return microphoneStatus()
        case .speechRecognition:
            return speechStatus()
        case .accessibility:
            return AXIsProcessTrusted() ? .granted : .denied
        case .inputMonitoring:
            return CGPreflightListenEventAccess() ? .granted : .denied
        }
    }

    /// Returns `true` when every permission required for a full dictation pass is granted.
    func allCriticalGranted() -> Bool {
        status(for: .microphone) == .granted
            && status(for: .accessibility) == .granted
            && status(for: .inputMonitoring) == .granted
    }

    // MARK: - Request

    func requestMicrophone() async -> Status {
        let current = microphoneStatus()
        if current == .granted { return .granted }
        let granted = await AVCaptureDevice.requestAccess(for: .audio)
        logger.info("Microphone permission → \(granted ? "granted" : "denied", privacy: .public)")
        return granted ? .granted : .denied
    }

    func requestSpeechRecognition() async -> Status {
        // The callback must be @Sendable: Speech invokes it on a background queue,
        // and a MainActor-inheriting closure would trip dispatch_assert_queue.
        let raw = await withCheckedContinuation { (continuation: CheckedContinuation<SFSpeechRecognizerAuthorizationStatus, Never>) in
            SFSpeechRecognizer.requestAuthorization { @Sendable status in
                continuation.resume(returning: status)
            }
        }

        let mapped: Status
        switch raw {
        case .authorized: mapped = .granted
        case .denied: mapped = .denied
        case .restricted: mapped = .restricted
        case .notDetermined: mapped = .notDetermined
        @unknown default: mapped = .denied
        }
        logger.info("Speech recognition permission → \(String(describing: mapped), privacy: .public)")
        return mapped
    }

    /// Prompts the Accessibility trust dialog when untrusted.
    @discardableResult
    func requestAccessibility() -> Status {
        // Use the literal key instead of `kAXTrustedCheckOptionPrompt` (not concurrency-safe under Swift 6).
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        let trusted = AXIsProcessTrustedWithOptions(options)
        logger.info("Accessibility permission → \(trusted ? "granted" : "denied", privacy: .public)")
        return trusted ? .granted : .denied
    }

    /// Requests Input Monitoring (required for `CGEventTap` listen access).
    @discardableResult
    func requestInputMonitoring() -> Status {
        let granted = CGRequestListenEventAccess()
        logger.info("Input Monitoring permission → \(granted ? "granted" : "denied", privacy: .public)")
        return granted ? .granted : .denied
    }

    // MARK: - System Settings deep links

    func openSystemSettings(for permission: Permission) {
        let urlString: String
        switch permission {
        case .microphone:
            urlString = "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"
        case .speechRecognition:
            urlString = "x-apple.systempreferences:com.apple.preference.security?Privacy_SpeechRecognition"
        case .accessibility:
            urlString = "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        case .inputMonitoring:
            urlString = "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent"
        }
        guard let url = URL(string: urlString) else { return }
        NSWorkspace.shared.open(url)
        logger.info("Opened System Settings for \(permission.rawValue, privacy: .public)")
    }

    // MARK: - Private

    private func microphoneStatus() -> Status {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return .granted
        case .denied: return .denied
        case .restricted: return .restricted
        case .notDetermined: return .notDetermined
        @unknown default: return .denied
        }
    }

    private func speechStatus() -> Status {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized: return .granted
        case .denied: return .denied
        case .restricted: return .restricted
        case .notDetermined: return .notDetermined
        @unknown default: return .denied
        }
    }
}
