import CryptoKit
import Foundation
@preconcurrency import NoctweaveCore

/// Algorithms and envelope metadata describe the encrypted object only. They
/// do not contain, derive, or identify the attachment plaintext.
public enum NoctCordAttachmentDigestAlgorithm: String, Codable, Equatable, Sendable {
    case sha256
}

public enum NoctCordAttachmentEncryptionScheme: String, Codable, Equatable, Sendable {
    case aeadChunkedV1
}

public struct NoctCordAttachmentEncryptionMetadataV1: Codable, Equatable, Sendable {
    public static let version = 1

    public let version: Int
    /// An opaque key reference. It is not a key and is never interpreted by a relay.
    public let keyID: Data
    /// The per-attachment content key. This field is inside the group-encrypted
    /// event and is therefore never visible to the relay; clients use it to
    /// decrypt the blob after fetching it by opaque blob ID.
    public let contentKey: Data
    /// A per-object nonce or nonce prefix for the group-delivered content key.
    public let nonce: Data
    public let scheme: NoctCordAttachmentEncryptionScheme
    public let chunkSize: UInt32
    public let authenticationTagBytes: UInt8

    public init(
        version: Int = Self.version,
        keyID: Data,
        contentKey: Data,
        nonce: Data,
        scheme: NoctCordAttachmentEncryptionScheme = .aeadChunkedV1,
        chunkSize: UInt32 = 64 * 1024,
        authenticationTagBytes: UInt8 = 16
    ) {
        self.version = version
        self.keyID = keyID
        self.contentKey = contentKey
        self.nonce = nonce
        self.scheme = scheme
        self.chunkSize = chunkSize
        self.authenticationTagBytes = authenticationTagBytes
    }

    public var isStructurallyValid: Bool {
        version == Self.version
            && keyID.count >= 16
            && keyID.count <= 128
            && contentKey.count == 32
            && nonce.count >= 12
            && nonce.count <= 32
            && chunkSize >= 4 * 1024
            && chunkSize <= 1024 * 1024
            && chunkSize.isMultiple(of: 1024)
            && authenticationTagBytes == 16
    }
}

/// A channel attachment announcement. The manifest intentionally has no
/// filename, path, or other plaintext file metadata. The blob ID is opaque to
/// both this layer and the relay.
public struct NoctCordAttachmentManifestV1: Codable, Equatable, Sendable {
    public static let version = 1

    public let version: Int
    public let blobID: Data
    /// Opaque capability required to access the relay media object. It is
    /// distributed only inside the group-encrypted attachment event.
    public let blobCapability: Data
    public let mediaType: String
    public let size: UInt64
    public let digestAlgorithm: NoctCordAttachmentDigestAlgorithm
    public let digest: Data
    public let expiresAt: Date
    public let encryption: NoctCordAttachmentEncryptionMetadataV1

    public init(
        version: Int = Self.version,
        blobID: Data,
        blobCapability: Data,
        mediaType: String,
        size: UInt64,
        digestAlgorithm: NoctCordAttachmentDigestAlgorithm = .sha256,
        digest: Data,
        expiresAt: Date,
        encryption: NoctCordAttachmentEncryptionMetadataV1
    ) {
        self.version = version
        self.blobID = blobID
        self.blobCapability = blobCapability
        self.mediaType = mediaType
        self.size = size
        self.digestAlgorithm = digestAlgorithm
        self.digest = digest
        self.expiresAt = expiresAt
        self.encryption = encryption
    }

    public var isStructurallyValid: Bool {
        version == Self.version
            && blobID.count >= 16
            && blobID.count <= 128
            && blobCapability.count == 32
            && NoctCordValidation.isSanitizedMediaType(mediaType)
            && size > 0
            && size <= 512 * 1024 * 1024
            && digest.count == 32
            && expiresAt.timeIntervalSince1970.isFinite
            && expiresAt >= Date(timeIntervalSince1970: 1_577_836_800)
            && expiresAt <= Date(timeIntervalSince1970: 4_102_444_800)
            && encryption.isStructurallyValid
    }
}

/// Opaque capabilities for the relay's low-latency room signal route. This
/// descriptor is distributed only inside the group-encrypted room event.
public struct NoctCordRealtimeRouteV1: Codable, Equatable, Sendable {
    public let routeCapability: Data
    public let appendCapability: Data
    public let readCapability: Data
    public let expiresAt: Date

    public init(
        routeCapability: Data,
        appendCapability: Data,
        readCapability: Data,
        expiresAt: Date
    ) {
        self.routeCapability = routeCapability
        self.appendCapability = appendCapability
        self.readCapability = readCapability
        self.expiresAt = expiresAt
    }

    public var isStructurallyValid: Bool {
        routeCapability.count == 32
            && appendCapability.count == 32
            && readCapability.count == 32
            && Set([routeCapability, appendCapability, readCapability]).count == 3
            && expiresAt.timeIntervalSince1970.isFinite
            && expiresAt >= Date(timeIntervalSince1970: 1_577_836_800)
            && expiresAt <= Date(timeIntervalSince1970: 4_102_444_800)
    }
}

public struct NoctCordVoiceRoomSpecV1: Codable, Equatable, Sendable {
    public static let version = 1

    public let version: Int
    public let name: String
    public let maxParticipants: UInt16
    /// Room-scoped secret material. It is carried only inside the enclosing
    /// group-encrypted event and is never available to relay code.
    public let signalingKey: Data
    public let realtimeRoute: NoctCordRealtimeRouteV1

    public init(
        version: Int = Self.version,
        name: String,
        maxParticipants: UInt16 = 16,
        signalingKey: Data,
        realtimeRoute: NoctCordRealtimeRouteV1
    ) {
        self.version = version
        self.name = name
        self.maxParticipants = maxParticipants
        self.signalingKey = signalingKey
        self.realtimeRoute = realtimeRoute
    }

    public var isStructurallyValid: Bool {
        version == Self.version
            && NoctCordValidation.isName(name)
            && maxParticipants >= 2
            && maxParticipants <= 64
            && signalingKey.count == 32
            && realtimeRoute.isStructurallyValid
    }

    /// A non-secret binding identifier for call signaling envelopes.
    public var signalingKeyID: Data {
        Data(SHA256.hash(data: Data("NoctCord/voice-signaling-key/v1".utf8) + signalingKey))
    }
}

public struct NoctCordVoiceParticipantStateV1: Codable, Equatable, Sendable {
    public let member: GroupScopedMemberHandleV2
    public let isJoined: Bool
    public let isMuted: Bool
    public let isDeafened: Bool
    public let isSpeaking: Bool

    public init(
        member: GroupScopedMemberHandleV2,
        isJoined: Bool,
        isMuted: Bool = false,
        isDeafened: Bool = false,
        isSpeaking: Bool = false
    ) {
        self.member = member
        self.isJoined = isJoined
        self.isMuted = isJoined && isMuted
        self.isDeafened = isJoined && isDeafened
        self.isSpeaking = isJoined && isSpeaking
    }

    public var isStructurallyValid: Bool {
        member.isStructurallyValid
            && (isJoined || (!isMuted && !isDeafened && !isSpeaking))
    }
}

public enum NoctCordCallSignalKind: String, Codable, Equatable, Sendable {
    case offer
    case answer
    case iceCandidate
    case renegotiation
    case end
}

/// Signaling is already encrypted before it enters a Noct Cord event. In
/// particular, this type contains ciphertext rather than SDP, ICE candidates,
/// or any other plaintext call description.
public struct NoctCordEncryptedCallSignalV1: Codable, Equatable, Sendable {
    public static let version = 1
    public static let maximumCiphertextBytes = 256 * 1024

    public let version: Int
    public let signalID: UUID
    public let callID: UUID
    public let sequence: UInt64
    public let kind: NoctCordCallSignalKind
    public let recipient: GroupScopedMemberHandleV2?
    public let keyID: Data
    public let nonce: Data
    public let ciphertext: Data
    public let authenticationTag: Data

    public init(
        version: Int = Self.version,
        signalID: UUID,
        callID: UUID,
        sequence: UInt64,
        kind: NoctCordCallSignalKind,
        recipient: GroupScopedMemberHandleV2? = nil,
        keyID: Data,
        nonce: Data,
        ciphertext: Data,
        authenticationTag: Data
    ) {
        self.version = version
        self.signalID = signalID
        self.callID = callID
        self.sequence = sequence
        self.kind = kind
        self.recipient = recipient
        self.keyID = keyID
        self.nonce = nonce
        self.ciphertext = ciphertext
        self.authenticationTag = authenticationTag
    }

    public var isStructurallyValid: Bool {
        version == Self.version
            && sequence > 0
            && sequence <= 9_007_199_254_740_991
            && keyID.count >= 16
            && keyID.count <= 128
            && nonce.count >= 12
            && nonce.count <= 32
            && !ciphertext.isEmpty
            && ciphertext.count <= Self.maximumCiphertextBytes
            && authenticationTag.count == 16
            && recipient?.isStructurallyValid ?? true
    }
}

public enum NoctCordScreenShareKind: String, Codable, Equatable, Sendable {
    case display
    case window
    case application
}

public struct NoctCordScreenShareDescriptorV1: Codable, Equatable, Sendable {
    public static let version = 1

    public let version: Int
    public let shareID: UUID
    public let presenter: GroupScopedMemberHandleV2
    public let source: NoctCordScreenShareKind
    /// Reference to an encrypted media key; never the media key itself.
    public let keyID: Data
    public let includesAudio: Bool

    public init(
        version: Int = Self.version,
        shareID: UUID,
        presenter: GroupScopedMemberHandleV2,
        source: NoctCordScreenShareKind,
        keyID: Data,
        includesAudio: Bool = false
    ) {
        self.version = version
        self.shareID = shareID
        self.presenter = presenter
        self.source = source
        self.keyID = keyID
        self.includesAudio = includesAudio
    }

    public var isStructurallyValid: Bool {
        version == Self.version
            && presenter.isStructurallyValid
            && keyID.count >= 16
            && keyID.count <= 128
    }
}

public struct NoctCordActiveScreenShare: Equatable, Sendable {
    public let roomID: UUID
    public let descriptor: NoctCordScreenShareDescriptorV1

    public init(roomID: UUID, descriptor: NoctCordScreenShareDescriptorV1) {
        self.roomID = roomID
        self.descriptor = descriptor
    }
}
