import Foundation
@preconcurrency import NoctweaveCore

public enum NoctCordPermission: String, Codable, CaseIterable, Hashable, Sendable {
    case readMessages
    case sendMessages
    case manageMessages
    case manageChannels
    case manageRoles
    case inviteMembers
    case manageSpace
}

public struct NoctCordRole: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let name: String
    public let permissions: [NoctCordPermission]

    public init(id: UUID = UUID(), name: String, permissions: Set<NoctCordPermission>) {
        self.id = id
        self.name = name
        self.permissions = permissions.sorted { $0.rawValue < $1.rawValue }
    }

    public var isStructurallyValid: Bool {
        NoctCordValidation.isName(name)
            && permissions.count <= NoctCordPermission.allCases.count
            && Set(permissions).count == permissions.count
            && permissions == permissions.sorted { $0.rawValue < $1.rawValue }
    }
}

public enum NoctCordEventKind: String, Codable, CaseIterable, Sendable {
    case spaceCreated
    case spaceRenamed
    case channelCreated
    case channelRenamed
    case channelArchived
    case roleDefined
    case roleDeleted
    case roleGranted
    case roleRevoked
    case messagePosted
    case messageEdited
    case messageRetracted
    case reactionAdded
    case reactionRemoved
    case messagePinned
    case messageUnpinned
    case attachmentAdded
    case voiceRoomCreated
    case voiceRoomUpdated
    case voiceRoomArchived
    case voiceParticipantJoined
    case voiceParticipantLeft
    case voiceParticipantMuted
    case voiceParticipantDeafened
    case voiceParticipantSpeaking
    case callSignalPosted
    case screenShareStarted
    case screenShareStopped
}

/// A bounded, application-level operation. It is encoded inside a Noctweave
/// group application event and is never interpreted by a relay.
public struct NoctCordOperation: Codable, Equatable, Sendable {
    public let kind: NoctCordEventKind
    public let channelID: UUID?
    public let messageID: UUID?
    public let roleID: UUID?
    public let memberHandle: GroupScopedMemberHandleV2?
    public let name: String?
    public let text: String?
    public let permissions: [NoctCordPermission]?
    public let replyTo: UUID?
    public let reaction: String?
    public let attachmentID: UUID?
    public let attachmentManifest: NoctCordAttachmentManifestV1?
    public let voiceRoomID: UUID?
    public let voiceRoomSpec: NoctCordVoiceRoomSpecV1?
    public let voiceParticipantState: NoctCordVoiceParticipantStateV1?
    public let callSignal: NoctCordEncryptedCallSignalV1?
    public let screenShare: NoctCordScreenShareDescriptorV1?
    public let screenShareID: UUID?

    public init(
        kind: NoctCordEventKind,
        channelID: UUID? = nil,
        messageID: UUID? = nil,
        roleID: UUID? = nil,
        memberHandle: GroupScopedMemberHandleV2? = nil,
        name: String? = nil,
        text: String? = nil,
        permissions: Set<NoctCordPermission>? = nil,
        replyTo: UUID? = nil,
        reaction: String? = nil,
        attachmentID: UUID? = nil,
        attachmentManifest: NoctCordAttachmentManifestV1? = nil,
        voiceRoomID: UUID? = nil,
        voiceRoomSpec: NoctCordVoiceRoomSpecV1? = nil,
        voiceParticipantState: NoctCordVoiceParticipantStateV1? = nil,
        callSignal: NoctCordEncryptedCallSignalV1? = nil,
        screenShare: NoctCordScreenShareDescriptorV1? = nil,
        screenShareID: UUID? = nil
    ) {
        self.kind = kind
        self.channelID = channelID
        self.messageID = messageID
        self.roleID = roleID
        self.memberHandle = memberHandle
        self.name = name
        self.text = text
        self.permissions = permissions?.sorted { $0.rawValue < $1.rawValue }
        self.replyTo = replyTo
        self.reaction = reaction
        self.attachmentID = attachmentID
        self.attachmentManifest = attachmentManifest
        self.voiceRoomID = voiceRoomID
        self.voiceRoomSpec = voiceRoomSpec
        self.voiceParticipantState = voiceParticipantState
        self.callSignal = callSignal
        self.screenShare = screenShare
        self.screenShareID = screenShareID
    }

    public static func createSpace(name: String) -> Self {
        Self(kind: .spaceCreated, name: name)
    }

    public static func renameSpace(_ name: String) -> Self {
        Self(kind: .spaceRenamed, name: name)
    }

    public static func createChannel(id: UUID, name: String) -> Self {
        Self(kind: .channelCreated, channelID: id, name: name)
    }

    public static func renameChannel(id: UUID, name: String) -> Self {
        Self(kind: .channelRenamed, channelID: id, name: name)
    }

    public static func archiveChannel(id: UUID) -> Self {
        Self(kind: .channelArchived, channelID: id)
    }

    public static func defineRole(_ role: NoctCordRole) -> Self {
        Self(
            kind: .roleDefined,
            roleID: role.id,
            name: role.name,
            permissions: Set(role.permissions)
        )
    }

    public static func deleteRole(id: UUID) -> Self {
        Self(kind: .roleDeleted, roleID: id)
    }

    public static func grantRole(id: UUID, to member: GroupScopedMemberHandleV2) -> Self {
        Self(kind: .roleGranted, roleID: id, memberHandle: member)
    }

    public static func revokeRole(id: UUID, from member: GroupScopedMemberHandleV2) -> Self {
        Self(kind: .roleRevoked, roleID: id, memberHandle: member)
    }

    public static func postMessage(
        id: UUID,
        channelID: UUID,
        text: String,
        replyTo: UUID? = nil
    ) -> Self {
        Self(
            kind: .messagePosted,
            channelID: channelID,
            messageID: id,
            text: text,
            replyTo: replyTo
        )
    }

    public static func editMessage(id: UUID, text: String) -> Self {
        Self(kind: .messageEdited, messageID: id, text: text)
    }

    public static func retractMessage(id: UUID) -> Self {
        Self(kind: .messageRetracted, messageID: id)
    }

    public static func addReaction(_ value: String, to messageID: UUID) -> Self {
        Self(kind: .reactionAdded, messageID: messageID, reaction: value)
    }

    public static func removeReaction(_ value: String, from messageID: UUID) -> Self {
        Self(kind: .reactionRemoved, messageID: messageID, reaction: value)
    }

    public static func pinMessage(id: UUID) -> Self {
        Self(kind: .messagePinned, messageID: id)
    }

    public static func unpinMessage(id: UUID) -> Self {
        Self(kind: .messageUnpinned, messageID: id)
    }

    public static func addAttachment(
        id: UUID,
        channelID: UUID,
        manifest: NoctCordAttachmentManifestV1
    ) -> Self {
        Self(
            kind: .attachmentAdded,
            channelID: channelID,
            attachmentID: id,
            attachmentManifest: manifest
        )
    }

    public static func createVoiceRoom(
        id: UUID,
        spec: NoctCordVoiceRoomSpecV1
    ) -> Self {
        Self(kind: .voiceRoomCreated, voiceRoomID: id, voiceRoomSpec: spec)
    }

    public static func updateVoiceRoom(
        id: UUID,
        spec: NoctCordVoiceRoomSpecV1
    ) -> Self {
        Self(kind: .voiceRoomUpdated, voiceRoomID: id, voiceRoomSpec: spec)
    }

    public static func archiveVoiceRoom(id: UUID) -> Self {
        Self(kind: .voiceRoomArchived, voiceRoomID: id)
    }

    public static func joinVoiceRoom(
        id: UUID,
        state: NoctCordVoiceParticipantStateV1
    ) -> Self {
        Self(kind: .voiceParticipantJoined, voiceRoomID: id, voiceParticipantState: state)
    }

    public static func leaveVoiceRoom(
        id: UUID,
        state: NoctCordVoiceParticipantStateV1
    ) -> Self {
        Self(kind: .voiceParticipantLeft, voiceRoomID: id, voiceParticipantState: state)
    }

    public static func setVoiceMute(
        roomID: UUID,
        state: NoctCordVoiceParticipantStateV1
    ) -> Self {
        Self(kind: .voiceParticipantMuted, voiceRoomID: roomID, voiceParticipantState: state)
    }

    public static func setVoiceDeafened(
        roomID: UUID,
        state: NoctCordVoiceParticipantStateV1
    ) -> Self {
        Self(kind: .voiceParticipantDeafened, voiceRoomID: roomID, voiceParticipantState: state)
    }

    public static func setVoiceSpeaking(
        roomID: UUID,
        state: NoctCordVoiceParticipantStateV1
    ) -> Self {
        Self(kind: .voiceParticipantSpeaking, voiceRoomID: roomID, voiceParticipantState: state)
    }

    public static func postCallSignal(
        roomID: UUID,
        signal: NoctCordEncryptedCallSignalV1
    ) -> Self {
        Self(kind: .callSignalPosted, voiceRoomID: roomID, callSignal: signal)
    }

    public static func startScreenShare(
        roomID: UUID,
        descriptor: NoctCordScreenShareDescriptorV1
    ) -> Self {
        Self(kind: .screenShareStarted, voiceRoomID: roomID, screenShare: descriptor)
    }

    public static func stopScreenShare(
        roomID: UUID,
        shareID: UUID
    ) -> Self {
        Self(kind: .screenShareStopped, voiceRoomID: roomID, screenShareID: shareID)
    }

    public var isStructurallyValid: Bool {
        let permissionListIsValid = permissions.map {
            $0.count <= NoctCordPermission.allCases.count
                && Set($0).count == $0.count
                && $0 == $0.sorted { lhs, rhs in lhs.rawValue < rhs.rawValue }
        } ?? true
        guard permissionListIsValid,
              memberHandle?.isStructurallyValid ?? true,
              attachmentManifest?.isStructurallyValid ?? true,
              voiceRoomSpec?.isStructurallyValid ?? true,
              voiceParticipantState?.isStructurallyValid ?? true,
              callSignal?.isStructurallyValid ?? true,
              screenShare?.isStructurallyValid ?? true else {
            return false
        }

        switch kind {
        case .spaceCreated, .spaceRenamed:
            return NoctCordValidation.isName(name)
                && only(name: true)
        case .channelCreated, .channelRenamed:
            return channelID != nil
                && NoctCordValidation.isName(name)
                && only(channel: true, name: true)
        case .channelArchived:
            return channelID != nil && only(channel: true)
        case .roleDefined:
            return roleID != nil
                && NoctCordValidation.isName(name)
                && permissions != nil
                && only(role: true, name: true, permissions: true)
        case .roleDeleted:
            return roleID != nil && only(role: true)
        case .roleGranted, .roleRevoked:
            return roleID != nil
                && memberHandle != nil
                && only(role: true, member: true)
        case .messagePosted:
            return channelID != nil
                && messageID != nil
                && NoctCordValidation.isMessage(text)
                && only(channel: true, message: true, text: true, reply: replyTo != nil)
        case .messageEdited:
            return messageID != nil
                && NoctCordValidation.isMessage(text)
                && only(message: true, text: true)
        case .messageRetracted, .messagePinned, .messageUnpinned:
            return messageID != nil && only(message: true)
        case .reactionAdded, .reactionRemoved:
            return messageID != nil
                && NoctCordValidation.isReaction(reaction)
                && only(message: true, reaction: true)
        case .attachmentAdded:
            return channelID != nil
                && attachmentID != nil
                && attachmentManifest != nil
                && only(channel: true, attachment: true, attachmentManifest: true)
        case .voiceRoomCreated, .voiceRoomUpdated:
            return voiceRoomID != nil
                && voiceRoomSpec != nil
                && only(voiceRoom: true, voiceRoomSpec: true)
        case .voiceRoomArchived:
            return voiceRoomID != nil && only(voiceRoom: true)
        case .voiceParticipantJoined, .voiceParticipantLeft,
             .voiceParticipantMuted, .voiceParticipantDeafened,
             .voiceParticipantSpeaking:
            return voiceRoomID != nil
                && voiceParticipantState != nil
                && only(voiceRoom: true, participantState: true)
        case .callSignalPosted:
            return voiceRoomID != nil
                && callSignal != nil
                && only(voiceRoom: true, callSignal: true)
        case .screenShareStarted:
            return voiceRoomID != nil
                && screenShare != nil
                && only(voiceRoom: true, screenShare: true)
        case .screenShareStopped:
            return voiceRoomID != nil
                && screenShareID != nil
                && only(voiceRoom: true, screenShareID: true)
        }
    }

    private func only(
        channel: Bool = false,
        message: Bool = false,
        role: Bool = false,
        member: Bool = false,
        name: Bool = false,
        text: Bool = false,
        permissions: Bool = false,
        reply: Bool = false,
        reaction: Bool = false,
        attachment: Bool = false,
        attachmentManifest: Bool = false,
        voiceRoom: Bool = false,
        voiceRoomSpec: Bool = false,
        participantState: Bool = false,
        callSignal: Bool = false,
        screenShare: Bool = false,
        screenShareID: Bool = false
    ) -> Bool {
        (channelID != nil) == channel
            && (messageID != nil) == message
            && (roleID != nil) == role
            && (memberHandle != nil) == member
            && (self.name != nil) == name
            && (self.text != nil) == text
            && (self.permissions != nil) == permissions
            && (replyTo != nil) == reply
            && (self.reaction != nil) == reaction
            && (attachmentID != nil) == attachment
            && (self.attachmentManifest != nil) == attachmentManifest
            && (voiceRoomID != nil) == voiceRoom
            && (self.voiceRoomSpec != nil) == voiceRoomSpec
            && (self.voiceParticipantState != nil) == participantState
            && (self.callSignal != nil) == callSignal
            && (self.screenShare != nil) == screenShare
            && (self.screenShareID != nil) == screenShareID
    }
}

public struct NoctCordEvent: Codable, Equatable, Identifiable, Sendable {
    public static let version = 1

    public let version: Int
    public let id: UUID
    public let spaceID: UUID
    public let author: GroupScopedMemberHandleV2
    public let logicalClock: UInt64
    public let createdAt: Date
    public let operation: NoctCordOperation

    public init(
        version: Int = Self.version,
        id: UUID = UUID(),
        spaceID: UUID,
        author: GroupScopedMemberHandleV2,
        logicalClock: UInt64,
        createdAt: Date = Date(),
        operation: NoctCordOperation
    ) {
        self.version = version
        self.id = id
        self.spaceID = spaceID
        self.author = author
        self.logicalClock = logicalClock
        // Noctweave's canonical JSON date profile is second-granular. Keep
        // the application event and its enclosing signed group event on that
        // same timestamp before either is encoded so local publications can
        // be decoded and projected identically to received publications.
        self.createdAt = NoctweaveRendezvousV2.canonicalTimestamp(createdAt)
        self.operation = operation
    }

    public var isStructurallyValid: Bool {
        version == Self.version
            && author.isStructurallyValid
            && logicalClock > 0
            && logicalClock <= 9_007_199_254_740_991
            && createdAt.timeIntervalSince1970.isFinite
            && createdAt >= Date(timeIntervalSince1970: 1_577_836_800)
            && createdAt <= Date(timeIntervalSince1970: 4_102_444_800)
            && operation.isStructurallyValid
    }
}

enum NoctCordValidation {
    static func isName(_ value: String?) -> Bool {
        guard let value else { return false }
        return !value.isEmpty
            && value == value.trimmingCharacters(in: .whitespacesAndNewlines)
            && value.utf8.count <= 96
            && !containsUnsafeControl(value)
    }

    static func isMessage(_ value: String?) -> Bool {
        guard let value else { return false }
        return !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && value.utf8.count <= 16_384
            && !containsUnsafeControl(value, allowingLineBreaks: true)
    }

    static func isReaction(_ value: String?) -> Bool {
        guard let value else { return false }
        return !value.isEmpty
            && value == value.trimmingCharacters(in: .whitespacesAndNewlines)
            && value.utf8.count <= 64
            && !containsUnsafeControl(value)
    }

    static func isSanitizedMediaType(_ value: String) -> Bool {
        guard value == value.lowercased(), value.utf8.count <= 128 else { return false }
        let parts = value.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else { return false }
        return parts.allSatisfy { token in
            token.unicodeScalars.allSatisfy { scalar in
                CharacterSet(
                    charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789!#$&^_.+-"
                ).contains(scalar)
            }
        }
    }

    private static func containsUnsafeControl(
        _ value: String,
        allowingLineBreaks: Bool = false
    ) -> Bool {
        value.unicodeScalars.contains { scalar in
            if allowingLineBreaks, scalar == "\n" || scalar == "\t" { return false }
            return CharacterSet.controlCharacters.contains(scalar)
        }
    }
}
