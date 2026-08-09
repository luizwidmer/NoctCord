import CryptoKit
import Foundation
@preconcurrency import NoctweaveCore

public enum NoctCordIdentityScope: String, Codable, Equatable, Sendable {
    /// The same public profile key may be disclosed in multiple communities.
    /// This intentionally makes those memberships linkable to other members.
    case portable

    /// A fresh profile key is created for exactly one community. The host app
    /// must never reuse it for another space.
    case isolated
}

public enum NoctCordIdentityError: Error, Equatable {
    case invalidProfile
    case invalidBinding
    case keyMismatch
}

public struct NoctCordIdentityPublicProfileV1: Codable, Equatable, Sendable {
    public static let version = 1

    public let version: Int
    public let identityID: String
    public let scope: NoctCordIdentityScope
    public let displayName: String
    public let signingPublicKey: Data
    public let createdAt: Date

    public init(
        version: Int = Self.version,
        identityID: String,
        scope: NoctCordIdentityScope,
        displayName: String,
        signingPublicKey: Data,
        createdAt: Date
    ) {
        self.version = version
        self.identityID = identityID
        self.scope = scope
        self.displayName = displayName
        self.signingPublicKey = signingPublicKey
        self.createdAt = createdAt
    }

    public var isStructurallyValid: Bool {
        version == Self.version
            && identityID == Self.identityID(for: signingPublicKey)
            && NoctCordValidation.isName(displayName)
            && createdAt.timeIntervalSince1970.isFinite
            && createdAt >= Date(timeIntervalSince1970: 1_577_836_800)
            && createdAt <= Date(timeIntervalSince1970: 4_102_444_800)
            && SigningKeyPair.isValidPublicKey(signingPublicKey)
    }

    public static func identityID(for publicKey: Data) -> String {
        var material = Data("NoctCord/identity-id/v1".utf8)
        material.append(publicKey)
        let digest = SHA256.hash(data: material)
        return "nci1" + digest.map { String(format: "%02x", $0) }.joined()
    }
}

/// Private local identity material. Store this only inside the host app's
/// encrypted state store. Portable identity export must use a separately
/// encrypted, authenticated package.
public struct NoctCordIdentityKeyV1: Codable {
    public let scope: NoctCordIdentityScope
    private let signingKey: SigningKeyPair

    public static func generate(scope: NoctCordIdentityScope) throws -> Self {
        Self(scope: scope, signingKey: try SigningKeyPair.generate())
    }

    public init(scope: NoctCordIdentityScope, signingKey: SigningKeyPair) {
        self.scope = scope
        self.signingKey = signingKey
    }

    public func publicProfile(
        displayName: String,
        createdAt: Date = Date()
    ) throws -> NoctCordIdentityPublicProfileV1 {
        let profile = NoctCordIdentityPublicProfileV1(
            identityID: NoctCordIdentityPublicProfileV1.identityID(
                for: signingKey.publicKeyData
            ),
            scope: scope,
            displayName: displayName,
            signingPublicKey: signingKey.publicKeyData,
            createdAt: createdAt
        )
        guard profile.isStructurallyValid else { throw NoctCordIdentityError.invalidProfile }
        return profile
    }

    public func bind(
        profile: NoctCordIdentityPublicProfileV1,
        to spaceID: UUID,
        memberHandle: GroupScopedMemberHandleV2,
        issuedAt: Date = Date()
    ) throws -> NoctCordCommunityIdentityBindingV1 {
        guard profile.signingPublicKey == signingKey.publicKeyData,
              profile.scope == scope else {
            throw NoctCordIdentityError.keyMismatch
        }
        let statement = NoctCordIdentityBindingStatementV1(
            profile: profile,
            spaceID: spaceID,
            memberHandle: memberHandle,
            issuedAt: issuedAt
        )
        guard statement.isStructurallyValid else {
            throw NoctCordIdentityError.invalidBinding
        }
        let bytes = try NoctweaveCoder.encode(statement, sortedKeys: true)
        return NoctCordCommunityIdentityBindingV1(
            profile: profile,
            spaceID: spaceID,
            memberHandle: memberHandle,
            issuedAt: issuedAt,
            signature: try signingKey.sign(bytes)
        )
    }
}

public struct NoctCordCommunityIdentityBindingV1: Codable, Equatable, Sendable {
    public static let version = 1

    public let version: Int
    public let profile: NoctCordIdentityPublicProfileV1
    public let spaceID: UUID
    public let memberHandle: GroupScopedMemberHandleV2
    public let issuedAt: Date
    public let signature: Data

    public init(
        version: Int = Self.version,
        profile: NoctCordIdentityPublicProfileV1,
        spaceID: UUID,
        memberHandle: GroupScopedMemberHandleV2,
        issuedAt: Date,
        signature: Data
    ) {
        self.version = version
        self.profile = profile
        self.spaceID = spaceID
        self.memberHandle = memberHandle
        self.issuedAt = issuedAt
        self.signature = signature
    }

    public var isStructurallyValid: Bool {
        version == Self.version
            && profile.isStructurallyValid
            && memberHandle.isStructurallyValid
            && issuedAt.timeIntervalSince1970.isFinite
            && issuedAt >= profile.createdAt
            && issuedAt <= Date(timeIntervalSince1970: 4_102_444_800)
            && !signature.isEmpty
            && signature.count <= 8_192
    }

    public func verify() throws -> Bool {
        guard isStructurallyValid else { return false }
        let statement = NoctCordIdentityBindingStatementV1(
            profile: profile,
            spaceID: spaceID,
            memberHandle: memberHandle,
            issuedAt: issuedAt
        )
        let bytes = try NoctweaveCoder.encode(statement, sortedKeys: true)
        return try SigningKeyPair.verifyThrowing(
            signature: signature,
            data: bytes,
            publicKeyData: profile.signingPublicKey
        )
    }
}

public enum NoctCordIdentityBindingCodec {
    public static var contentType: ContentTypeId {
        ContentTypeId(
            authority: "org.noctcord",
            name: "identity-binding",
            major: 1
        )
    }

    public static func encode(
        _ binding: NoctCordCommunityIdentityBindingV1
    ) throws -> EncodedContent {
        guard try binding.verify() else { throw NoctCordIdentityError.invalidBinding }
        let content = EncodedContent(
            type: contentType,
            payload: try NoctweaveCoder.encode(binding, sortedKeys: true),
            disposition: .visible
        )
        guard content.isStructurallyValid else {
            throw NoctCordIdentityError.invalidBinding
        }
        return content
    }

    public static func decode(
        _ content: EncodedContent
    ) throws -> NoctCordCommunityIdentityBindingV1 {
        guard content.type == contentType else { throw NoctCordIdentityError.invalidBinding }
        let binding = try NoctweaveCoder.decode(
            NoctCordCommunityIdentityBindingV1.self,
            from: content.payload
        )
        guard try binding.verify() else { throw NoctCordIdentityError.invalidBinding }
        return binding
    }
}

private struct NoctCordIdentityBindingStatementV1: Codable {
    let domain: String
    let profile: NoctCordIdentityPublicProfileV1
    let spaceID: UUID
    let memberHandle: GroupScopedMemberHandleV2
    let issuedAt: Date

    init(
        profile: NoctCordIdentityPublicProfileV1,
        spaceID: UUID,
        memberHandle: GroupScopedMemberHandleV2,
        issuedAt: Date
    ) {
        domain = "NoctCord/community-identity-binding/v1"
        self.profile = profile
        self.spaceID = spaceID
        self.memberHandle = memberHandle
        self.issuedAt = issuedAt
    }

    var isStructurallyValid: Bool {
        domain == "NoctCord/community-identity-binding/v1"
            && profile.isStructurallyValid
            && memberHandle.isStructurallyValid
            && issuedAt.timeIntervalSince1970.isFinite
            && issuedAt >= profile.createdAt
            && issuedAt <= Date(timeIntervalSince1970: 4_102_444_800)
    }
}
