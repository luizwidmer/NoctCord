import Foundation

#if os(macOS) && canImport(ScreenCaptureKit)
@preconcurrency import ScreenCaptureKit

public struct NoctCordMacScreenCaptureKitSource: NoctCordScreenShareSource {
    public init() {}

    public func requestAccess() async throws -> NoctCordMediaPermissionState {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(
                false,
                onScreenWindowsOnly: true
            )
            return content.displays.isEmpty ? .restricted : .granted
        } catch {
            throw NoctCordMediaError.permissionUnavailable(.screenCapture)
        }
    }

    public func makeTrack() async throws -> NoctCordScreenShareTrack {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(
                false,
                onScreenWindowsOnly: true
            )
            guard let display = content.displays.first else {
                throw NoctCordMediaError.noCaptureSource
            }
            return NoctCordScreenShareTrack(
                trackID: try NoctCordMediaTrackID("sck-display-\(display.displayID)"),
                source: .display(identifier: display.displayID)
            )
        } catch let error as NoctCordMediaError {
            throw error
        } catch {
            throw NoctCordMediaError.noCaptureSource
        }
    }
}
#endif

#if os(iOS) && canImport(ReplayKit)
@preconcurrency import ReplayKit

/// This is the in-app ReplayKit path. It starts only while the host application is
/// active; background broadcast through Control Center still requires a separate
/// broadcast-upload extension, which NoctCordMedia does not provide.
public struct NoctCordReplayKitScreenShareSource: NoctCordScreenShareSource {
    public init() {}

    public func requestAccess() async throws -> NoctCordMediaPermissionState {
        guard RPScreenRecorder.shared().isAvailable else { return .unavailable }
        return .requiresUserAction
    }

    public func makeTrack() async throws -> NoctCordScreenShareTrack {
        guard RPScreenRecorder.shared().isAvailable else {
            throw NoctCordMediaError.permissionUnavailable(.screenCapture)
        }
        return NoctCordScreenShareTrack(
            trackID: try NoctCordMediaTrackID("replaykit-in-app"),
            source: .replayKitBroadcast
        )
    }
}
#endif

public struct NoctCordDescriptorScreenShareSource: NoctCordScreenShareSource {
    public let permission: NoctCordMediaPermissionState
    public let track: NoctCordScreenShareTrack

    public init(permission: NoctCordMediaPermissionState, track: NoctCordScreenShareTrack) {
        self.permission = permission
        self.track = track
    }

    public func requestAccess() async throws -> NoctCordMediaPermissionState { permission }

    public func makeTrack() async throws -> NoctCordScreenShareTrack {
        guard permission == .granted else {
            throw NoctCordMediaError.permissionUnavailable(.screenCapture)
        }
        return track
    }
}
