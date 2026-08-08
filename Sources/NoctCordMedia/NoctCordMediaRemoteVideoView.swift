import Foundation

#if canImport(SwiftUI)
import SwiftUI
#endif

#if canImport(WebRTC)
@preconcurrency import WebRTC
#endif

#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

/// Controls how a remote video frame is fitted into its SwiftUI container.
public enum NoctCordMediaVideoContentMode: String, Codable, CaseIterable, Sendable {
    /// Shows the complete frame and preserves its aspect ratio. This is the
    /// default and is appropriate for screen sharing.
    case aspectFit

    /// Fills the container and crops the edges when the aspect ratios differ.
    case aspectFill
}

#if canImport(SwiftUI) && canImport(WebRTC)

/// A SwiftUI renderer for a received Noct Cord remote video track.
///
/// The view owns the platform renderer for its lifetime. It attaches the
/// current track during view updates, detaches a replaced track before
/// attaching the new one, and always detaches during dismantling. This keeps
/// remote screen-share frames out of stale views when a call is dismissed or
/// the active participant changes.
///
/// Use it directly from an application surface:
///
///     NoctCordMediaRemoteVideoView(
///         track: snapshot.remoteVideoTracks[participant],
///         contentMode: .aspectFit
///     )
///
/// A nil track produces an opaque black placeholder and does not create a
/// WebRTC renderer. The parent can therefore keep this view mounted while
/// signaling catches up without creating a renderer leak or a transient
/// invalid attachment.
public struct NoctCordMediaRemoteVideoView: View {
    private let track: NoctCordMediaRemoteVideoTrack?
    private let contentMode: NoctCordMediaVideoContentMode

    public init(
        track: NoctCordMediaRemoteVideoTrack?,
        contentMode: NoctCordMediaVideoContentMode = .aspectFit
    ) {
        self.track = track
        self.contentMode = contentMode
    }

    public var body: some View {
        NoctCordMediaRemoteVideoRepresentable(
            track: track,
            contentMode: contentMode
        )
        .background(Color.black)
        .clipped()
    }
}

#if os(iOS)

private struct NoctCordMediaRemoteVideoRepresentable: UIViewRepresentable {
    let track: NoctCordMediaRemoteVideoTrack?
    let contentMode: NoctCordMediaVideoContentMode

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> RTCMTLVideoView {
        let view = RTCMTLVideoView(frame: .zero)
        view.backgroundColor = .black
        view.isOpaque = true
        view.clipsToBounds = true
        view.videoContentMode = contentMode.uiKitValue
        context.coordinator.update(view: view, track: track)
        return view
    }

    func updateUIView(_ view: RTCMTLVideoView, context: Context) {
        view.videoContentMode = contentMode.uiKitValue
        context.coordinator.update(view: view, track: track)
    }

    static func dismantleUIView(_ view: RTCMTLVideoView, coordinator: Coordinator) {
        coordinator.detach(from: view)
    }

    final class Coordinator {
        private var attachedTrack: NoctCordMediaRemoteVideoTrack?

        func update(view: RTCMTLVideoView, track: NoctCordMediaRemoteVideoTrack?) {
            if let attachedTrack, attachedTrack !== track {
                try? attachedTrack.detach(from: view)
                self.attachedTrack = nil
            }

            guard let track, attachedTrack == nil else { return }
            guard track.isRenderable else { return }
            guard (try? track.attach(to: view)) != nil else { return }
            attachedTrack = track
        }

        func detach(from view: RTCMTLVideoView) {
            guard let attachedTrack else { return }
            try? attachedTrack.detach(from: view)
            self.attachedTrack = nil
        }
    }
}

private extension NoctCordMediaVideoContentMode {
    var uiKitValue: UIView.ContentMode {
        switch self {
        case .aspectFit: .scaleAspectFit
        case .aspectFill: .scaleAspectFill
        }
    }
}

#elseif os(macOS)

private struct NoctCordMediaRemoteVideoRepresentable: NSViewRepresentable {
    let track: NoctCordMediaRemoteVideoTrack?
    let contentMode: NoctCordMediaVideoContentMode

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> RTCMTLNSVideoView {
        let view = RTCMTLNSVideoView(frame: .zero)
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.black.cgColor
        context.coordinator.update(view: view, track: track)
        return view
    }

    func updateNSView(_ view: RTCMTLNSVideoView, context: Context) {
        _ = contentMode
        context.coordinator.update(view: view, track: track)
    }

    static func dismantleNSView(_ view: RTCMTLNSVideoView, coordinator: Coordinator) {
        coordinator.detach(from: view)
    }

    final class Coordinator {
        private var attachedTrack: NoctCordMediaRemoteVideoTrack?

        func update(view: RTCMTLNSVideoView, track: NoctCordMediaRemoteVideoTrack?) {
            if let attachedTrack, attachedTrack !== track {
                try? attachedTrack.detach(from: view)
                self.attachedTrack = nil
            }

            guard let track, attachedTrack == nil else { return }
            guard track.isRenderable else { return }
            guard (try? track.attach(to: view)) != nil else { return }
            attachedTrack = track
        }

        func detach(from view: RTCMTLNSVideoView) {
            guard let attachedTrack else { return }
            try? attachedTrack.detach(from: view)
            self.attachedTrack = nil
        }
    }
}

#endif

#else

#if canImport(SwiftUI)

/// Fallback view used by targets that do not link the WebRTC runtime. It
/// keeps applications compilable while making the missing runtime visible as
/// an intentionally empty renderer rather than pretending that media works.
public struct NoctCordMediaRemoteVideoView: View {
    private let track: NoctCordMediaRemoteVideoTrack?

    public init(
        track: NoctCordMediaRemoteVideoTrack?,
        contentMode: NoctCordMediaVideoContentMode = .aspectFit
    ) {
        self.track = track
        _ = contentMode
    }

    public var body: some View {
        Color.black
            .overlay {
                if track != nil {
                    Image(systemName: "video.slash")
                        .foregroundStyle(.secondary)
                }
            }
    }
}

#endif

#endif
