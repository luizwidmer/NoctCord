import CryptoKit
import Foundation
@preconcurrency import NoctweaveCore

public enum NoctCordProjectionError: Error, Equatable, CustomStringConvertible {
    case invalidEvent
    case wrongSpace
    case inactiveMember
    case outOfOrder
    case permissionDenied(NoctCordPermission)
    case alreadyExists
    case missingDependency
    case archivedChannel

    public var description: String {
        switch self {
        case .invalidEvent: "invalid event"
        case .wrongSpace: "event belongs to another space"
        case .inactiveMember: "author is not an active group member"
        case .outOfOrder: "event was not supplied in canonical order"
        case .permissionDenied(let permission): "missing permission: \(permission.rawValue)"
        case .alreadyExists: "object already exists"
        case .missingDependency: "referenced object does not exist"
        case .archivedChannel: "channel is archived"
        }
    }
}

public struct NoctCordChannel: Equatable, Identifiable, Sendable {
    public let id: UUID
    public var name: String
    public var isArchived: Bool
    public var permissionOverrides: [
        NoctCordChannelPermissionTarget: NoctCordChannelPermissionOverride
    ]
    public var messageIDs: [UUID]
    public var attachmentIDs: [UUID]
}

public struct NoctCordVoiceRoom: Equatable, Identifiable, Sendable {
    public let id: UUID
    public var name: String
    public var maxParticipants: UInt16
    public var signalingKey: Data
    public var realtimeRoute: NoctCordRealtimeRouteV1
    public var isArchived: Bool

    public var signalingKeyID: Data {
        Data(SHA256.hash(data: Data("NoctCord/voice-signaling-key/v1".utf8) + signalingKey))
    }
}

public struct NoctCordMessage: Equatable, Identifiable, Sendable {
    public let id: UUID
    public let channelID: UUID
    public let author: GroupScopedMemberHandleV2
    public let createdAt: Date
    public var editedAt: Date?
    public var text: String
    public let replyTo: UUID?
    public var isRetracted: Bool
    public var isPinned: Bool
    public var reactions: [String: Set<GroupScopedMemberHandleV2>]
}

public struct NoctCordRejectedEvent: Equatable, Sendable {
    public let eventID: UUID
    public let reason: String
}

public struct NoctCordProjectionResult: Equatable, Sendable {
    public let projection: NoctCordSpaceProjection
    public let rejectedEvents: [NoctCordRejectedEvent]
}

/// Deterministic local materialization of encrypted Noct Cord events.
/// No relay stores or evaluates this state.
public struct NoctCordSpaceProjection: Equatable, Sendable {
    public let spaceID: UUID
    public let owner: GroupScopedMemberHandleV2
    public private(set) var name: String?
    public private(set) var activeMembers: Set<GroupScopedMemberHandleV2>
    public private(set) var channels: [UUID: NoctCordChannel]
    public private(set) var roles: [UUID: NoctCordRole]
    public private(set) var roleAssignments: [GroupScopedMemberHandleV2: Set<UUID>]
    public private(set) var botApplications: [UUID: NoctCordBotApplication]
    public private(set) var botInvocations: [UUID: NoctCordBotCommandInvocation]
    public private(set) var messages: [UUID: NoctCordMessage]
    public private(set) var attachments: [UUID: NoctCordAttachmentManifestV1]
    public private(set) var voiceRooms: [UUID: NoctCordVoiceRoom]
    public private(set) var voiceParticipants: [UUID: [GroupScopedMemberHandleV2: NoctCordVoiceParticipantStateV1]]
    public private(set) var callSignals: [UUID: [UUID: NoctCordEncryptedCallSignalV1]]
    public private(set) var activeScreenShares: [UUID: NoctCordActiveScreenShare]
    public private(set) var appliedEventIDs: Set<UUID>

    private var lastOrder: EventOrder?

    public init(
        spaceID: UUID,
        owner: GroupScopedMemberHandleV2,
        activeMembers: Set<GroupScopedMemberHandleV2>
    ) {
        self.spaceID = spaceID
        self.owner = owner
        self.activeMembers = activeMembers.union([owner])
        name = nil
        channels = [:]
        roles = [:]
        roleAssignments = [:]
        botApplications = [:]
        botInvocations = [:]
        messages = [:]
        attachments = [:]
        voiceRooms = [:]
        voiceParticipants = [:]
        callSignals = [:]
        activeScreenShares = [:]
        appliedEventIDs = []
        lastOrder = nil
    }

    public static func project(
        spaceID: UUID,
        owner: GroupScopedMemberHandleV2,
        activeMembers: Set<GroupScopedMemberHandleV2>,
        historicalMembers: Set<GroupScopedMemberHandleV2>,
        events: [NoctCordEvent]
    ) -> NoctCordProjectionResult {
        var projection = NoctCordSpaceProjection(
            spaceID: spaceID,
            owner: owner,
            activeMembers: activeMembers.union(historicalMembers)
        )
        var rejected: [NoctCordRejectedEvent] = []
        for event in events.sorted(by: canonicalOrder) {
            do {
                try projection.apply(
                    event,
                    permittingHistoricalAuthor: historicalMembers.contains(event.author)
                )
            } catch {
                rejected.append(
                    NoctCordRejectedEvent(eventID: event.id, reason: String(describing: error))
                )
            }
        }
        projection.reconcileMembership(activeMembers)
        return NoctCordProjectionResult(projection: projection, rejectedEvents: rejected)
    }

    public static func project(
        spaceID: UUID,
        owner: GroupScopedMemberHandleV2,
        activeMembers: Set<GroupScopedMemberHandleV2>,
        events: [NoctCordEvent]
    ) -> NoctCordProjectionResult {
        project(
            spaceID: spaceID,
            owner: owner,
            activeMembers: activeMembers,
            historicalMembers: [],
            events: events
        )
    }

    public mutating func reconcileMembership(
        _ members: Set<GroupScopedMemberHandleV2>
    ) {
        activeMembers = members.union([owner])
        roleAssignments = roleAssignments.filter { activeMembers.contains($0.key) }
        botApplications = botApplications.filter { activeMembers.contains($0.value.memberHandle) }
    }

    public func permissions(for member: GroupScopedMemberHandleV2) -> Set<NoctCordPermission> {
        guard activeMembers.contains(member) else { return [] }
        if member == owner { return Set(NoctCordPermission.allCases) }
        var result = NoctCordPermission.defaultMember
        for roleID in roleAssignments[member, default: []] {
            result.formUnion(roles[roleID]?.permissions ?? [])
        }
        if result.contains(.manageSpace) {
            return Set(NoctCordPermission.allCases)
        }
        return result
    }

    public func permissions(
        for member: GroupScopedMemberHandleV2,
        in channelID: UUID
    ) -> Set<NoctCordPermission> {
        guard let channel = channels[channelID], !channel.isArchived else { return [] }
        var result = permissions(for: member)
        guard !result.isEmpty else { return [] }
        if member == owner || result.contains(.manageSpace) {
            return Set(NoctCordPermission.allCases)
        }

        if let everyone = channel.permissionOverrides[.everyone] {
            result.subtract(everyone.deny)
            result.formUnion(everyone.allow)
        }

        var roleDeny: Set<NoctCordPermission> = []
        var roleAllow: Set<NoctCordPermission> = []
        for roleID in roleAssignments[member, default: []] {
            guard let overwrite = channel.permissionOverrides[.role(roleID)] else { continue }
            roleDeny.formUnion(overwrite.deny)
            roleAllow.formUnion(overwrite.allow)
        }
        result.subtract(roleDeny)
        result.formUnion(roleAllow)

        if !result.contains(.readMessages) {
            result.subtract(NoctCordPermission.channelScoped)
        } else if !result.contains(.sendMessages) {
            result.subtract([.attachFiles, .useApplicationCommands])
        }
        return result
    }

    public func roles(for member: GroupScopedMemberHandleV2) -> [NoctCordRole] {
        roleAssignments[member, default: []]
            .compactMap { roles[$0] }
            .sorted {
                if $0.position != $1.position { return $0.position > $1.position }
                return $0.id.uuidString < $1.id.uuidString
            }
    }

    public func highestRolePosition(for member: GroupScopedMemberHandleV2) -> UInt16 {
        member == owner ? .max : (roles(for: member).map(\.position).max() ?? 0)
    }

    public mutating func apply(_ event: NoctCordEvent) throws {
        try apply(event, permittingHistoricalAuthor: false)
    }

    private mutating func apply(
        _ event: NoctCordEvent,
        permittingHistoricalAuthor: Bool
    ) throws {
        guard event.isStructurallyValid else { throw NoctCordProjectionError.invalidEvent }
        guard event.spaceID == spaceID else { throw NoctCordProjectionError.wrongSpace }
        if appliedEventIDs.contains(event.id) { return }
        guard activeMembers.contains(event.author) || permittingHistoricalAuthor else {
            throw NoctCordProjectionError.inactiveMember
        }
        let order = EventOrder(event)
        if let lastOrder, order < lastOrder { throw NoctCordProjectionError.outOfOrder }

        switch event.operation.kind {
        case .spaceCreated:
            guard event.author == owner else {
                throw NoctCordProjectionError.permissionDenied(.manageSpace)
            }
            guard name == nil else { throw NoctCordProjectionError.alreadyExists }
            name = event.operation.name

        case .spaceRenamed:
            try require(.manageSpace, for: event.author)
            guard name != nil else { throw NoctCordProjectionError.missingDependency }
            name = event.operation.name

        case .channelCreated:
            try require(.manageChannels, for: event.author)
            guard let channelID = event.operation.channelID,
                  let channelName = event.operation.name else {
                throw NoctCordProjectionError.invalidEvent
            }
            guard channels[channelID] == nil else { throw NoctCordProjectionError.alreadyExists }
            channels[channelID] = NoctCordChannel(
                id: channelID,
                name: channelName,
                isArchived: false,
                permissionOverrides: [:],
                messageIDs: [],
                attachmentIDs: []
            )

        case .channelRenamed:
            try require(.manageChannels, for: event.author)
            guard let channelID = event.operation.channelID,
                  let channelName = event.operation.name,
                  var channel = channels[channelID] else {
                throw NoctCordProjectionError.missingDependency
            }
            channel.name = channelName
            channels[channelID] = channel

        case .channelArchived:
            try require(.manageChannels, for: event.author)
            guard let channelID = event.operation.channelID,
                  var channel = channels[channelID] else {
                throw NoctCordProjectionError.missingDependency
            }
            channel.isArchived = true
            channels[channelID] = channel

        case .roleDefined:
            try require(.manageRoles, for: event.author)
            guard let roleID = event.operation.roleID,
                  let roleName = event.operation.name,
                  let permissions = event.operation.permissions,
                  let position = event.operation.rolePosition else {
                throw NoctCordProjectionError.invalidEvent
            }
            let role = NoctCordRole(
                id: roleID,
                name: roleName,
                position: position,
                permissions: Set(permissions)
            )
            guard role.isStructurallyValid else { throw NoctCordProjectionError.invalidEvent }
            try requireRoleMutation(role, existing: roles[roleID], actor: event.author)
            roles[roleID] = role

        case .roleDeleted:
            try require(.manageRoles, for: event.author)
            guard let roleID = event.operation.roleID,
                  let role = roles[roleID] else {
                throw NoctCordProjectionError.missingDependency
            }
            try requireManageable(role, actor: event.author)
            roles.removeValue(forKey: roleID)
            for member in roleAssignments.keys {
                roleAssignments[member]?.remove(roleID)
            }
            for channelID in channels.keys {
                channels[channelID]?.permissionOverrides.removeValue(forKey: .role(roleID))
            }

        case .roleGranted:
            try require(.manageRoles, for: event.author)
            guard let roleID = event.operation.roleID,
                  let member = event.operation.memberHandle,
                  let role = roles[roleID],
                  activeMembers.contains(member) else {
                throw NoctCordProjectionError.missingDependency
            }
            try requireManageable(role, actor: event.author)
            try requireManageable(member: member, actor: event.author)
            roleAssignments[member, default: []].insert(roleID)

        case .roleRevoked:
            try require(.manageRoles, for: event.author)
            guard let roleID = event.operation.roleID,
                  let member = event.operation.memberHandle,
                  let role = roles[roleID],
                  activeMembers.contains(member) else {
                throw NoctCordProjectionError.missingDependency
            }
            try requireManageable(role, actor: event.author)
            try requireManageable(member: member, actor: event.author)
            roleAssignments[member]?.remove(roleID)

        case .channelPermissionSet:
            try require(.manageChannels, for: event.author)
            guard let channelID = event.operation.channelID,
                  let overwrite = event.operation.channelPermissionOverride,
                  var channel = channels[channelID] else {
                throw NoctCordProjectionError.missingDependency
            }
            try requirePermissionOverwriteMutation(overwrite, actor: event.author)
            channel.permissionOverrides[overwrite.target] = overwrite
            channels[channelID] = channel

        case .channelPermissionRemoved:
            try require(.manageChannels, for: event.author)
            guard let channelID = event.operation.channelID,
                  let overwrite = event.operation.channelPermissionOverride,
                  var channel = channels[channelID] else {
                throw NoctCordProjectionError.missingDependency
            }
            try requirePermissionOverwriteMutation(overwrite, actor: event.author)
            guard channel.permissionOverrides.removeValue(forKey: overwrite.target) != nil else {
                throw NoctCordProjectionError.missingDependency
            }
            channels[channelID] = channel

        case .messagePosted:
            guard let channelID = event.operation.channelID,
                  let messageID = event.operation.messageID,
                  let text = event.operation.text,
                  var channel = channels[channelID] else {
                throw NoctCordProjectionError.missingDependency
            }
            try require(.sendMessages, for: event.author, in: channelID)
            guard !channel.isArchived else { throw NoctCordProjectionError.archivedChannel }
            guard messages[messageID] == nil else { throw NoctCordProjectionError.alreadyExists }
            if let replyTo = event.operation.replyTo {
                guard messages[replyTo]?.channelID == channelID else {
                    throw NoctCordProjectionError.missingDependency
                }
            }
            messages[messageID] = NoctCordMessage(
                id: messageID,
                channelID: channelID,
                author: event.author,
                createdAt: event.createdAt,
                editedAt: nil,
                text: text,
                replyTo: event.operation.replyTo,
                isRetracted: false,
                isPinned: false,
                reactions: [:]
            )
            channel.messageIDs.append(messageID)
            channels[channelID] = channel

        case .messageEdited:
            guard let messageID = event.operation.messageID,
                  let text = event.operation.text,
                  var message = messages[messageID] else {
                throw NoctCordProjectionError.missingDependency
            }
            try require(.readMessages, for: event.author, in: message.channelID)
            try requireMessageOwnershipOrModeration(message, actor: event.author)
            message.text = text
            message.editedAt = event.createdAt
            messages[messageID] = message

        case .messageRetracted:
            guard let messageID = event.operation.messageID,
                  var message = messages[messageID] else {
                throw NoctCordProjectionError.missingDependency
            }
            try require(.readMessages, for: event.author, in: message.channelID)
            try requireMessageOwnershipOrModeration(message, actor: event.author)
            message.text = ""
            message.isRetracted = true
            message.reactions = [:]
            messages[messageID] = message

        case .reactionAdded:
            guard let messageID = event.operation.messageID,
                  let reaction = event.operation.reaction,
                  var message = messages[messageID],
                  !message.isRetracted else {
                throw NoctCordProjectionError.missingDependency
            }
            try require(.readMessages, for: event.author, in: message.channelID)
            try require(.addReactions, for: event.author, in: message.channelID)
            message.reactions[reaction, default: []].insert(event.author)
            messages[messageID] = message

        case .reactionRemoved:
            guard let messageID = event.operation.messageID,
                  let reaction = event.operation.reaction,
                  var message = messages[messageID] else {
                throw NoctCordProjectionError.missingDependency
            }
            try require(.readMessages, for: event.author, in: message.channelID)
            message.reactions[reaction]?.remove(event.author)
            if message.reactions[reaction]?.isEmpty == true {
                message.reactions.removeValue(forKey: reaction)
            }
            messages[messageID] = message

        case .messagePinned, .messageUnpinned:
            guard let messageID = event.operation.messageID,
                  var message = messages[messageID] else {
                throw NoctCordProjectionError.missingDependency
            }
            try require(.manageMessages, for: event.author, in: message.channelID)
            message.isPinned = event.operation.kind == .messagePinned
            messages[messageID] = message

        case .attachmentAdded:
            guard let channelID = event.operation.channelID,
                  let attachmentID = event.operation.attachmentID,
                  let manifest = event.operation.attachmentManifest,
                  var channel = channels[channelID] else {
                throw NoctCordProjectionError.missingDependency
            }
            try require(.sendMessages, for: event.author, in: channelID)
            try require(.attachFiles, for: event.author, in: channelID)
            guard !channel.isArchived else {
                throw NoctCordProjectionError.archivedChannel
            }
            guard manifest.expiresAt > event.createdAt else {
                throw NoctCordProjectionError.invalidEvent
            }
            guard attachments[attachmentID] == nil else {
                throw NoctCordProjectionError.alreadyExists
            }
            attachments[attachmentID] = manifest
            channel.attachmentIDs.append(attachmentID)
            channels[channelID] = channel

        case .voiceRoomCreated:
            try require(.manageChannels, for: event.author)
            guard let roomID = event.operation.voiceRoomID,
                  let spec = event.operation.voiceRoomSpec else {
                throw NoctCordProjectionError.invalidEvent
            }
            guard voiceRooms[roomID] == nil else {
                throw NoctCordProjectionError.alreadyExists
            }
            voiceRooms[roomID] = NoctCordVoiceRoom(
                id: roomID,
                name: spec.name,
                maxParticipants: spec.maxParticipants,
                signalingKey: spec.signalingKey,
                realtimeRoute: spec.realtimeRoute,
                isArchived: false
            )

        case .voiceRoomUpdated:
            try require(.manageChannels, for: event.author)
            guard let roomID = event.operation.voiceRoomID,
                  let spec = event.operation.voiceRoomSpec,
                  var room = voiceRooms[roomID] else {
                throw NoctCordProjectionError.missingDependency
            }
            guard !room.isArchived else { throw NoctCordProjectionError.archivedChannel }
            let joinedCount = voiceParticipants[roomID, default: [:]].values.filter(\.isJoined).count
            guard spec.maxParticipants >= joinedCount else {
                throw NoctCordProjectionError.invalidEvent
            }
            room.name = spec.name
            room.maxParticipants = spec.maxParticipants
            room.signalingKey = spec.signalingKey
            room.realtimeRoute = spec.realtimeRoute
            voiceRooms[roomID] = room

        case .voiceRoomArchived:
            try require(.manageChannels, for: event.author)
            guard let roomID = event.operation.voiceRoomID,
                  var room = voiceRooms[roomID] else {
                throw NoctCordProjectionError.missingDependency
            }
            room.isArchived = true
            voiceRooms[roomID] = room
            voiceParticipants.removeValue(forKey: roomID)
            activeScreenShares = activeScreenShares.filter { $0.value.roomID != roomID }

        case .voiceParticipantJoined, .voiceParticipantLeft,
             .voiceParticipantMuted, .voiceParticipantDeafened,
             .voiceParticipantSpeaking:
            try require(.connectVoice, for: event.author)
            guard let roomID = event.operation.voiceRoomID,
                  let state = event.operation.voiceParticipantState,
                  let room = voiceRooms[roomID],
                  !room.isArchived,
                  state.member == event.author else {
                throw NoctCordProjectionError.invalidEvent
            }
            let expectedKind: NoctCordEventKind
            switch event.operation.kind {
            case .voiceParticipantJoined: expectedKind = .voiceParticipantJoined
            case .voiceParticipantLeft: expectedKind = .voiceParticipantLeft
            case .voiceParticipantMuted: expectedKind = .voiceParticipantMuted
            case .voiceParticipantDeafened: expectedKind = .voiceParticipantDeafened
            case .voiceParticipantSpeaking: expectedKind = .voiceParticipantSpeaking
            default: throw NoctCordProjectionError.invalidEvent
            }
            guard event.operation.kind == expectedKind else {
                throw NoctCordProjectionError.invalidEvent
            }
            let existing = voiceParticipants[roomID]?[state.member]
            switch event.operation.kind {
            case .voiceParticipantJoined:
                guard state.isJoined, existing?.isJoined != true else {
                    throw NoctCordProjectionError.alreadyExists
                }
                guard voiceParticipants[roomID, default: [:]].values.filter(\.isJoined).count
                    < Int(room.maxParticipants) else {
                    throw NoctCordProjectionError.invalidEvent
                }
            case .voiceParticipantLeft:
                guard !state.isJoined, existing?.isJoined == true else {
                    throw NoctCordProjectionError.missingDependency
                }
            case .voiceParticipantMuted, .voiceParticipantDeafened,
                 .voiceParticipantSpeaking:
                guard state.isJoined, existing?.isJoined == true else {
                    throw NoctCordProjectionError.missingDependency
                }
            default: break
            }
            voiceParticipants[roomID, default: [:]][state.member] = state

        case .callSignalPosted:
            try require(.connectVoice, for: event.author)
            guard let roomID = event.operation.voiceRoomID,
                  let signal = event.operation.callSignal,
                  let room = voiceRooms[roomID],
                  !room.isArchived,
                  signal.keyID == room.signalingKeyID,
                  voiceParticipants[roomID]?[event.author]?.isJoined == true,
                  callSignals[signal.callID]?[signal.signalID] == nil else {
                if let signal = event.operation.callSignal,
                   callSignals[signal.callID]?[signal.signalID] != nil {
                    throw NoctCordProjectionError.alreadyExists
                }
                throw NoctCordProjectionError.missingDependency
            }
            callSignals[signal.callID, default: [:]][signal.signalID] = signal

        case .screenShareStarted:
            try require(.speakVoice, for: event.author)
            guard let roomID = event.operation.voiceRoomID,
                  let descriptor = event.operation.screenShare,
                  let room = voiceRooms[roomID],
                  !room.isArchived,
                  descriptor.presenter == event.author,
                  voiceParticipants[roomID]?[event.author]?.isJoined == true,
                  activeScreenShares[descriptor.shareID] == nil else {
                throw NoctCordProjectionError.missingDependency
            }
            activeScreenShares[descriptor.shareID] = NoctCordActiveScreenShare(
                roomID: roomID,
                descriptor: descriptor
            )

        case .screenShareStopped:
            try require(.speakVoice, for: event.author)
            guard let shareID = event.operation.screenShareID,
                  let activeShare = activeScreenShares[shareID],
                  activeShare.descriptor.presenter == event.author
                    || permissions(for: event.author).contains(.manageChannels) else {
                throw NoctCordProjectionError.missingDependency
            }
            activeScreenShares.removeValue(forKey: shareID)

        case .botInstalled:
            try require(.manageBots, for: event.author)
            guard let bot = event.operation.botApplication,
                  activeMembers.contains(bot.memberHandle),
                  bot.memberHandle != owner,
                  bot.memberHandle != event.author,
                  roleAssignments[bot.memberHandle, default: []].isEmpty,
                  botApplications[bot.id] == nil,
                  !botApplications.values.contains(where: { $0.memberHandle == bot.memberHandle })
            else {
                throw NoctCordProjectionError.alreadyExists
            }
            let commandNames = Set(bot.commands.map(\.name))
            guard botApplications.values.allSatisfy({ installed in
                Set(installed.commands.map(\.name)).isDisjoint(with: commandNames)
            }) else {
                throw NoctCordProjectionError.alreadyExists
            }
            botApplications[bot.id] = bot

        case .botUpdated:
            try require(.manageBots, for: event.author)
            guard let bot = event.operation.botApplication,
                  let existing = botApplications[bot.id],
                  existing.memberHandle == bot.memberHandle,
                  activeMembers.contains(bot.memberHandle) else {
                throw NoctCordProjectionError.missingDependency
            }
            let commandNames = Set(bot.commands.map(\.name))
            guard botApplications.values
                .filter({ $0.id != bot.id })
                .allSatisfy({ installed in
                    Set(installed.commands.map(\.name)).isDisjoint(with: commandNames)
                }) else {
                throw NoctCordProjectionError.alreadyExists
            }
            botApplications[bot.id] = bot

        case .botRemoved:
            try require(.manageBots, for: event.author)
            guard let botID = event.operation.botID,
                  botApplications.removeValue(forKey: botID) != nil else {
                throw NoctCordProjectionError.missingDependency
            }

        case .botCommandInvoked:
            guard let invocation = event.operation.botInvocation,
                  let bot = botApplications[invocation.botID],
                  bot.commands.contains(where: { $0.name == invocation.commandName }),
                  var channel = channels[invocation.channelID] else {
                throw NoctCordProjectionError.missingDependency
            }
            try require(.readMessages, for: event.author, in: invocation.channelID)
            try require(.sendMessages, for: event.author, in: invocation.channelID)
            try require(.useApplicationCommands, for: event.author, in: invocation.channelID)
            guard botInvocations[invocation.id] == nil,
                  messages[invocation.id] == nil else {
                throw NoctCordProjectionError.alreadyExists
            }
            botInvocations[invocation.id] = invocation
            let renderedCommand = invocation.arguments.isEmpty
                ? "/\(invocation.commandName)"
                : "/\(invocation.commandName) \(invocation.arguments)"
            messages[invocation.id] = NoctCordMessage(
                id: invocation.id,
                channelID: invocation.channelID,
                author: event.author,
                createdAt: event.createdAt,
                editedAt: nil,
                text: renderedCommand,
                replyTo: nil,
                isRetracted: false,
                isPinned: false,
                reactions: [:]
            )
            channel.messageIDs.append(invocation.id)
            channels[invocation.channelID] = channel
        }

        appliedEventIDs.insert(event.id)
        lastOrder = order
    }

    private func require(
        _ permission: NoctCordPermission,
        for member: GroupScopedMemberHandleV2
    ) throws {
        guard permissions(for: member).contains(permission) else {
            throw NoctCordProjectionError.permissionDenied(permission)
        }
    }

    private func require(
        _ permission: NoctCordPermission,
        for member: GroupScopedMemberHandleV2,
        in channelID: UUID
    ) throws {
        guard permissions(for: member, in: channelID).contains(permission) else {
            throw NoctCordProjectionError.permissionDenied(permission)
        }
    }

    private func requireMessageOwnershipOrModeration(
        _ message: NoctCordMessage,
        actor: GroupScopedMemberHandleV2
    ) throws {
        guard message.author == actor
            || permissions(for: actor, in: message.channelID).contains(.manageMessages) else {
            throw NoctCordProjectionError.permissionDenied(.manageMessages)
        }
    }

    private func requireRoleMutation(
        _ role: NoctCordRole,
        existing: NoctCordRole?,
        actor: GroupScopedMemberHandleV2
    ) throws {
        if let existing {
            try requireManageable(existing, actor: actor)
        }
        guard actor == owner || (
            role.position < highestRolePosition(for: actor)
                && !role.permissions.contains(.manageSpace)
                && Set(role.permissions).isSubset(of: permissions(for: actor))
        ) else {
            if actor == owner { return }
            throw NoctCordProjectionError.permissionDenied(.manageRoles)
        }
    }

    private func requireManageable(
        _ role: NoctCordRole,
        actor: GroupScopedMemberHandleV2
    ) throws {
        guard actor == owner || role.position < highestRolePosition(for: actor) else {
            throw NoctCordProjectionError.permissionDenied(.manageRoles)
        }
    }

    private func requireManageable(
        member: GroupScopedMemberHandleV2,
        actor: GroupScopedMemberHandleV2
    ) throws {
        guard actor == owner || (
            member != owner
                && member != actor
                && highestRolePosition(for: member) < highestRolePosition(for: actor)
        ) else {
            if actor == owner { return }
            throw NoctCordProjectionError.permissionDenied(.manageRoles)
        }
    }

    private func requirePermissionOverwriteMutation(
        _ overwrite: NoctCordChannelPermissionOverride,
        actor: GroupScopedMemberHandleV2
    ) throws {
        if let roleID = overwrite.roleID {
            guard let role = roles[roleID] else {
                throw NoctCordProjectionError.missingDependency
            }
            try requireManageable(role, actor: actor)
        }
        guard actor == owner
            || Set(overwrite.allow).isSubset(of: permissions(for: actor)) else {
            throw NoctCordProjectionError.permissionDenied(.manageChannels)
        }
    }
}

private struct EventOrder: Comparable, Equatable, Sendable {
    let logicalClock: UInt64
    let createdAt: Date
    let id: UUID

    init(_ event: NoctCordEvent) {
        logicalClock = event.logicalClock
        createdAt = event.createdAt
        id = event.id
    }

    static func < (lhs: Self, rhs: Self) -> Bool {
        if lhs.logicalClock != rhs.logicalClock { return lhs.logicalClock < rhs.logicalClock }
        if lhs.createdAt != rhs.createdAt { return lhs.createdAt < rhs.createdAt }
        return lhs.id.uuidString < rhs.id.uuidString
    }
}

private func canonicalOrder(_ lhs: NoctCordEvent, _ rhs: NoctCordEvent) -> Bool {
    EventOrder(lhs) < EventOrder(rhs)
}
