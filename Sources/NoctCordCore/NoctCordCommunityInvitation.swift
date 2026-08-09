import CryptoKit
import Foundation
@preconcurrency import NoctweaveCore

private struct NoctCordInvitationCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int?

    init?(stringValue: String) {
        self.stringValue = stringValue
        intValue = nil
    }

    init?(intValue: Int) {
        stringValue = String(intValue)
        self.intValue = intValue
    }
}

public enum NoctCordCommunityInvitationError: Error, Equatable, LocalizedError {
    case invalidInvitation
    case expiredInvitation
    case invalidExchange

    public var errorDescription: String? {
        switch self {
        case .invalidInvitation:
            "This Noct Cord invitation is malformed or unsupported."
        case .expiredInvitation:
            "This Noct Cord invitation has expired. Ask for a fresh invitation."
        case .invalidExchange:
            "This admission exchange does not belong to the selected invitation."
        }
    }
}

/// A bounded, transport-neutral invitation to one Noct Cord community.
///
/// The artifact intentionally contains no relay password, group secret, global
/// account, or reusable membership credential. It binds the prospective
/// member's one-use admission to the exact group state observed by the
/// inviter. The code must still be transferred through a channel where the
/// recipient can authenticate who supplied it; it is not a public directory
/// claim by itself.
public struct NoctCordCommunityInvitationV1: Codable, Equatable {
    public static let version = 1
    public static let prefix = "noctcord-community-invite-v1:"
    public static let maximumLifetime: TimeInterval = 12 * 60 * 60
    public static let maximumEncodedCharacters = 256 * 1_024

    public let version: Int
    public let invitationID: UUID
    public let spaceID: UUID
    public let spaceName: String
    public let relay: RelayEndpoint
    public let baseEpoch: UInt64
    public let baseStateDigest: Data
    public let invitationBindingDigest: Data
    public let issuedAt: Date
    public let expiresAt: Date

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case version
        case invitationID
        case spaceID
        case spaceName
        case relay
        case baseEpoch
        case baseStateDigest
        case invitationBindingDigest
        case issuedAt
        case expiresAt
    }

    private struct BindingPayload: Codable {
        let domain: String
        let version: Int
        let invitationID: UUID
        let spaceID: UUID
        let spaceName: String
        let relay: RelayEndpoint
        let baseEpoch: UInt64
        let baseStateDigest: Data
        let issuedAt: Date
        let expiresAt: Date
    }

    private init(
        invitationID: UUID,
        spaceID: UUID,
        spaceName: String,
        relay: RelayEndpoint,
        baseEpoch: UInt64,
        baseStateDigest: Data,
        invitationBindingDigest: Data,
        issuedAt: Date,
        expiresAt: Date
    ) {
        version = Self.version
        self.invitationID = invitationID
        self.spaceID = spaceID
        self.spaceName = spaceName
        self.relay = relay
        self.baseEpoch = baseEpoch
        self.baseStateDigest = baseStateDigest
        self.invitationBindingDigest = invitationBindingDigest
        self.issuedAt = issuedAt
        self.expiresAt = expiresAt
    }

    public init(from decoder: Decoder) throws {
        let strict = try decoder.container(keyedBy: NoctCordInvitationCodingKey.self)
        guard Set(strict.allKeys.map(\.stringValue))
                == Set(CodingKeys.allCases.map(\.rawValue)) else {
            throw NoctCordCommunityInvitationError.invalidInvitation
        }
        let values = try decoder.container(keyedBy: CodingKeys.self)
        version = try values.decode(Int.self, forKey: .version)
        invitationID = try values.decode(UUID.self, forKey: .invitationID)
        spaceID = try values.decode(UUID.self, forKey: .spaceID)
        spaceName = try values.decode(String.self, forKey: .spaceName)
        relay = try values.decode(RelayEndpoint.self, forKey: .relay)
        baseEpoch = try values.decode(UInt64.self, forKey: .baseEpoch)
        baseStateDigest = try values.decode(Data.self, forKey: .baseStateDigest)
        invitationBindingDigest = try values.decode(
            Data.self,
            forKey: .invitationBindingDigest
        )
        issuedAt = try values.decode(Date.self, forKey: .issuedAt)
        expiresAt = try values.decode(Date.self, forKey: .expiresAt)
        guard isValid(at: issuedAt) else {
            throw NoctCordCommunityInvitationError.invalidInvitation
        }
    }

    public static func create(
        spaceID: UUID,
        spaceName: String,
        relay: RelayEndpoint,
        baseEpoch: UInt64,
        baseStateDigest: Data,
        lifetime: TimeInterval = 60 * 60,
        issuedAt: Date = Date()
    ) throws -> Self {
        let cleanName = spaceName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard lifetime.isFinite,
              lifetime >= 60,
              lifetime <= maximumLifetime,
              issuedAt.timeIntervalSince1970.isFinite else {
            throw NoctCordCommunityInvitationError.invalidInvitation
        }
        let invitationID = UUID()
        let canonicalIssuedAt = NoctweaveRendezvousV2.canonicalTimestamp(issuedAt)
        let expiresAt = NoctweaveRendezvousV2.canonicalTimestamp(
            canonicalIssuedAt.addingTimeInterval(lifetime)
        )
        let digest = try bindingDigest(
            invitationID: invitationID,
            spaceID: spaceID,
            spaceName: cleanName,
            relay: relay,
            baseEpoch: baseEpoch,
            baseStateDigest: baseStateDigest,
            issuedAt: canonicalIssuedAt,
            expiresAt: expiresAt
        )
        let invitation = Self(
            invitationID: invitationID,
            spaceID: spaceID,
            spaceName: cleanName,
            relay: relay,
            baseEpoch: baseEpoch,
            baseStateDigest: baseStateDigest,
            invitationBindingDigest: digest,
            issuedAt: canonicalIssuedAt,
            expiresAt: expiresAt
        )
        guard invitation.isValid(at: canonicalIssuedAt) else {
            throw NoctCordCommunityInvitationError.invalidInvitation
        }
        return invitation
    }

    public func encoded() throws -> String {
        guard isValid(at: Date()) else {
            throw expiresAt <= Date()
                ? NoctCordCommunityInvitationError.expiredInvitation
                : NoctCordCommunityInvitationError.invalidInvitation
        }
        let result = Self.prefix
            + (try NoctweaveCoder.encode(self, sortedKeys: true)).base64EncodedString()
        guard result.count <= Self.maximumEncodedCharacters else {
            throw NoctCordCommunityInvitationError.invalidInvitation
        }
        return result
    }

    public static func decode(_ value: String, at date: Date = Date()) throws -> Self {
        let clean = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard clean.hasPrefix(prefix),
              clean.count <= maximumEncodedCharacters,
              let bytes = Data(base64Encoded: String(clean.dropFirst(prefix.count))) else {
            throw NoctCordCommunityInvitationError.invalidInvitation
        }
        let invitation: Self
        do {
            invitation = try NoctweaveCoder.decode(Self.self, from: bytes)
        } catch {
            throw NoctCordCommunityInvitationError.invalidInvitation
        }
        guard invitation.expiresAt > date else {
            throw NoctCordCommunityInvitationError.expiredInvitation
        }
        guard invitation.isValid(at: date) else {
            throw NoctCordCommunityInvitationError.invalidInvitation
        }
        return invitation
    }

    public func isValid(at date: Date) -> Bool {
        guard version == Self.version,
              !spaceName.isEmpty,
              spaceName == spaceName.trimmingCharacters(in: .whitespacesAndNewlines),
              spaceName.utf8.count <= 96,
              !spaceName.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              (try? relay.isStructurallyValidThrowing) == true,
              baseStateDigest.count == SHA256.byteCount,
              invitationBindingDigest.count == SHA256.byteCount,
              issuedAt.timeIntervalSince1970.isFinite,
              expiresAt.timeIntervalSince1970.isFinite,
              date.timeIntervalSince1970.isFinite,
              issuedAt < expiresAt,
              expiresAt.timeIntervalSince(issuedAt) <= Self.maximumLifetime,
              expiresAt > date,
              let expected = try? Self.bindingDigest(
                  invitationID: invitationID,
                  spaceID: spaceID,
                  spaceName: spaceName,
                  relay: relay,
                  baseEpoch: baseEpoch,
                  baseStateDigest: baseStateDigest,
                  issuedAt: issuedAt,
                  expiresAt: expiresAt
              ) else {
            return false
        }
        return expected == invitationBindingDigest
    }

    private static func bindingDigest(
        invitationID: UUID,
        spaceID: UUID,
        spaceName: String,
        relay: RelayEndpoint,
        baseEpoch: UInt64,
        baseStateDigest: Data,
        issuedAt: Date,
        expiresAt: Date
    ) throws -> Data {
        let payload = BindingPayload(
            domain: "org.noctcord.community-invitation/v1",
            version: Self.version,
            invitationID: invitationID,
            spaceID: spaceID,
            spaceName: spaceName,
            relay: relay,
            baseEpoch: baseEpoch,
            baseStateDigest: baseStateDigest,
            issuedAt: issuedAt,
            expiresAt: expiresAt
        )
        return Data(SHA256.hash(data: try NoctweaveCoder.encode(payload, sortedKeys: true)))
    }
}

public struct NoctCordPreparedCommunityAdmission: Equatable {
    public let invitation: NoctCordCommunityInvitationV1
    public let admissionID: UUID
    public let requestCode: String

    public init(
        invitation: NoctCordCommunityInvitationV1,
        admissionID: UUID,
        requestCode: String
    ) {
        self.invitation = invitation
        self.admissionID = admissionID
        self.requestCode = requestCode
    }
}
