import Foundation

public enum NoctCordMediaError: Error, Equatable, Sendable {
    case invalidConfiguration(String)
    case invalidEnvelope(String)
    case invalidState(String)
    case permissionDenied(NoctCordMediaPermission)
    case permissionUnavailable(NoctCordMediaPermission)
    case noCaptureSource
    case runtimeUnavailable(String)
    case transportFailure(String)
}

public struct NoctCordMediaRoomID: Codable, Hashable, Sendable, ExpressibleByStringLiteral {
    public let rawValue: String

    public init(_ rawValue: String) throws {
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.isValid(value), value == rawValue else {
            throw NoctCordMediaError.invalidConfiguration("room id must be 1-256 UTF-8 bytes")
        }
        self.rawValue = value
    }

    public var isStructurallyValid: Bool { Self.isValid(rawValue) }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(values.decode(String.self, forKey: .rawValue))
    }

    private enum CodingKeys: String, CodingKey { case rawValue }

    private static func isValid(_ value: String) -> Bool {
        !value.isEmpty
            && value == value.trimmingCharacters(in: .whitespacesAndNewlines)
            && value.utf8.count <= 256
            && !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    }

    public init(stringLiteral value: String) {
        self.rawValue = value
    }
}

public struct NoctCordMediaParticipantID: Codable, Hashable, Sendable, ExpressibleByStringLiteral {
    public let rawValue: String

    public init(_ rawValue: String) throws {
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.isValid(value), value == rawValue else {
            throw NoctCordMediaError.invalidConfiguration("participant id must be 1-256 UTF-8 bytes")
        }
        self.rawValue = value
    }

    public var isStructurallyValid: Bool { Self.isValid(rawValue) }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(values.decode(String.self, forKey: .rawValue))
    }

    private enum CodingKeys: String, CodingKey { case rawValue }

    private static func isValid(_ value: String) -> Bool {
        !value.isEmpty
            && value == value.trimmingCharacters(in: .whitespacesAndNewlines)
            && value.utf8.count <= 256
            && !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    }

    public init(stringLiteral value: String) {
        self.rawValue = value
    }
}

public enum NoctCordMediaPermission: String, Codable, CaseIterable, Hashable, Sendable {
    case microphone
    case screenCapture
}

/// An operator- or user-provided ICE service. Only STUN and TURN URLs are
/// accepted; an empty room configuration intentionally remains LAN-only.
public struct NoctCordMediaICEServer: Codable, Equatable, Sendable {
    public let urls: [String]
    public let username: String?
    public let credential: String?

    public init(
        urls: [String],
        username: String? = nil,
        credential: String? = nil
    ) throws {
        let normalizedURLs = try Self.validateURLs(urls)
        let normalizedUsername = Self.normalizeOptional(username)
        let normalizedCredential = Self.normalizeOptional(credential)
        guard normalizedUsername == nil || normalizedCredential != nil else {
            throw NoctCordMediaError.invalidConfiguration(
                "ICE username requires a credential"
            )
        }
        guard normalizedCredential == nil || normalizedUsername != nil else {
            throw NoctCordMediaError.invalidConfiguration(
                "ICE credential requires a username"
            )
        }
        self.urls = normalizedURLs
        self.username = normalizedUsername
        self.credential = normalizedCredential
    }

    public init(
        url: String,
        username: String? = nil,
        credential: String? = nil
    ) throws {
        try self.init(urls: [url], username: username, credential: credential)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            urls: container.decode([String].self, forKey: .urls),
            username: container.decodeIfPresent(String.self, forKey: .username),
            credential: container.decodeIfPresent(String.self, forKey: .credential)
        )
    }

    private enum CodingKeys: String, CodingKey {
        case urls
        case username
        case credential
    }

    private static func normalizeOptional(_ value: String?) -> String? {
        guard let value else { return nil }
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty ? nil : String(normalized.prefix(4_096))
    }

    private static func validateURLs(_ urls: [String]) throws -> [String] {
        guard !urls.isEmpty, urls.count <= 8 else {
            throw NoctCordMediaError.invalidConfiguration(
                "ICE server must contain 1-8 URLs"
            )
        }
        var normalized: [String] = []
        for rawURL in urls {
            let value = rawURL.trimmingCharacters(in: .whitespacesAndNewlines)
            guard value.utf8.count <= 2_048,
                  !value.isEmpty,
                  value.rangeOfCharacter(from: .whitespacesAndNewlines) == nil,
                  let schemeSeparator = value.firstIndex(of: ":") else {
                throw NoctCordMediaError.invalidConfiguration(
                    "ICE URL must be a valid stun/stuns/turn/turns URL without embedded credentials"
                )
            }
            let scheme = value[..<schemeSeparator].lowercased()
            guard ["stun", "stuns", "turn", "turns"].contains(scheme) else {
                throw NoctCordMediaError.invalidConfiguration(
                    "ICE URL must use stun, stuns, turn, or turns"
                )
            }
            let remainder = value[value.index(after: schemeSeparator)...]
            let authorityAndQuery = remainder.hasPrefix("//")
                ? remainder.dropFirst(2)
                : remainder[remainder.startIndex...]
            let authority = authorityAndQuery.split(
                maxSplits: 1,
                omittingEmptySubsequences: true,
                whereSeparator: { $0 == "?" || $0 == "#" }
            ).first.map(String.init) ?? ""
            guard !authority.isEmpty,
                  !authority.contains("@"),
                  !authority.contains("/"),
                  let host = URL(string: "https://\(authority)")?.host,
                  !host.isEmpty,
                  !authorityAndQuery.contains("#") else {
                throw NoctCordMediaError.invalidConfiguration(
                    "ICE URL must be a valid stun/stuns/turn/turns URL without embedded credentials"
                )
            }
            let canonical = String(value)
            guard !normalized.contains(canonical) else { continue }
            normalized.append(canonical)
        }
        guard !normalized.isEmpty else {
            throw NoctCordMediaError.invalidConfiguration("ICE URL list cannot be empty")
        }
        return normalized
    }
}

public enum NoctCordMediaPermissionState: String, Codable, Equatable, Sendable {
    case granted
    case denied
    case restricted
    case notDetermined
    case requiresUserAction
    case unavailable
}

public struct NoctCordMediaPermissionSnapshot: Codable, Equatable, Sendable {
    public let microphone: NoctCordMediaPermissionState
    public let screenCapture: NoctCordMediaPermissionState

    public init(
        microphone: NoctCordMediaPermissionState = .notDetermined,
        screenCapture: NoctCordMediaPermissionState = .notDetermined
    ) {
        self.microphone = microphone
        self.screenCapture = screenCapture
    }

    public subscript(permission: NoctCordMediaPermission) -> NoctCordMediaPermissionState {
        switch permission {
        case .microphone: microphone
        case .screenCapture: screenCapture
        }
    }
}

public protocol NoctCordMediaPermissionProvider: Sendable {
    func request(_ permissions: Set<NoctCordMediaPermission>) async throws -> NoctCordMediaPermissionSnapshot
}

public struct NoctCordFixedPermissionProvider: NoctCordMediaPermissionProvider {
    public let snapshot: NoctCordMediaPermissionSnapshot

    public init(snapshot: NoctCordMediaPermissionSnapshot) {
        self.snapshot = snapshot
    }

    public func request(_ permissions: Set<NoctCordMediaPermission>) async throws -> NoctCordMediaPermissionSnapshot {
        for permission in permissions {
            switch snapshot[permission] {
            case .granted: break
            case .denied: throw NoctCordMediaError.permissionDenied(permission)
            default: throw NoctCordMediaError.permissionUnavailable(permission)
            }
        }
        return snapshot
    }
}

public struct NoctCordUnavailablePermissionProvider: NoctCordMediaPermissionProvider {
    public init() {}

    public func request(_ permissions: Set<NoctCordMediaPermission>) async throws -> NoctCordMediaPermissionSnapshot {
        guard let permission = permissions.sorted(by: { $0.rawValue < $1.rawValue }).first else {
            return NoctCordMediaPermissionSnapshot()
        }
        throw NoctCordMediaError.permissionUnavailable(permission)
    }
}

public enum NoctCordMediaTrackKind: String, Codable, Equatable, Sendable {
    case microphone
    case screenShare
}

public struct NoctCordMediaTrackID: Codable, Hashable, Sendable {
    public let rawValue: String

    public init(_ rawValue: String) throws {
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.isValid(value), value == rawValue else {
            throw NoctCordMediaError.invalidConfiguration("track id must be 1-256 UTF-8 bytes")
        }
        self.rawValue = value
    }

    public var isStructurallyValid: Bool { Self.isValid(rawValue) }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(values.decode(String.self, forKey: .rawValue))
    }

    private enum CodingKeys: String, CodingKey { case rawValue }

    private static func isValid(_ value: String) -> Bool {
        !value.isEmpty
            && value == value.trimmingCharacters(in: .whitespacesAndNewlines)
            && value.utf8.count <= 256
            && !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    }
}

public enum NoctCordScreenShareSourceDescriptor: Codable, Equatable, Sendable {
    case display(identifier: UInt32)
    case replayKitBroadcast
}

public struct NoctCordScreenShareTrack: Codable, Equatable, Sendable {
    public let trackID: NoctCordMediaTrackID
    public let source: NoctCordScreenShareSourceDescriptor
    public let cameraIndependent: Bool

    public init(
        trackID: NoctCordMediaTrackID,
        source: NoctCordScreenShareSourceDescriptor,
        cameraIndependent: Bool = true
    ) {
        self.trackID = trackID
        self.source = source
        self.cameraIndependent = cameraIndependent
    }
}

public protocol NoctCordScreenShareSource: Sendable {
    func requestAccess() async throws -> NoctCordMediaPermissionState
    func makeTrack() async throws -> NoctCordScreenShareTrack
}

public struct NoctCordMediaParticipant: Codable, Equatable, Sendable {
    public let id: NoctCordMediaParticipantID
    public let displayName: String

    public init(id: NoctCordMediaParticipantID, displayName: String = "") {
        self.id = id
        self.displayName = String(displayName.prefix(128))
    }
}

public struct NoctCordMediaRoomConfiguration: Codable, Equatable, Sendable {
    public let roomID: NoctCordMediaRoomID
    public let participant: NoctCordMediaParticipant
    public let wantsMicrophone: Bool
    public let iceServers: [NoctCordMediaICEServer]

    public init(
        roomID: NoctCordMediaRoomID,
        participant: NoctCordMediaParticipant,
        wantsMicrophone: Bool = true,
        iceServers: [NoctCordMediaICEServer] = []
    ) {
        self.roomID = roomID
        self.participant = participant
        self.wantsMicrophone = wantsMicrophone
        self.iceServers = iceServers
    }

    public func validate() throws {
        guard iceServers.count <= 8 else {
            throw NoctCordMediaError.invalidConfiguration(
                "room configuration supports at most 8 ICE servers"
            )
        }
    }
}

public enum NoctCordMediaRoomState: Equatable, Sendable {
    case idle
    case joining
    case joined
    case leaving
    case left
    case failed(NoctCordMediaError)
}

public struct NoctCordMediaRoomSnapshot: Equatable, Sendable {
    public let state: NoctCordMediaRoomState
    public let localParticipant: NoctCordMediaParticipant
    public let participants: [NoctCordMediaParticipant]
    public let microphoneMuted: Bool
    public let deafened: Bool
    public let remoteMicrophoneEnabled: [NoctCordMediaParticipantID: Bool]
    public let remoteDeafened: [NoctCordMediaParticipantID: Bool]
    public let remoteConnectionStates: [NoctCordMediaParticipantID: String]
    public let localScreenShare: NoctCordScreenShareTrack?
    public let remoteScreenShares: [NoctCordMediaParticipantID: NoctCordScreenShareTrack]
    public let remoteVideoTracks: [NoctCordMediaParticipantID: NoctCordMediaRemoteVideoTrack]
    public let screenShareError: NoctCordMediaError?
    public let lastReceivedSequence: [NoctCordMediaParticipantID: UInt64]

    public init(
        state: NoctCordMediaRoomState,
        localParticipant: NoctCordMediaParticipant,
        participants: [NoctCordMediaParticipant],
        microphoneMuted: Bool,
        deafened: Bool,
        remoteMicrophoneEnabled: [NoctCordMediaParticipantID: Bool],
        remoteDeafened: [NoctCordMediaParticipantID: Bool],
        remoteConnectionStates: [NoctCordMediaParticipantID: String],
        localScreenShare: NoctCordScreenShareTrack?,
        remoteScreenShares: [NoctCordMediaParticipantID: NoctCordScreenShareTrack],
        remoteVideoTracks: [NoctCordMediaParticipantID: NoctCordMediaRemoteVideoTrack] = [:],
        screenShareError: NoctCordMediaError? = nil,
        lastReceivedSequence: [NoctCordMediaParticipantID: UInt64]
    ) {
        self.state = state
        self.localParticipant = localParticipant
        self.participants = participants.sorted { $0.id.rawValue < $1.id.rawValue }
        self.microphoneMuted = microphoneMuted
        self.deafened = deafened
        self.remoteMicrophoneEnabled = remoteMicrophoneEnabled
        self.remoteDeafened = remoteDeafened
        self.remoteConnectionStates = remoteConnectionStates
        self.localScreenShare = localScreenShare
        self.remoteScreenShares = remoteScreenShares
        self.remoteVideoTracks = remoteVideoTracks
        self.screenShareError = screenShareError
        self.lastReceivedSequence = lastReceivedSequence
    }
}
