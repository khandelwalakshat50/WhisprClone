import AVFoundation
import os

/// Requests and reports microphone authorization for the audio pipeline.
enum AudioPermissions {
    static func status() -> PermissionManager.Status {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return .granted
        case .denied: return .denied
        case .restricted: return .restricted
        case .notDetermined: return .notDetermined
        @unknown default: return .denied
        }
    }

    static func request() async -> PermissionManager.Status {
        let granted = await AVCaptureDevice.requestAccess(for: .audio)
        return granted ? .granted : .denied
    }
}
