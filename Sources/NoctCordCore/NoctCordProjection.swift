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
    /// Exact outer events authorized during replay, excluding duplicate IDs
    /// already applied directly or through an owner bootstrap.
    public let acceptedEvents: [NoctCordEvent]
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
    public private(set) var identityBindings: [GroupScopedMemberHandleV2: NoctCordCommunityIdentityBindingV1]
    public private(set) var messages: [UUID: NoctCordMessage]
    public private(set) var attachments: [UUID: NoctCordAttachmentManifestV1]
    public private(set) var voiceRooms: [UUID: NoctCordVoiceRoom]
    public private(set) var voiceParticipants: [UUID: [GroupScopedMemberHandleV2: NoctCordVoiceParticipantStateV1]]
    public private(set) var callSignals: [UUID: [UUID: NoctCordEncryptedCallSignalV1]]
    public private(set) var activeScreenShares: [UUID: NoctCordActiveScreenShare]
    public private(set) var appliedEventIDs: Set<UUID>

    private var lastOrder: EventOrder?
    private var verifiedV2EventCount: UInt64

    /// Checkpoint retirement may change replay bookkeeping and accepted
    /// checkpoint IDs. It is safe only when every user-visible durable and
    /// ephemeral projection field remains identical.
    package func hasSameRetainedState(as other: Self) -> Bool {
        spaceID == other.spaceID
            && owner == other.owner
            && name == other.name
            && activeMembers == other.activeMembers
            && channels == other.channels
            && roles == other.roles
            && roleAssignments == other.roleAssignments
            && botApplications == other.botApplications
            && botInvocations == other.botInvocations
            && identityBindings == other.identityBindings
            && messages == other.messages
            && attachments == other.attachments
            && voiceRooms == other.voiceRooms
            && voiceParticipants == other.voiceParticipants
            && callSignals == other.callSignals
            && activeScreenShares == other.activeScreenShares
    }

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
        identityBindings = [:]
        messages = [:]
        attachments = [:]
        voiceRooms = [:]
        voiceParticipants = [:]
        callSignals = [:]
        activeScreenShares = [:]
        appliedEventIDs = []
        lastOrder = nil
        verifiedV2EventCount = 0
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
        var accepted: [NoctCordEvent] = []
        var rejected: [NoctCordRejectedEvent] = []
        for event in events.sorted(by: canonicalOrder) {
            do {
                let wasAlreadyApplied = projection.appliedEventIDs.contains(event.id)
                try projection.apply(
                    event,
                    permittingHistoricalAuthor: historicalMembers.contains(event.author)
                )
                if !wasAlreadyApplied { accepted.append(event) }
            } catch {
                rejected.append(
                    NoctCordRejectedEvent(eventID: event.id, reason: String(describing: error))
                )
            }
        }
        projection.reconcileMembership(activeMembers)
        return NoctCordProjectionResult(
            projection: projection, acceptedEvents: accepted, rejectedEvents: rejected
        )
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
        identityBindings = identityBindings.filter { activeMembers.contains($0.key) }
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

    /// An accepted command can wait in history while its author loses access.
    /// Bot handlers and publication retries must use current channel policy,
    /// not only the permission verdict from when the event was first applied.
    public func isBotInvocationCurrentlyAuthorized(_ event: NoctCordEvent) -> Bool {
        guard event.spaceID == spaceID,
              event.operation.kind == .botCommandInvoked,
              let invocation = event.operation.botInvocation,
              botInvocations[invocation.id] == invocation,
              messages[invocation.id]?.author == event.author,
              messages[invocation.id]?.channelID == invocation.channelID,
              let bot = botApplications[invocation.botID],
              activeMembers.contains(bot.memberHandle),
              bot.commands.contains(where: { $0.name == invocation.commandName }) else {
            return false
        }
        let current = permissions(for: event.author, in: invocation.channelID)
        return current.isSuperset(of: [
            .readMessages, .sendMessages, .useApplicationCommands,
        ])
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

    /// A bounded owner-authored snapshot for a v2 policy checkpoint. It
    /// contains durable configuration only; member messages and call activity
    /// remain independently signed events. The caller must reject an oversized
    /// snapshot rather than publish a partial authorization state.
    public func checkpointConfiguration(createdAt: Date) throws -> [NoctCordEvent] {
        guard let name else { throw NoctCordProjectionError.missingDependency }
        var events: [NoctCordEvent] = []
        func append(_ operation: NoctCordOperation) {
            let index = events.count
            let operationBytes = (try? NoctweaveCoder.encode(
                operation, sortedKeys: true
            )) ?? Data()
            var material = Data("NoctCord/checkpoint-config-event/v2\0".utf8)
            material.append(Data(spaceID.uuidString.utf8))
            material.append(Data(String(index).utf8))
            material.append(operationBytes)
            let digest = Array(SHA256.hash(data: material))
            let stableID = UUID(uuid: (
                digest[0], digest[1], digest[2], digest[3],
                digest[4], digest[5], digest[6], digest[7],
                digest[8], digest[9], digest[10], digest[11],
                digest[12], digest[13], digest[14], digest[15]
            ))
            events.append(NoctCordEvent(
                id: stableID,
                spaceID: spaceID,
                author: owner,
                logicalClock: UInt64(index + 1),
                // Synthetic snapshots must be reproducible after a crash.
                createdAt: Date(timeIntervalSince1970: 1_577_836_800
                    + TimeInterval(index)),
                operation: operation
            ))
        }

        append(.createSpace(name: name))
        for channel in channels.values.sorted(by: { $0.id.uuidString < $1.id.uuidString }) {
            append(.createChannel(id: channel.id, name: channel.name))
            if channel.isArchived { append(.archiveChannel(id: channel.id)) }
        }
        for role in roles.values.sorted(by: { $0.id.uuidString < $1.id.uuidString }) {
            append(.defineRole(role))
        }
        // Installation requires an unassigned bot member. A role may be
        // granted later, so preserve that valid ordering in snapshots.
        for bot in botApplications.values.sorted(by: { $0.id.uuidString < $1.id.uuidString }) {
            append(.installBot(bot))
        }
        for member in roleAssignments.keys.sorted(by: { $0.rawValue < $1.rawValue }) {
            for roleID in roleAssignments[member, default: []].sorted(by: {
                $0.uuidString < $1.uuidString
            }) {
                append(.grantRole(id: roleID, to: member))
            }
        }
        for channel in channels.values.sorted(by: { $0.id.uuidString < $1.id.uuidString }) {
            for target in channel.permissionOverrides.keys.sorted(by: {
                switch ($0, $1) {
                case (.everyone, .role): true
                case (.role, .everyone): false
                case (.everyone, .everyone): false
                case (.role(let lhs), .role(let rhs)):
                    lhs.uuidString < rhs.uuidString
                }
            }) {
                guard let override = channel.permissionOverrides[target] else { continue }
                append(.setChannelPermissions(
                    channelID: channel.id,
                    roleID: override.roleID,
                    allow: Set(override.allow),
                    deny: Set(override.deny)
                ))
            }
        }
        for room in voiceRooms.values.sorted(by: { $0.id.uuidString < $1.id.uuidString }) {
            append(.createVoiceRoom(id: room.id, spec: NoctCordVoiceRoomSpecV1(
                name: room.name,
                maxParticipants: room.maxParticipants,
                signalingKey: room.signalingKey,
                realtimeRoute: room.realtimeRoute
            )))
            if room.isArchived { append(.archiveVoiceRoom(id: room.id)) }
        }
        let encoded = try NoctweaveCoder.encode(events, sortedKeys: true)
        guard events.count <= 64 * 128,
              encoded.count <= 4 * 1_024 * 1_024,
              Set(events.map(\.id)).count == events.count,
              events.allSatisfy(\.isStructurallyValid) else {
            throw NoctCordProjectionError.invalidEvent
        }
        return events
    }

    public func highestRolePosition(for member: GroupScopedMemberHandleV2) -> UInt16 {
        member == owner ? .max : (roles(for: member).map(\.position).max() ?? 0)
    }

    public mutating func apply(_ event: NoctCordEvent) throws {
        try apply(event, permittingHistoricalAuthor: false, enforcingOrder: true)
    }

    /// Core receipts and owner checkpoints provide the ordering boundary in
    /// v2. A sender-chosen application clock cannot reject a later policy
    /// transition or move an event across that boundary. The v1 projection
    /// path continues to enforce its original canonical clock order.
    package mutating func applyVerifiedV2(
        _ event: NoctCordEvent,
        permittingHistoricalAuthor: Bool
    ) throws {
        try apply(
            event,
            permittingHistoricalAuthor: permittingHistoricalAuthor,
            enforcingOrder: false
        )
        // An admitted peer controls `logicalClock`. It must not be able to
        // pin local publication at the maximum clock or force a gap failure.
        // Verified v2 order comes from Core receipts and owner frontiers.
        if verifiedV2EventCount < NoctCordEvent.maximumLogicalClock {
            verifiedV2EventCount += 1
        }
    }

    /// Applies one fully verified owner snapshot assembled from one or more
    /// signed checkpoint fragments. The caller verifies every fragment and
    /// the aggregate digest before this method can change policy.
    package mutating func applyVerifiedConfigurationSnapshot(
        _ events: [NoctCordEvent]
    ) throws {
        guard !events.isEmpty,
              events.count <= 64 * 128,
              Set(events.map(\.id)).count == events.count,
              events.allSatisfy({
                  $0.spaceID == spaceID && $0.author == owner
                      && $0.operation.kind.isBootstrapConfiguration
                      && $0.isStructurallyValid
              }) else {
            throw NoctCordProjectionError.invalidEvent
        }
        var candidate = self
        for nested in events.sorted(by: canonicalOrder) {
            try candidate.apply(
                nested,
                permittingHistoricalAuthor: true,
                enforcingOrder: false
            )
        }
        self = candidate
        noteVerifiedV2Boundary()
    }

    /// An owner snapshot after the first v2 checkpoint bootstraps a new
    /// member. Existing members verify its configuration without resetting
    /// retained messages, attachments, reactions, or call activity.
    func hasSameDurableConfiguration(
        as other: Self,
        allowingEpochVoiceCredentialRotation: Bool = false
    ) -> Bool {
        guard name == other.name,
              roles == other.roles,
              roleAssignments == other.roleAssignments,
              botApplications == other.botApplications,
              Set(voiceRooms.keys) == Set(other.voiceRooms.keys),
              Set(channels.keys) == Set(other.channels.keys) else {
            return false
        }
        guard voiceRooms.allSatisfy({ id, room in
            guard let candidate = other.voiceRooms[id] else { return false }
            return room.name == candidate.name
                && room.maxParticipants == candidate.maxParticipants
                && room.isArchived == candidate.isArchived
                && (allowingEpochVoiceCredentialRotation
                    || (room.signalingKey == candidate.signalingKey
                        && room.realtimeRoute == candidate.realtimeRoute))
        }) else { return false }
        return channels.allSatisfy { id, channel in
            guard let candidate = other.channels[id] else { return false }
            return channel.name == candidate.name
                && channel.isArchived == candidate.isArchived
                && channel.permissionOverrides == candidate.permissionOverrides
        }
    }

    /// A Core-signed epoch transition and owner checkpoint may replace only
    /// voice signaling secrets/routes while preserving durable room identity.
    /// Old ephemeral call state cannot be carried into that new epoch.
    mutating func adoptVerifiedEpochVoiceCredentials(from other: Self) {
        voiceRooms = other.voiceRooms
        voiceParticipants = [:]
        callSignals = [:]
        activeScreenShares = [:]
    }

    mutating func noteVerifiedV2Boundary() {
        if verifiedV2EventCount < NoctCordEvent.maximumLogicalClock {
            verifiedV2EventCount += 1
        }
    }

    /// Rejected events never contribute to the next local clock. Only the
    /// owner's configuration bootstrap may bridge an arbitrarily large gap
    /// for a new member that did not receive the preceding group history.
    public func nextLogicalClock() throws -> UInt64 {
        let previous = max(lastOrder?.logicalClock ?? 0, verifiedV2EventCount)
        guard previous < NoctCordEvent.maximumLogicalClock else {
            throw NoctCordProjectionError.invalidEvent
        }
        return previous + 1
    }

    private mutating func apply(
        _ event: NoctCordEvent,
        permittingHistoricalAuthor: Bool,
        enforcingOrder: Bool = true
    ) throws {
        guard event.isStructurallyValid else { throw NoctCordProjectionError.invalidEvent }
        guard event.spaceID == spaceID else { throw NoctCordProjectionError.wrongSpace }
        if appliedEventIDs.contains(event.id) { return }
        guard activeMembers.contains(event.author) || permittingHistoricalAuthor else {
            throw NoctCordProjectionError.inactiveMember
        }
        let order = EventOrder(event)
        if enforcingOrder, let lastOrder, order < lastOrder {
            throw NoctCordProjectionError.outOfOrder
        }
        if enforcingOrder,
           !(event.author == owner && event.operation.kind == .bootstrapApplied) {
            let previous = lastOrder?.logicalClock ?? 0
            guard event.logicalClock <= previous
                    || event.logicalClock - previous <= 1_024 else {
                throw NoctCordProjectionError.outOfOrder
            }
        }

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
                if roleAssignments[member]?.isEmpty == true {
                    roleAssignments.removeValue(forKey: member)
                }
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
            // Rank alone is insufficient: an owner-created lower role may
            // contain administrator or other permissions the actor lacks.
            try requireRoleMutation(role, existing: nil, actor: event.author)
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
            if roleAssignments[member]?.isEmpty == true {
                roleAssignments.removeValue(forKey: member)
            }

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
            try require(.sendMessages, for: event.author, in: message.channelID)
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

        case .identityBound:
            guard let binding = event.operation.identityBinding,
                  binding.spaceID == spaceID,
                  binding.memberHandle == event.author,
                  try binding.verify() else {
                throw NoctCordProjectionError.invalidEvent
            }
            if let existing = identityBindings[event.author],
               binding.issuedAt < existing.issuedAt {
                throw NoctCordProjectionError.outOfOrder
            }
            identityBindings[event.author] = binding

        case .bootstrapRequested:
            break

        case .bootstrapApplied:
            guard event.author == owner,
                  let events = event.operation.bootstrapEvents else {
                throw NoctCordProjectionError.permissionDenied(.manageSpace)
            }
            var candidate = self
            for nested in events.sorted(by: canonicalOrder) {
                if nested.operation.kind == .identityBound { continue }
                guard nested.operation.kind.isBootstrapConfiguration else {
                    throw NoctCordProjectionError.invalidEvent
                }
                try candidate.apply(
                    nested,
                    permittingHistoricalAuthor: true,
                    enforcingOrder: false
                )
            }
            self = candidate
        }

        appliedEventIDs.insert(event.id)
        if enforcingOrder { lastOrder = order }
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
