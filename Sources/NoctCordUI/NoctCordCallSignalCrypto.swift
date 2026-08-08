import CryptoKit
import Foundation
import NoctCordCore
import NoctCordMedia
@preconcurrency import NoctweaveCore

enum NoctCordCallSignalCryptoError: Error, Equatable {
    case unsupportedSignal
    case invalidRoom
    case invalidRecipient
    case authenticationFailed
}

enum NoctCordCallSignalCrypto {
    static func seal(
        _ envelope: NoctCordMediaSignalEnvelope,
        spaceID: UUID,
        room: NoctCordCore.NoctCordVoiceRoom,
        author: GroupScopedMemberHandleV2,
        recipient: GroupScopedMemberHandleV2?
    ) throws -> NoctCordEncryptedCallSignalV1 {
        guard envelope.roomID.rawValue == room.id.uuidString,
              envelope.sender.rawValue == participantID(for: author),
              envelope.recipient?.rawValue == recipient.map({ participantID(for: $0) }) else {
            throw NoctCordCallSignalCryptoError.invalidRoom
        }
        let kind = try callKind(for: envelope.signal.kind)
        let signalID = UUID()
        let encoded = try NoctCordMediaSignalingCodec.encode(envelope)
        let aad = authenticatedData(
            spaceID: spaceID,
            roomID: room.id,
            signalID: signalID,
            sequence: envelope.sequence,
            kind: kind,
            author: author,
            recipient: recipient
        )
        let encrypted = try CryptoBox.encrypt(
            encoded,
            key: SymmetricKey(data: room.signalingKey),
            authenticatedData: aad
        )
        return NoctCordEncryptedCallSignalV1(
            signalID: signalID,
            callID: room.id,
            sequence: envelope.sequence,
            kind: kind,
            recipient: recipient,
            keyID: room.signalingKeyID,
            nonce: encrypted.nonce,
            ciphertext: encrypted.ciphertext,
            authenticationTag: encrypted.tag
        )
    }

    static func open(
        _ signal: NoctCordEncryptedCallSignalV1,
        spaceID: UUID,
        room: NoctCordCore.NoctCordVoiceRoom,
        author: GroupScopedMemberHandleV2,
        localMember: GroupScopedMemberHandleV2
    ) throws -> NoctCordMediaSignalEnvelope {
        guard signal.callID == room.id,
              signal.keyID == room.signalingKeyID else {
            throw NoctCordCallSignalCryptoError.invalidRoom
        }
        guard signal.recipient == nil || signal.recipient == localMember else {
            throw NoctCordCallSignalCryptoError.invalidRecipient
        }
        let aad = authenticatedData(
            spaceID: spaceID,
            roomID: room.id,
            signalID: signal.signalID,
            sequence: signal.sequence,
            kind: signal.kind,
            author: author,
            recipient: signal.recipient
        )
        let payload = EncryptedPayload(
            nonce: signal.nonce,
            ciphertext: signal.ciphertext,
            tag: signal.authenticationTag
        )
        let plaintext: Data
        do {
            plaintext = try CryptoBox.decrypt(
                payload,
                key: SymmetricKey(data: room.signalingKey),
                authenticatedData: aad
            )
        } catch {
            throw NoctCordCallSignalCryptoError.authenticationFailed
        }
        let envelope = try NoctCordMediaSignalingCodec.decode(plaintext)
        guard envelope.roomID.rawValue == room.id.uuidString,
              envelope.sender.rawValue == participantID(for: author),
              envelope.recipient?.rawValue == signal.recipient.map({ participantID(for: $0) }),
              envelope.sequence == signal.sequence,
              try callKind(for: envelope.signal.kind) == signal.kind else {
            throw NoctCordCallSignalCryptoError.authenticationFailed
        }
        return envelope
    }

    static func participantID(for member: GroupScopedMemberHandleV2) -> String {
        member.rawValue
    }

    private static func callKind(
        for mediaKind: NoctCordMediaSignalKind
    ) throws -> NoctCordCallSignalKind {
        switch mediaKind {
        case .offer: .offer
        case .answer: .answer
        case .iceCandidate: .iceCandidate
        case .join, .leave, .microphoneState, .deafenState,
             .screenShareStarted, .screenShareStopped:
            .renegotiation
        }
    }

    private static func authenticatedData(
        spaceID: UUID,
        roomID: UUID,
        signalID: UUID,
        sequence: UInt64,
        kind: NoctCordCallSignalKind,
        author: GroupScopedMemberHandleV2,
        recipient: GroupScopedMemberHandleV2?
    ) -> Data {
        var value = Data("org.noctcord.call-signal-aad/v1".utf8)
        for component in [
            Data(spaceID.uuidString.utf8),
            Data(roomID.uuidString.utf8),
            Data(signalID.uuidString.utf8),
            Data(author.rawValue.utf8),
            Data((recipient?.rawValue ?? "").utf8),
            Data(kind.rawValue.utf8),
        ] {
            value.append(0)
            var length = UInt64(component.count).bigEndian
            value.append(Data(bytes: &length, count: MemoryLayout<UInt64>.size))
            value.append(component)
        }
        var orderedSequence = sequence.bigEndian
        value.append(Data(bytes: &orderedSequence, count: MemoryLayout<UInt64>.size))
        return value
    }
}
