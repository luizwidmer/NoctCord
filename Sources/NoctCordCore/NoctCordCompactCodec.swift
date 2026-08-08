import Foundation
@preconcurrency import NoctweaveCore

public enum NoctCordCompactCodecError: Error, Equatable {
    case invalidRecord
    case unsupportedVersion
    case truncatedRecord
}

/// Strict binary encoding for the low-latency route. It avoids JSON field
/// names and optional placeholders, but deliberately does not compress data or
/// pad records to a common size. Ciphertext length therefore remains visible.
public enum NoctCordCompactCodec {
    public static let version: UInt8 = 1
    public static let maximumRecordBytes = 512 * 1024

    public static func encode(_ event: NoctCordEvent) throws -> Data {
        guard event.isStructurallyValid else { throw NoctCordCompactCodecError.invalidRecord }
        var writer = CompactWriter()
        writer.append(UInt8(0x4E))
        writer.append(UInt8(0x43))
        writer.append(version)
        writer.append(event.operation.kind.compactCode)
        writer.append(event.id)
        writer.append(event.spaceID)
        guard let author = Data(base64Encoded: event.author.rawValue), author.count == 32 else {
            throw NoctCordCompactCodecError.invalidRecord
        }
        writer.append(author)
        writer.append(event.logicalClock)
        writer.append(event.createdAt.timeIntervalSince1970.bitPattern)

        let operation = event.operation
        var flags: UInt16 = 0
        if operation.kind.usesExtendedCompactPayload {
            flags = 1 << 15
        } else {
            if operation.channelID != nil { flags |= 1 << 0 }
            if operation.messageID != nil { flags |= 1 << 1 }
            if operation.roleID != nil { flags |= 1 << 2 }
            if operation.memberHandle != nil { flags |= 1 << 3 }
            if operation.name != nil { flags |= 1 << 4 }
            if operation.text != nil { flags |= 1 << 5 }
            if operation.permissions != nil { flags |= 1 << 6 }
            if operation.replyTo != nil { flags |= 1 << 7 }
            if operation.reaction != nil { flags |= 1 << 8 }
        }
        writer.append(flags)

        if operation.kind.usesExtendedCompactPayload {
            let payload = try NoctweaveCoder.encode(operation, sortedKeys: true)
            guard payload.count <= Int(UInt32.max) else {
                throw NoctCordCompactCodecError.invalidRecord
            }
            writer.append(UInt32(payload.count))
            writer.append(payload)
            guard writer.data.count <= maximumRecordBytes else {
                throw NoctCordCompactCodecError.invalidRecord
            }
            return writer.data
        }

        if let value = operation.channelID { writer.append(value) }
        if let value = operation.messageID { writer.append(value) }
        if let value = operation.roleID { writer.append(value) }
        if let value = operation.memberHandle {
            guard let bytes = Data(base64Encoded: value.rawValue), bytes.count == 32 else {
                throw NoctCordCompactCodecError.invalidRecord
            }
            writer.append(bytes)
        }
        if let value = operation.name { try writer.append(value) }
        if let value = operation.text { try writer.append(value) }
        if let values = operation.permissions {
            var bitmap: UInt16 = 0
            for value in values {
                guard let index = NoctCordPermission.allCases.firstIndex(of: value), index < 16 else {
                    throw NoctCordCompactCodecError.invalidRecord
                }
                bitmap |= 1 << UInt16(index)
            }
            writer.append(bitmap)
        }
        if let value = operation.replyTo { writer.append(value) }
        if let value = operation.reaction { try writer.append(value) }

        guard writer.data.count <= maximumRecordBytes else {
            throw NoctCordCompactCodecError.invalidRecord
        }
        return writer.data
    }

    public static func decode(_ data: Data) throws -> NoctCordEvent {
        guard data.count <= maximumRecordBytes else {
            throw NoctCordCompactCodecError.invalidRecord
        }
        var reader = CompactReader(data: data)
        guard try reader.readByte() == 0x4E,
              try reader.readByte() == 0x43 else {
            throw NoctCordCompactCodecError.invalidRecord
        }
        guard try reader.readByte() == version else {
            throw NoctCordCompactCodecError.unsupportedVersion
        }
        let kind = try NoctCordEventKind(compactCode: reader.readByte())
        let id = try reader.readUUID()
        let spaceID = try reader.readUUID()
        let author = GroupScopedMemberHandleV2(
            rawValue: try reader.readData(count: 32).base64EncodedString()
        )
        let logicalClock = try reader.readUInt64()
        let createdAt = Date(
            timeIntervalSince1970: Double(bitPattern: try reader.readUInt64())
        )
        let flags = try reader.readUInt16()
        let extendedPayload = flags & (1 << 15) != 0
        guard extendedPayload
            ? flags == (1 << 15)
            : flags & ~UInt16(0x01FF) == 0 else {
            throw NoctCordCompactCodecError.invalidRecord
        }

        let operation: NoctCordOperation
        if extendedPayload {
            let payloadLength = Int(try reader.readUInt32())
            let payload = try reader.readData(count: payloadLength)
            operation = try NoctweaveCoder.decode(NoctCordOperation.self, from: payload)
            guard operation.kind == kind else {
                throw NoctCordCompactCodecError.invalidRecord
            }
        } else {
            let channelID = flags & (1 << 0) != 0 ? try reader.readUUID() : nil
            let messageID = flags & (1 << 1) != 0 ? try reader.readUUID() : nil
            let roleID = flags & (1 << 2) != 0 ? try reader.readUUID() : nil
            let memberHandle = flags & (1 << 3) != 0
                ? GroupScopedMemberHandleV2(
                    rawValue: try reader.readData(count: 32).base64EncodedString()
                )
                : nil
            let name = flags & (1 << 4) != 0 ? try reader.readString() : nil
            let text = flags & (1 << 5) != 0 ? try reader.readString() : nil
            let permissions: Set<NoctCordPermission>?
            if flags & (1 << 6) != 0 {
                let bitmap = try reader.readUInt16()
                guard bitmap >> UInt16(NoctCordPermission.allCases.count) == 0 else {
                    throw NoctCordCompactCodecError.invalidRecord
                }
                permissions = Set(
                    NoctCordPermission.allCases.enumerated().compactMap { index, permission in
                        bitmap & (1 << UInt16(index)) != 0 ? permission : nil
                    }
                )
            } else {
                permissions = nil
            }
            let replyTo = flags & (1 << 7) != 0 ? try reader.readUUID() : nil
            let reaction = flags & (1 << 8) != 0 ? try reader.readString() : nil
            operation = NoctCordOperation(
                kind: kind,
                channelID: channelID,
                messageID: messageID,
                roleID: roleID,
                memberHandle: memberHandle,
                name: name,
                text: text,
                permissions: permissions,
                replyTo: replyTo,
                reaction: reaction
            )
        }
        guard reader.isAtEnd else { throw NoctCordCompactCodecError.invalidRecord }

        let event = NoctCordEvent(
            id: id,
            spaceID: spaceID,
            author: author,
            logicalClock: logicalClock,
            createdAt: createdAt,
            operation: operation
        )
        guard event.isStructurallyValid else { throw NoctCordCompactCodecError.invalidRecord }
        return event
    }
}

private extension NoctCordEventKind {
    var compactCode: UInt8 {
        switch self {
        case .spaceCreated: 0
        case .spaceRenamed: 1
        case .channelCreated: 2
        case .channelRenamed: 3
        case .channelArchived: 4
        case .roleDefined: 5
        case .roleDeleted: 6
        case .roleGranted: 7
        case .roleRevoked: 8
        case .messagePosted: 9
        case .messageEdited: 10
        case .messageRetracted: 11
        case .reactionAdded: 12
        case .reactionRemoved: 13
        case .messagePinned: 14
        case .messageUnpinned: 15
        case .attachmentAdded: 16
        case .voiceRoomCreated: 17
        case .voiceRoomUpdated: 18
        case .voiceRoomArchived: 19
        case .voiceParticipantJoined: 20
        case .voiceParticipantLeft: 21
        case .voiceParticipantMuted: 22
        case .voiceParticipantDeafened: 23
        case .voiceParticipantSpeaking: 24
        case .callSignalPosted: 25
        case .screenShareStarted: 26
        case .screenShareStopped: 27
        case .channelPermissionSet: 28
        case .channelPermissionRemoved: 29
        case .botInstalled: 30
        case .botUpdated: 31
        case .botRemoved: 32
        case .botCommandInvoked: 33
        }
    }

    var usesExtendedCompactPayload: Bool {
        switch self {
        case .roleDefined, .channelPermissionSet, .channelPermissionRemoved,
             .attachmentAdded, .voiceRoomCreated, .voiceRoomUpdated,
             .voiceRoomArchived, .voiceParticipantJoined, .voiceParticipantLeft,
             .voiceParticipantMuted, .voiceParticipantDeafened,
             .voiceParticipantSpeaking, .callSignalPosted, .screenShareStarted,
             .screenShareStopped, .botInstalled, .botUpdated, .botRemoved,
             .botCommandInvoked:
            return true
        default:
            return false
        }
    }

    init(compactCode: UInt8) throws {
        switch compactCode {
        case 0: self = .spaceCreated
        case 1: self = .spaceRenamed
        case 2: self = .channelCreated
        case 3: self = .channelRenamed
        case 4: self = .channelArchived
        case 5: self = .roleDefined
        case 6: self = .roleDeleted
        case 7: self = .roleGranted
        case 8: self = .roleRevoked
        case 9: self = .messagePosted
        case 10: self = .messageEdited
        case 11: self = .messageRetracted
        case 12: self = .reactionAdded
        case 13: self = .reactionRemoved
        case 14: self = .messagePinned
        case 15: self = .messageUnpinned
        case 16: self = .attachmentAdded
        case 17: self = .voiceRoomCreated
        case 18: self = .voiceRoomUpdated
        case 19: self = .voiceRoomArchived
        case 20: self = .voiceParticipantJoined
        case 21: self = .voiceParticipantLeft
        case 22: self = .voiceParticipantMuted
        case 23: self = .voiceParticipantDeafened
        case 24: self = .voiceParticipantSpeaking
        case 25: self = .callSignalPosted
        case 26: self = .screenShareStarted
        case 27: self = .screenShareStopped
        case 28: self = .channelPermissionSet
        case 29: self = .channelPermissionRemoved
        case 30: self = .botInstalled
        case 31: self = .botUpdated
        case 32: self = .botRemoved
        case 33: self = .botCommandInvoked
        default: throw NoctCordCompactCodecError.invalidRecord
        }
    }
}

private struct CompactWriter {
    var data = Data()

    mutating func append(_ value: UInt8) {
        data.append(value)
    }

    mutating func append(_ value: UInt16) {
        appendInteger(value.bigEndian)
    }

    mutating func append(_ value: UInt32) {
        appendInteger(value.bigEndian)
    }

    mutating func append(_ value: UInt64) {
        appendInteger(value.bigEndian)
    }

    mutating func append(_ value: UUID) {
        var uuid = value.uuid
        withUnsafeBytes(of: &uuid) { data.append(contentsOf: $0) }
    }

    mutating func append(_ value: Data) {
        data.append(value)
    }

    mutating func append(_ value: String) throws {
        let bytes = Data(value.utf8)
        guard bytes.count <= Int(UInt16.max) else {
            throw NoctCordCompactCodecError.invalidRecord
        }
        append(UInt16(bytes.count))
        append(bytes)
    }

    private mutating func appendInteger<T>(_ value: T) {
        var copy = value
        withUnsafeBytes(of: &copy) { data.append(contentsOf: $0) }
    }
}

private struct CompactReader {
    let data: Data
    var offset = 0

    var isAtEnd: Bool { offset == data.count }

    mutating func readByte() throws -> UInt8 {
        guard offset < data.count else { throw NoctCordCompactCodecError.truncatedRecord }
        defer { offset += 1 }
        return data[offset]
    }

    mutating func readUInt16() throws -> UInt16 {
        let bytes = try readData(count: 2)
        return bytes.reduce(UInt16(0)) { ($0 << 8) | UInt16($1) }
    }

    mutating func readUInt32() throws -> UInt32 {
        let bytes = try readData(count: 4)
        return bytes.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
    }

    mutating func readUInt64() throws -> UInt64 {
        let bytes = try readData(count: 8)
        return bytes.reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
    }

    mutating func readUUID() throws -> UUID {
        let bytes = [UInt8](try readData(count: 16))
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }

    mutating func readString() throws -> String {
        let count = Int(try readUInt16())
        let bytes = try readData(count: count)
        guard let value = String(data: bytes, encoding: .utf8) else {
            throw NoctCordCompactCodecError.invalidRecord
        }
        return value
    }

    mutating func readData(count: Int) throws -> Data {
        guard count >= 0, offset <= data.count - count else {
            throw NoctCordCompactCodecError.truncatedRecord
        }
        defer { offset += count }
        return data.subdata(in: offset..<(offset + count))
    }
}
