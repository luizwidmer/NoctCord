import Foundation

/// The adapter is intentionally conditional. Noct Cord's relay does not speak
/// LiveKit's room protocol, so linking a WebRTC SDK alone must not be treated as
/// proof that a relay-compatible media session exists.
public enum NoctCordWebRTCRuntimeLink: String, Sendable {
    case liveKitSDK
    case liveKitWebRTC
    case rawWebRTC
    case unavailable

    public static var current: Self {
#if canImport(LiveKit)
        return .liveKitSDK
#elseif canImport(LiveKitWebRTC)
        return .liveKitWebRTC
#elseif canImport(WebRTC)
        return .rawWebRTC
#else
        return .unavailable
#endif
    }
}

/// The platform-neutral representation used to map NoctCord ICE settings to
/// WebRTC's `RTCIceServer`. Keeping this mapping public makes configuration
/// inspection and tests possible without exposing WebRTC objects to callers.
public struct NoctCordWebRTCIceServerMapping: Equatable, Sendable {
    public let urls: [String]
    public let username: String?
    public let credential: String?

    public init(server: NoctCordMediaICEServer) {
        urls = server.urls
        username = server.username
        credential = server.credential
    }
}

public enum NoctCordWebRTCIceServerMapper {
    public static func map(
        _ servers: [NoctCordMediaICEServer]
    ) throws -> [NoctCordWebRTCIceServerMapping] {
        guard servers.count <= 8 else {
            throw NoctCordMediaError.invalidConfiguration(
                "room configuration supports at most 8 ICE servers"
            )
        }
        return servers.map(NoctCordWebRTCIceServerMapping.init(server:))
    }
}

#if canImport(LiveKit)
import LiveKit
#elseif canImport(LiveKitWebRTC)
import LiveKitWebRTC
#elseif canImport(WebRTC)
import WebRTC
#endif
