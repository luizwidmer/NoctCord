import Foundation
import SwiftUI
import NoctCordCore
@preconcurrency import NoctweaveCore

public enum NoctCordPresence: String, Equatable, Sendable {
    case active
    case away
    case offline
}

public struct NoctCordMemberViewState: Identifiable, Equatable {
    public let id: GroupScopedMemberHandleV2
    public let displayName: String
    public let roleName: String
    public let presence: NoctCordPresence

    public var initials: String {
        displayName
            .split(separator: " ")
            .prefix(2)
            .compactMap(\.first)
            .map(String.init)
            .joined()
            .uppercased()
    }
}

public struct NoctCordVoiceRoom: Identifiable, Equatable {
    public let id: UUID
    public let name: String
    public let participantCount: Int
}

public struct NoctCordMessagePresentation: Identifiable, Equatable {
    public let id: UUID
    public let authorID: GroupScopedMemberHandleV2
    public let authorName: String
    public let authorInitials: String
    public let createdAt: Date
    public let editedAt: Date?
    public let text: String
    public let isRetracted: Bool
    public let isPinned: Bool
    public let reactions: [(value: String, count: Int, selected: Bool)]

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.id == rhs.id
            && lhs.authorID == rhs.authorID
            && lhs.authorName == rhs.authorName
            && lhs.authorInitials == rhs.authorInitials
            && lhs.createdAt == rhs.createdAt
            && lhs.editedAt == rhs.editedAt
            && lhs.text == rhs.text
            && lhs.isRetracted == rhs.isRetracted
            && lhs.isPinned == rhs.isPinned
            && lhs.reactions.map { "\($0.value):\($0.count):\($0.selected)" }
                == rhs.reactions.map { "\($0.value):\($0.count):\($0.selected)" }
    }
}

public struct NoctCordSpaceSession: Identifiable, Equatable {
    public let id: UUID
    public var shortName: String
    public var currentMember: GroupScopedMemberHandleV2
    public var identityScope: NoctCordIdentityScope
    public var members: [NoctCordMemberViewState]
    public var events: [NoctCordEvent]
    public var projection: NoctCordSpaceProjection
    public var unreadByChannel: [UUID: Int]
    public var voiceRooms: [NoctCordVoiceRoom]
    public var activeVoiceRoomID: UUID?
    public var relayName: String
    public var relayAssessment: NoctCordRelayAssessment

    public var name: String { projection.name ?? "Untitled space" }

    public var textChannels: [NoctCordChannel] {
        projection.channels.values
            .filter { !$0.isArchived }
            .sorted { lhs, rhs in
                if lhs.name == "general" { return rhs.name != "general" }
                if rhs.name == "general" { return false }
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
    }

    public var canManageChannels: Bool {
        projection.permissions(for: currentMember).contains(.manageChannels)
    }
}

@MainActor
public final class NoctCordAppModel: ObservableObject {
    @Published public private(set) var spaces: [NoctCordSpaceSession]
    @Published public var selectedSpaceID: UUID?
    @Published public var selectedChannelID: UUID?
    @Published public var composerText = ""
    @Published public var searchQuery = ""
    @Published public var showsMemberInspector = true
    @Published public var showsCreateSpace = false
    @Published public var showsCreateChannel = false
    @Published public var showsIdentity = false
    @Published public var appearance: NoctCordAppearance = .system

    public init(seedPreviewData: Bool = true) {
        spaces = seedPreviewData ? Self.previewSpaces() : []
        selectedSpaceID = spaces.first?.id
        selectedChannelID = spaces.first?.textChannels.first?.id
    }

    public var selectedSpace: NoctCordSpaceSession? {
        guard let selectedSpaceID else { return nil }
        return spaces.first { $0.id == selectedSpaceID }
    }

    public var selectedChannel: NoctCordChannel? {
        guard let selectedChannelID else { return nil }
        return selectedSpace?.projection.channels[selectedChannelID]
    }

    public var selectedMessages: [NoctCordMessagePresentation] {
        guard let space = selectedSpace,
              let channel = selectedChannel else { return [] }
        let memberLookup = Dictionary(uniqueKeysWithValues: space.members.map { ($0.id, $0) })
        let normalizedSearch = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        return channel.messageIDs.compactMap { messageID in
            guard let message = space.projection.messages[messageID] else { return nil }
            if !normalizedSearch.isEmpty,
               !message.text.localizedCaseInsensitiveContains(normalizedSearch),
               !(memberLookup[message.author]?.displayName.localizedCaseInsensitiveContains(normalizedSearch) ?? false) {
                return nil
            }
            let member = memberLookup[message.author]
            let reactions = message.reactions.keys.sorted().map { value in
                let authors = message.reactions[value, default: []]
                return (
                    value: value,
                    count: authors.count,
                    selected: authors.contains(space.currentMember)
                )
            }
            return NoctCordMessagePresentation(
                id: message.id,
                authorID: message.author,
                authorName: member?.displayName ?? "Unknown member",
                authorInitials: member?.initials ?? "?",
                createdAt: message.createdAt,
                editedAt: message.editedAt,
                text: message.text,
                isRetracted: message.isRetracted,
                isPinned: message.isPinned,
                reactions: reactions
            )
        }
    }

    public var currentMember: NoctCordMemberViewState? {
        guard let space = selectedSpace else { return nil }
        return space.members.first { $0.id == space.currentMember }
    }

    public func selectSpace(_ id: UUID) {
        selectedSpaceID = id
        selectedChannelID = spaces.first { $0.id == id }?.textChannels.first?.id
        searchQuery = ""
    }

    public func selectChannel(_ id: UUID) {
        selectedChannelID = id
        searchQuery = ""
        updateSelectedSpace { space in
            space.unreadByChannel[id] = 0
        }
    }

    public func sendCurrentMessage() {
        let text = composerText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty,
              let channelID = selectedChannelID else { return }
        updateSelectedSpace { space in
            let event = NoctCordEvent(
                spaceID: space.id,
                author: space.currentMember,
                logicalClock: Self.nextClock(in: space.events),
                operation: .postMessage(
                    id: UUID(),
                    channelID: channelID,
                    text: text
                )
            )
            space.events.append(event)
            Self.rebuild(&space)
        }
        composerText = ""
    }

    public func toggleReaction(_ value: String, messageID: UUID) {
        updateSelectedSpace { space in
            let selected = space.projection.messages[messageID]?.reactions[value]?.contains(
                space.currentMember
            ) == true
            let operation: NoctCordOperation = selected
                ? .removeReaction(value, from: messageID)
                : .addReaction(value, to: messageID)
            space.events.append(
                NoctCordEvent(
                    spaceID: space.id,
                    author: space.currentMember,
                    logicalClock: Self.nextClock(in: space.events),
                    operation: operation
                )
            )
            Self.rebuild(&space)
        }
    }

    public func createSpace(name: String, identityScope: NoctCordIdentityScope) {
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanName.isEmpty else { return }
        let owner = GroupScopedMemberHandleV2.generate()
        let spaceID = UUID()
        let channelID = UUID()
        let events = [
            NoctCordEvent(
                spaceID: spaceID,
                author: owner,
                logicalClock: 1,
                operation: .createSpace(name: cleanName)
            ),
            NoctCordEvent(
                spaceID: spaceID,
                author: owner,
                logicalClock: 2,
                operation: .createChannel(id: channelID, name: "general")
            ),
        ]
        let projection = NoctCordSpaceProjection.project(
            spaceID: spaceID,
            owner: owner,
            activeMembers: [owner],
            events: events
        ).projection
        let session = NoctCordSpaceSession(
            id: spaceID,
            shortName: Self.shortName(cleanName),
            currentMember: owner,
            identityScope: identityScope,
            members: [
                NoctCordMemberViewState(
                    id: owner,
                    displayName: "You",
                    roleName: "Owner",
                    presence: .active
                )
            ],
            events: events,
            projection: projection,
            unreadByChannel: [:],
            voiceRooms: [],
            activeVoiceRoomID: nil,
            relayName: "No relay selected",
            relayAssessment: Self.fallbackRelayAssessment()
        )
        spaces.append(session)
        selectedSpaceID = spaceID
        selectedChannelID = channelID
        showsCreateSpace = false
    }

    public func createChannel(name: String) {
        let cleanName = name
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: " ", with: "-")
        guard !cleanName.isEmpty,
              selectedSpace?.canManageChannels == true else {
            showsCreateChannel = false
            return
        }
        let channelID = UUID()
        updateSelectedSpace { space in
            space.events.append(
                NoctCordEvent(
                    spaceID: space.id,
                    author: space.currentMember,
                    logicalClock: Self.nextClock(in: space.events),
                    operation: .createChannel(id: channelID, name: cleanName)
                )
            )
            Self.rebuild(&space)
        }
        if selectedSpace?.projection.channels[channelID] != nil {
            selectedChannelID = channelID
        }
        showsCreateChannel = false
    }

    public func joinVoiceRoom(_ id: UUID) {
        updateSelectedSpace { space in
            space.activeVoiceRoomID = space.activeVoiceRoomID == id ? nil : id
        }
    }

    public func setIdentityScope(_ scope: NoctCordIdentityScope) {
        updateSelectedSpace { space in
            space.identityScope = scope
        }
    }

    private func updateSelectedSpace(_ update: (inout NoctCordSpaceSession) -> Void) {
        guard let selectedSpaceID,
              let index = spaces.firstIndex(where: { $0.id == selectedSpaceID }) else { return }
        update(&spaces[index])
    }

    private static func rebuild(_ space: inout NoctCordSpaceSession) {
        space.projection = NoctCordSpaceProjection.project(
            spaceID: space.id,
            owner: space.projection.owner,
            activeMembers: Set(space.members.map(\.id)),
            events: space.events
        ).projection
    }

    private static func nextClock(in events: [NoctCordEvent]) -> UInt64 {
        (events.map(\.logicalClock).max() ?? 0) + 1
    }

    private static func shortName(_ name: String) -> String {
        name.split(separator: " ")
            .prefix(2)
            .compactMap(\.first)
            .map(String.init)
            .joined()
            .uppercased()
    }
}

private extension NoctCordAppModel {
    static func previewSpaces() -> [NoctCordSpaceSession] {
        [makeNightShift(), makeProtocolGuild()]
    }

    static func makeNightShift() -> NoctCordSpaceSession {
        let spaceID = UUID(uuidString: "10000000-0000-0000-0000-000000000001")!
        let general = UUID(uuidString: "20000000-0000-0000-0000-000000000001")!
        let buildRoom = UUID(uuidString: "20000000-0000-0000-0000-000000000002")!
        let fieldNotes = UUID(uuidString: "20000000-0000-0000-0000-000000000003")!
        let owner = handle(1)
        let aster = handle(2)
        let mara = handle(3)
        let ivo = handle(4)
        let now = Date()
        let messages: [(GroupScopedMemberHandleV2, UUID, String, TimeInterval)] = [
            (owner, general, "Welcome to Night Shift. This space is running on compact realtime delivery.", -3_900),
            (aster, general, "The channel projection is clean now. I also checked the new identity binding flow.", -3_240),
            (mara, general, "Portable for the public rooms, isolated for anything sensitive. That split feels right.", -2_760),
            (owner, buildRoom, "I pushed the compact record codec. The sample event dropped from 400 bytes to 144.", -1_920),
            (ivo, buildRoom, "Nice. I’ll test the cursor path against the Linux relay next.", -1_260),
            (aster, fieldNotes, "Reminder: realtime mode leaks timing and approximate size. We should keep that visible in relay setup.", -420),
        ]
        var events: [NoctCordEvent] = []
        var clock: UInt64 = 1
        func append(_ author: GroupScopedMemberHandleV2, _ operation: NoctCordOperation, _ date: Date) {
            events.append(
                NoctCordEvent(
                    spaceID: spaceID,
                    author: author,
                    logicalClock: clock,
                    createdAt: date,
                    operation: operation
                )
            )
            clock += 1
        }
        append(owner, .createSpace(name: "Night Shift"), now.addingTimeInterval(-4_800))
        append(owner, .createChannel(id: general, name: "general"), now.addingTimeInterval(-4_700))
        append(owner, .createChannel(id: buildRoom, name: "build-room"), now.addingTimeInterval(-4_600))
        append(owner, .createChannel(id: fieldNotes, name: "field-notes"), now.addingTimeInterval(-4_500))
        for (author, channel, text, offset) in messages {
            append(
                author,
                .postMessage(id: UUID(), channelID: channel, text: text),
                now.addingTimeInterval(offset)
            )
        }
        if let firstGeneralMessage = events.first(where: {
            $0.operation.kind == .messagePosted && $0.operation.channelID == general
        })?.operation.messageID {
            append(aster, .addReaction("🌙", to: firstGeneralMessage), now.addingTimeInterval(-3_100))
            append(mara, .addReaction("✓", to: firstGeneralMessage), now.addingTimeInterval(-3_000))
        }
        let members = [
            NoctCordMemberViewState(id: owner, displayName: "You", roleName: "Owner", presence: .active),
            NoctCordMemberViewState(id: aster, displayName: "Aster", roleName: "Maintainer", presence: .active),
            NoctCordMemberViewState(id: mara, displayName: "Mara", roleName: "Member", presence: .away),
            NoctCordMemberViewState(id: ivo, displayName: "Ivo", roleName: "Member", presence: .offline),
        ]
        let projection = NoctCordSpaceProjection.project(
            spaceID: spaceID,
            owner: owner,
            activeMembers: Set(members.map(\.id)),
            events: events
        ).projection
        return NoctCordSpaceSession(
            id: spaceID,
            shortName: "NS",
            currentMember: owner,
            identityScope: .portable,
            members: members,
            events: events,
            projection: projection,
            unreadByChannel: [buildRoom: 2, fieldNotes: 1],
            voiceRooms: [
                NoctCordVoiceRoom(id: UUID(), name: "Workbench", participantCount: 2),
                NoctCordVoiceRoom(id: UUID(), name: "Quiet room", participantCount: 0),
            ],
            activeVoiceRoomID: nil,
            relayName: "Hearth Relay",
            relayAssessment: realtimeRelayAssessment()
        )
    }

    static func makeProtocolGuild() -> NoctCordSpaceSession {
        let spaceID = UUID(uuidString: "10000000-0000-0000-0000-000000000002")!
        let channelID = UUID(uuidString: "21000000-0000-0000-0000-000000000001")!
        let owner = handle(5)
        let current = handle(6)
        let now = Date()
        let members = [
            NoctCordMemberViewState(id: owner, displayName: "Sol", roleName: "Owner", presence: .active),
            NoctCordMemberViewState(id: current, displayName: "You", roleName: "Member", presence: .active),
        ]
        let events = [
            NoctCordEvent(
                spaceID: spaceID,
                author: owner,
                logicalClock: 1,
                createdAt: now.addingTimeInterval(-7_200),
                operation: .createSpace(name: "Protocol Guild")
            ),
            NoctCordEvent(
                spaceID: spaceID,
                author: owner,
                logicalClock: 2,
                createdAt: now.addingTimeInterval(-7_100),
                operation: .createChannel(id: channelID, name: "spec-review")
            ),
            NoctCordEvent(
                spaceID: spaceID,
                author: owner,
                logicalClock: 3,
                createdAt: now.addingTimeInterval(-1_800),
                operation: .postMessage(
                    id: UUID(),
                    channelID: channelID,
                    text: "Review the realtime-route threat model before the next relay implementation pass."
                )
            ),
        ]
        let projection = NoctCordSpaceProjection.project(
            spaceID: spaceID,
            owner: owner,
            activeMembers: Set(members.map(\.id)),
            events: events
        ).projection
        return NoctCordSpaceSession(
            id: spaceID,
            shortName: "PG",
            currentMember: current,
            identityScope: .isolated,
            members: members,
            events: events,
            projection: projection,
            unreadByChannel: [channelID: 1],
            voiceRooms: [],
            activeVoiceRoomID: nil,
            relayName: "Northstar Relay",
            relayAssessment: realtimeRelayAssessment()
        )
    }

    static func handle(_ byte: UInt8) -> GroupScopedMemberHandleV2 {
        GroupScopedMemberHandleV2(
            rawValue: Data(repeating: byte, count: 32).base64EncodedString()
        )
    }

    static func realtimeRelayAssessment() -> NoctCordRelayAssessment {
        NoctCordRelaySupport.assess(
            RelayCapabilityManifestV2(modules: [
                RelayModuleCapabilityV2(module: "nw.core", versions: [2], status: .provisional),
                RelayModuleCapabilityV2(module: "nw.realtime-route", versions: [1], status: .experimental),
                RelayModuleCapabilityV2(module: "nw.shared-log", versions: [1], status: .experimental),
                RelayModuleCapabilityV2(module: "nw.blobs", versions: [1], status: .provisional),
                RelayModuleCapabilityV2(module: "nw.federation", versions: [1], status: .provisional),
            ]),
            temporalBucketSeconds: 0
        )
    }

    static func fallbackRelayAssessment() -> NoctCordRelayAssessment {
        NoctCordRelaySupport.assess(
            RelayCapabilityManifestV2(modules: [
                RelayModuleCapabilityV2(module: "nw.core", versions: [2], status: .provisional),
                RelayModuleCapabilityV2(module: "nw.opaque-route", versions: [2], status: .provisional),
            ]),
            temporalBucketSeconds: 0
        )
    }
}
