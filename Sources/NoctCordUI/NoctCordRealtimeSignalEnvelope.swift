import CryptoKit
import Foundation
import NoctCordCore
@preconcurrency import NoctweaveCore

struct NoctCordRealtimeSignedSignalBodyV1: Codable, Equatable {
    static let schema = "org.noctcord.realtime-call-signal"
    static let version = 1

    let schema: String
    let version: Int
    let spaceID: UUID
    let roomID: UUID
    let author: GroupScopedMemberHandleV2
    let credential: GroupScopedCredentialHandleV2
    let signal: NoctCordEncryptedCallSignalV1
    let createdAt: Date

    init(
        spaceID: UUID,
        roomID: UUID,
        author: GroupScopedMemberHandleV2,
        credential: GroupScopedCredentialHandleV2,
        signal: NoctCordEncryptedCallSignalV1,
        createdAt: Date
    ) {
        schema = Self.schema
        version = Self.version
        self.spaceID = spaceID
        self.roomID = roomID
        self.author = author
        self.credential = credential
        self.signal = signal
        self.createdAt = NoctweaveRendezvousV2.canonicalTimestamp(createdAt)
    }

    var isStructurallyValid: Bool {
        schema == Self.schema
            && version == Self.version
            && author.isStructurallyValid
            && credential.isStructurallyValid
            && signal.isStructurallyValid
            && signal.callID == roomID
            && createdAt.timeIntervalSince1970.isFinite
    }
}

struct NoctCordRealtimeSignedSignalEnvelopeV1: Codable, Equatable {
    static let version = 1

    let version: Int
    let body: NoctCordRealtimeSignedSignalBodyV1
    let signature: Data

    init(body: NoctCordRealtimeSignedSignalBodyV1, signature: Data) {
        version = Self.version
        self.body = body
        self.signature = signature
    }

    var isStructurallyValid: Bool {
        version == Self.version
            && body.isStructurallyValid
            && !signature.isEmpty
            && signature.count <= 16 * 1_024
    }
}

enum NoctCordRealtimeSignalWire {
    static func seal(
        _ envelope: NoctCordRealtimeSignedSignalEnvelopeV1,
        room: NoctCordCore.NoctCordVoiceRoom,
        spaceID: UUID
    ) throws -> Data {
        guard envelope.isStructurallyValid else {
            throw NoctCordTransportError.eventRejected
        }
        let plaintext = try NoctweaveCoder.encode(envelope)
        let encrypted = try CryptoBox.encrypt(
            plaintext,
            key: SymmetricKey(data: room.signalingKey),
            authenticatedData: authenticatedData(
                spaceID: spaceID,
                roomID: room.id,
                routeCapability: room.realtimeRoute.routeCapability
            )
        )
        let result = try NoctweaveCoder.encode(encrypted)
        guard result.count <= RealtimeRelayLimitsV1.maximumRecordBytes else {
            throw NoctCordTransportError.eventRejected
        }
        return result
    }

    static func open(
        _ wire: Data,
        room: NoctCordCore.NoctCordVoiceRoom,
        spaceID: UUID
    ) throws -> NoctCordRealtimeSignedSignalEnvelopeV1 {
        guard !wire.isEmpty, wire.count <= RealtimeRelayLimitsV1.maximumRecordBytes else {
            throw NoctCordTransportError.eventRejected
        }
        let encrypted = try NoctweaveCoder.decode(EncryptedPayload.self, from: wire)
        let plaintext = try CryptoBox.decrypt(
            encrypted,
            key: SymmetricKey(data: room.signalingKey),
            authenticatedData: authenticatedData(
                spaceID: spaceID,
                roomID: room.id,
                routeCapability: room.realtimeRoute.routeCapability
            )
        )
        let envelope = try NoctweaveCoder.decode(
            NoctCordRealtimeSignedSignalEnvelopeV1.self,
            from: plaintext
        )
        guard envelope.isStructurallyValid,
              envelope.body.spaceID == spaceID,
              envelope.body.roomID == room.id else {
            throw NoctCordTransportError.eventRejected
        }
        return envelope
    }

    static func signedBytes(_ body: NoctCordRealtimeSignedSignalBodyV1) throws -> Data {
        try NoctweaveCoder.encode(body, sortedKeys: true)
    }

    private static func authenticatedData(
        spaceID: UUID,
        roomID: UUID,
        routeCapability: Data
    ) -> Data {
        var data = Data("org.noctcord.realtime-signal-wire-aad/v1".utf8)
        data.append(0)
        data.append(Data(spaceID.uuidString.utf8))
        data.append(0)
        data.append(Data(roomID.uuidString.utf8))
        data.append(0)
        data.append(Data(SHA256.hash(data: routeCapability)))
        return data
    }
}
