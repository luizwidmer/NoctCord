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
    public var messageIDs: [UUID]
}

public struct NoctCordMessage: Equatable, Identifiable {
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

public struct NoctCordProjectionResult: Equatable {
    public let projection: NoctCordSpaceProjection
    public let rejectedEvents: [NoctCordRejectedEvent]
}

/// Deterministic local materialization of encrypted Noct Cord events.
/// No relay stores or evaluates this state.
public struct NoctCordSpaceProjection: Equatable {
    public let spaceID: UUID
    public let owner: GroupScopedMemberHandleV2
    public private(set) var name: String?
    public private(set) var activeMembers: Set<GroupScopedMemberHandleV2>
    public private(set) var channels: [UUID: NoctCordChannel]
    public private(set) var roles: [UUID: NoctCordRole]
    public private(set) var roleAssignments: [GroupScopedMemberHandleV2: Set<UUID>]
    public private(set) var messages: [UUID: NoctCordMessage]
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
        messages = [:]
        appliedEventIDs = []
        lastOrder = nil
    }

    public static func project(
        spaceID: UUID,
        owner: GroupScopedMemberHandleV2,
        activeMembers: Set<GroupScopedMemberHandleV2>,
        events: [NoctCordEvent]
    ) -> NoctCordProjectionResult {
        var projection = NoctCordSpaceProjection(
            spaceID: spaceID,
            owner: owner,
            activeMembers: activeMembers
        )
        var rejected: [NoctCordRejectedEvent] = []
        for event in events.sorted(by: canonicalOrder) {
            do {
                try projection.apply(event)
            } catch {
                rejected.append(
                    NoctCordRejectedEvent(eventID: event.id, reason: String(describing: error))
                )
            }
        }
        return NoctCordProjectionResult(projection: projection, rejectedEvents: rejected)
    }

    public mutating func reconcileMembership(
        _ members: Set<GroupScopedMemberHandleV2>
    ) {
        activeMembers = members.union([owner])
        roleAssignments = roleAssignments.filter { activeMembers.contains($0.key) }
    }

    public func permissions(for member: GroupScopedMemberHandleV2) -> Set<NoctCordPermission> {
        guard activeMembers.contains(member) else { return [] }
        if member == owner { return Set(NoctCordPermission.allCases) }
        var result: Set<NoctCordPermission> = [.readMessages, .sendMessages]
        for roleID in roleAssignments[member, default: []] {
            result.formUnion(roles[roleID]?.permissions ?? [])
        }
        return result
    }

    public mutating func apply(_ event: NoctCordEvent) throws {
        guard event.isStructurallyValid else { throw NoctCordProjectionError.invalidEvent }
        guard event.spaceID == spaceID else { throw NoctCordProjectionError.wrongSpace }
        if appliedEventIDs.contains(event.id) { return }
        guard activeMembers.contains(event.author) else {
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
                messageIDs: []
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
                  let permissions = event.operation.permissions else {
                throw NoctCordProjectionError.invalidEvent
            }
            let role = NoctCordRole(id: roleID, name: roleName, permissions: Set(permissions))
            guard role.isStructurallyValid else { throw NoctCordProjectionError.invalidEvent }
            roles[roleID] = role

        case .roleDeleted:
            try require(.manageRoles, for: event.author)
            guard let roleID = event.operation.roleID,
                  roles.removeValue(forKey: roleID) != nil else {
                throw NoctCordProjectionError.missingDependency
            }
            for member in roleAssignments.keys {
                roleAssignments[member]?.remove(roleID)
            }

        case .roleGranted:
            try require(.manageRoles, for: event.author)
            guard let roleID = event.operation.roleID,
                  let member = event.operation.memberHandle,
                  roles[roleID] != nil,
                  activeMembers.contains(member) else {
                throw NoctCordProjectionError.missingDependency
            }
            roleAssignments[member, default: []].insert(roleID)

        case .roleRevoked:
            try require(.manageRoles, for: event.author)
            guard let roleID = event.operation.roleID,
                  let member = event.operation.memberHandle,
                  roles[roleID] != nil else {
                throw NoctCordProjectionError.missingDependency
            }
            roleAssignments[member]?.remove(roleID)

        case .messagePosted:
            try require(.sendMessages, for: event.author)
            guard let channelID = event.operation.channelID,
                  let messageID = event.operation.messageID,
                  let text = event.operation.text,
                  var channel = channels[channelID] else {
                throw NoctCordProjectionError.missingDependency
            }
            guard !channel.isArchived else { throw NoctCordProjectionError.archivedChannel }
            guard messages[messageID] == nil else { throw NoctCordProjectionError.alreadyExists }
            if let replyTo = event.operation.replyTo, messages[replyTo] == nil {
                throw NoctCordProjectionError.missingDependency
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
            try requireMessageOwnershipOrModeration(message, actor: event.author)
            message.text = text
            message.editedAt = event.createdAt
            messages[messageID] = message

        case .messageRetracted:
            guard let messageID = event.operation.messageID,
                  var message = messages[messageID] else {
                throw NoctCordProjectionError.missingDependency
            }
            try requireMessageOwnershipOrModeration(message, actor: event.author)
            message.text = ""
            message.isRetracted = true
            message.reactions = [:]
            messages[messageID] = message

        case .reactionAdded:
            try require(.readMessages, for: event.author)
            guard let messageID = event.operation.messageID,
                  let reaction = event.operation.reaction,
                  var message = messages[messageID],
                  !message.isRetracted else {
                throw NoctCordProjectionError.missingDependency
            }
            message.reactions[reaction, default: []].insert(event.author)
            messages[messageID] = message

        case .reactionRemoved:
            try require(.readMessages, for: event.author)
            guard let messageID = event.operation.messageID,
                  let reaction = event.operation.reaction,
                  var message = messages[messageID] else {
                throw NoctCordProjectionError.missingDependency
            }
            message.reactions[reaction]?.remove(event.author)
            if message.reactions[reaction]?.isEmpty == true {
                message.reactions.removeValue(forKey: reaction)
            }
            messages[messageID] = message

        case .messagePinned, .messageUnpinned:
            try require(.manageMessages, for: event.author)
            guard let messageID = event.operation.messageID,
                  var message = messages[messageID] else {
                throw NoctCordProjectionError.missingDependency
            }
            message.isPinned = event.operation.kind == .messagePinned
            messages[messageID] = message
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

    private func requireMessageOwnershipOrModeration(
        _ message: NoctCordMessage,
        actor: GroupScopedMemberHandleV2
    ) throws {
        guard message.author == actor || permissions(for: actor).contains(.manageMessages) else {
            throw NoctCordProjectionError.permissionDenied(.manageMessages)
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
