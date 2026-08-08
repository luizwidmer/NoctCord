import Foundation

#if canImport(AVFoundation)
@preconcurrency import AVFoundation

/// Uses the host OS microphone permission state. Screen capture remains owned by
/// the platform-specific screen-share source because macOS and iOS expose it
/// through different APIs and user flows.
public struct NoctCordAVAudioPermissionProvider: NoctCordMediaPermissionProvider {
    public init() {}

    public func request(_ permissions: Set<NoctCordMediaPermission>) async throws -> NoctCordMediaPermissionSnapshot {
        var microphone: NoctCordMediaPermissionState = .notDetermined
        if permissions.contains(.microphone) {
            microphone = await requestMicrophone()
            guard microphone == .granted else {
                throw microphone == .denied
                    ? NoctCordMediaError.permissionDenied(.microphone)
                    : NoctCordMediaError.permissionUnavailable(.microphone)
            }
        }
        return NoctCordMediaPermissionSnapshot(microphone: microphone)
    }

    private func requestMicrophone() async -> NoctCordMediaPermissionState {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        switch status {
        case .authorized:
            return .granted
        case .denied:
            return .denied
        case .restricted:
            return .restricted
        case .notDetermined:
            let granted = await withCheckedContinuation { continuation in
                AVCaptureDevice.requestAccess(for: .audio) { granted in
                    continuation.resume(returning: granted)
                }
            }
            return granted ? .granted : .denied
        @unknown default:
            return .unavailable
        }
    }
}
#endif
