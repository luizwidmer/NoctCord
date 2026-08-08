import Foundation

#if canImport(WebRTC)
@preconcurrency import WebRTC
#endif

/// A safe bridge from a received WebRTC video track to a platform renderer.
/// SwiftUI callers can wrap WebRTC's `RTCMTLVideoView` (macOS/iOS) or
/// `RTCMTLNSVideoView` (macOS) in their own `NSViewRepresentable`/
/// `UIViewRepresentable`, then attach that renderer here.
public final class NoctCordMediaRemoteVideoTrack: @unchecked Sendable, Equatable {
    public let trackID: String

#if canImport(WebRTC)
    private let nativeTrack: RTCVideoTrack?

    internal init(track: RTCVideoTrack) {
        trackID = track.trackId
        nativeTrack = track
    }
#else
    internal init(trackID: String) {
        self.trackID = trackID
    }
#endif

    /// This initializer is used only by deterministic driver tests to model a
    /// track lifecycle without pretending that a native renderer exists.
    internal init(unavailableTrackID: String) throws {
        let normalized = unavailableTrackID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else {
            throw NoctCordMediaError.invalidConfiguration("remote video track id cannot be empty")
        }
        trackID = String(normalized.prefix(256))
#if canImport(WebRTC)
        nativeTrack = nil
#endif
    }

    public var isRenderable: Bool {
#if canImport(WebRTC)
        nativeTrack != nil
#else
        false
#endif
    }

    /// Attaches the received track to a WebRTC renderer. The `AnyObject`
    /// signature keeps NoctCordMedia usable on targets where WebRTC is not
    /// linked while still accepting every WebRTC `RTCVideoRenderer`.
    public func attach(to renderer: AnyObject) throws {
#if canImport(WebRTC)
        guard let nativeTrack else {
            throw NoctCordMediaError.runtimeUnavailable("remote video track has no native runtime")
        }
        guard let renderer = renderer as? RTCVideoRenderer else {
            throw NoctCordMediaError.invalidConfiguration(
                "renderer must conform to WebRTC RTCVideoRenderer"
            )
        }
        nativeTrack.add(renderer)
#else
        _ = renderer
        throw NoctCordMediaError.runtimeUnavailable(
            "stasel/WebRTC 150.0.0 is unavailable for this target"
        )
#endif
    }

    public func detach(from renderer: AnyObject) throws {
#if canImport(WebRTC)
        guard let nativeTrack else {
            throw NoctCordMediaError.runtimeUnavailable("remote video track has no native runtime")
        }
        guard let renderer = renderer as? RTCVideoRenderer else {
            throw NoctCordMediaError.invalidConfiguration(
                "renderer must conform to WebRTC RTCVideoRenderer"
            )
        }
        nativeTrack.remove(renderer)
#else
        _ = renderer
        throw NoctCordMediaError.runtimeUnavailable(
            "stasel/WebRTC 150.0.0 is unavailable for this target"
        )
#endif
    }

    public static func == (lhs: NoctCordMediaRemoteVideoTrack, rhs: NoctCordMediaRemoteVideoTrack) -> Bool {
        lhs.trackID == rhs.trackID
    }
}
