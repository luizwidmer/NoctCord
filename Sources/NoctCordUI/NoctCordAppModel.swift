import Foundation
import SwiftUI
import CryptoKit
import NoctCordCore
import NoctCordMedia
@preconcurrency import NoctweaveCore

public enum NoctCordPresence: String, Equatable, Sendable {
    case active
    case away
    case offline
}

public enum NoctCordConnectionState: Equatable, Sendable {
    case preview
    case needsSetup
    case connecting
    case ready
    case failed(String)
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

public struct NoctCordAttachmentPresentation: Identifiable, Equatable {
    public let id: UUID
    public let mediaType: String
    public let byteCount: UInt64
    public let expiresAt: Date
    public let isAvailableLocally: Bool
    public let isExpired: Bool
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
    @Published public private(set) var connectionState: NoctCordConnectionState
    @Published public private(set) var activityMessage: String?
    @Published public private(set) var cachedAttachments: [UUID: NoctCordDownloadedAttachment] = [:]
    @Published public var showsAttachmentImporter = false
    @Published public var selectedAttachmentID: UUID?
    @Published public var showsCreateVoiceRoom = false
    @Published public private(set) var callSnapshot: NoctCordMediaRoomSnapshot?

    private let previewMode: Bool
    private var transport: NoctCordTransportCoordinator?
    private var refreshTask: Task<Void, Never>?
    private var identityScopes: [UUID: NoctCordIdentityScope] = [:]
    private var mediaRoom: NoctCordMediaRoom?
    private var mediaRefreshTask: Task<Void, Never>?
    private var processedCallSignalIDs: Set<UUID> = []
    private var iceServers: [NoctCordMediaICEServer] = []

    public init(seedPreviewData: Bool = false) {
        previewMode = seedPreviewData
        spaces = seedPreviewData ? Self.previewSpaces() : []
        connectionState = seedPreviewData ? .preview : .needsSetup
        selectedSpaceID = spaces.first?.id
        selectedChannelID = spaces.first?.textChannels.first?.id
    }

    deinit {
        refreshTask?.cancel()
        mediaRefreshTask?.cancel()
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

    public var selectedAttachments: [NoctCordAttachmentPresentation] {
        guard let space = selectedSpace,
              let channel = selectedChannel else { return [] }
        return channel.attachmentIDs.compactMap { id in
            guard let manifest = space.projection.attachments[id] else { return nil }
            return NoctCordAttachmentPresentation(
                id: id,
                mediaType: manifest.mediaType,
                byteCount: manifest.size,
                expiresAt: manifest.expiresAt,
                isAvailableLocally: cachedAttachments[id] != nil,
                isExpired: manifest.expiresAt < Date()
            )
        }
    }

    public func connect(
        configuration: NoctCordTransportConfiguration,
        iceServers: [NoctCordMediaICEServer] = []
    ) async {
        refreshTask?.cancel()
        connectionState = .connecting
        activityMessage = "Connecting to the relay…"
        do {
            guard iceServers.count <= 8 else {
                throw NoctCordMediaError.invalidConfiguration(
                    "Call connectivity supports at most eight ICE services."
                )
            }
            let coordinator = try await NoctCordTransportCoordinator.open(
                configuration: configuration
            )
            try await coordinator.testRelay()
            transport = coordinator
            self.iceServers = iceServers
            try await reloadAllSpaces()
            connectionState = .ready
            activityMessage = nil
            beginAutomaticRefresh()
        } catch {
            transport = nil
            connectionState = .failed(error.localizedDescription)
            activityMessage = nil
        }
    }

    public func retryConnection() async {
        guard let transport else { return }
        connectionState = .connecting
        do {
            try await reloadAllSpaces(using: transport)
            connectionState = .ready
            beginAutomaticRefresh()
        } catch {
            connectionState = .failed(error.localizedDescription)
        }
    }

    public func selectSpace(_ id: UUID) {
        if let current = selectedSpace,
           current.id != id,
           let roomID = current.activeVoiceRoomID,
           !previewMode {
            Task { await leaveVoiceRoom(spaceID: current.id, roomID: roomID) }
        }
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
              let channelID = selectedChannelID,
              let spaceID = selectedSpaceID else { return }
        if !previewMode {
            composerText = ""
            Task {
                await publishAndRefresh(
                    .postMessage(id: UUID(), channelID: channelID, text: text),
                    spaceID: spaceID,
                    activity: "Sending message…"
                )
            }
            return
        }
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
        guard let space = selectedSpace else { return }
        let selected = space.projection.messages[messageID]?.reactions[value]?.contains(
            space.currentMember
        ) == true
        let operation: NoctCordOperation = selected
            ? .removeReaction(value, from: messageID)
            : .addReaction(value, to: messageID)
        if !previewMode {
            Task {
                await publishAndRefresh(operation, spaceID: space.id)
            }
            return
        }
        updateSelectedSpace { space in
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
        if !previewMode {
            guard let transport else {
                connectionState = .failed("Connect a relay before creating a space.")
                return
            }
            showsCreateSpace = false
            activityMessage = "Creating encrypted space…"
            Task {
                do {
                    let bootstrap = try await transport.createSpace(name: cleanName)
                    identityScopes[bootstrap.spaceID] = identityScope
                    try await reloadAllSpaces(using: transport)
                    selectedSpaceID = bootstrap.spaceID
                    selectedChannelID = bootstrap.generalChannelID
                    connectionState = .ready
                    activityMessage = nil
                } catch {
                    activityMessage = nil
                    connectionState = .failed(error.localizedDescription)
                }
            }
            return
        }
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
        if !previewMode, let spaceID = selectedSpaceID {
            showsCreateChannel = false
            Task {
                await publishAndRefresh(
                    .createChannel(id: channelID, name: cleanName),
                    spaceID: spaceID,
                    activity: "Creating channel…"
                )
                if selectedSpace?.projection.channels[channelID] != nil {
                    selectedChannelID = channelID
                }
            }
            return
        }
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
        guard let space = selectedSpace else { return }
        if !previewMode {
            let isLeaving = space.activeVoiceRoomID == id
            Task {
                if isLeaving {
                    await leaveVoiceRoom(spaceID: space.id, roomID: id)
                } else {
                    await enterVoiceRoom(spaceID: space.id, roomID: id)
                }
            }
            return
        }
        updateSelectedSpace { space in
            space.activeVoiceRoomID = space.activeVoiceRoomID == id ? nil : id
        }
    }

    public func createVoiceRoom(name: String, maxParticipants: UInt16 = 8) {
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanName.isEmpty,
              let space = selectedSpace,
              space.canManageChannels else {
            showsCreateVoiceRoom = false
            return
        }
        let key = SymmetricKey(size: .bits256)
        let keyData = key.withUnsafeBytes { Data($0) }
        let roomID = UUID()
        showsCreateVoiceRoom = false
        if !previewMode {
            guard let transport else { return }
            Task {
                activityMessage = "Creating realtime voice route…"
                do {
                    let route = try await transport.createRealtimeRoute()
                    await publishAndRefresh(
                        .createVoiceRoom(
                            id: roomID,
                            spec: NoctCordVoiceRoomSpecV1(
                                name: cleanName,
                                maxParticipants: maxParticipants,
                                signalingKey: keyData,
                                realtimeRoute: route
                            )
                        ),
                        spaceID: space.id,
                        activity: "Creating voice room…"
                    )
                } catch {
                    activityMessage = nil
                    connectionState = .failed(error.localizedDescription)
                }
            }
            return
        }
        let previewCapabilities = (0..<3).map { _ in
            let key = SymmetricKey(size: .bits256)
            return key.withUnsafeBytes { Data($0) }
        }
        let operation = NoctCordOperation.createVoiceRoom(
            id: roomID,
            spec: NoctCordVoiceRoomSpecV1(
                name: cleanName,
                maxParticipants: maxParticipants,
                signalingKey: keyData,
                realtimeRoute: NoctCordRealtimeRouteV1(
                    routeCapability: previewCapabilities[0],
                    appendCapability: previewCapabilities[1],
                    readCapability: previewCapabilities[2],
                    expiresAt: Date().addingTimeInterval(8 * 60 * 60)
                )
            )
        )
        updateSelectedSpace { mutable in
            mutable.events.append(NoctCordEvent(
                spaceID: mutable.id,
                author: mutable.currentMember,
                logicalClock: Self.nextClock(in: mutable.events),
                operation: operation
            ))
            Self.rebuild(&mutable)
            mutable.voiceRooms.append(NoctCordVoiceRoom(
                id: roomID,
                name: cleanName,
                participantCount: 0
            ))
        }
    }

    public func setCallMuted(_ muted: Bool) {
        guard let mediaRoom,
              let space = selectedSpace,
              let roomID = space.activeVoiceRoomID else { return }
        Task {
            do {
                try await mediaRoom.setMicrophoneMuted(muted)
                let snapshot = await mediaRoom.snapshot()
                callSnapshot = snapshot
                await publishAndRefresh(
                    .setVoiceMute(
                        roomID: roomID,
                        state: NoctCordVoiceParticipantStateV1(
                            member: space.currentMember,
                            isJoined: true,
                            isMuted: snapshot.microphoneMuted,
                            isDeafened: snapshot.deafened
                        )
                    ),
                    spaceID: space.id
                )
            } catch {
                connectionState = .failed(error.localizedDescription)
            }
        }
    }

    public func setCallDeafened(_ deafened: Bool) {
        guard let mediaRoom,
              let space = selectedSpace,
              let roomID = space.activeVoiceRoomID else { return }
        Task {
            do {
                try await mediaRoom.setDeafened(deafened)
                let snapshot = await mediaRoom.snapshot()
                callSnapshot = snapshot
                await publishAndRefresh(
                    .setVoiceDeafened(
                        roomID: roomID,
                        state: NoctCordVoiceParticipantStateV1(
                            member: space.currentMember,
                            isJoined: true,
                            isMuted: snapshot.microphoneMuted,
                            isDeafened: snapshot.deafened
                        )
                    ),
                    spaceID: space.id
                )
            } catch {
                connectionState = .failed(error.localizedDescription)
            }
        }
    }

    public func startScreenShare() {
        guard let mediaRoom,
              let space = selectedSpace,
              let roomID = space.activeVoiceRoomID,
              let projectedRoom = space.projection.voiceRooms[roomID] else { return }
        Task {
            do {
                #if os(macOS)
                try await mediaRoom.startScreenShare(using: NoctCordMacScreenCaptureKitSource())
                #elseif os(iOS)
                try await mediaRoom.startScreenShare(using: NoctCordReplayKitScreenShareSource())
                #endif
                let snapshot = await mediaRoom.snapshot()
                callSnapshot = snapshot
                if let track = snapshot.localScreenShare {
                    let source: NoctCordScreenShareKind
                    switch track.source {
                    case .display: source = .display
                    case .replayKitBroadcast: source = .application
                    }
                    await publishAndRefresh(
                        .startScreenShare(
                            roomID: roomID,
                            descriptor: NoctCordScreenShareDescriptorV1(
                                shareID: UUID(),
                                presenter: space.currentMember,
                                source: source,
                                keyID: projectedRoom.signalingKeyID
                            )
                        ),
                        spaceID: space.id
                    )
                }
            } catch {
                connectionState = .failed(error.localizedDescription)
            }
        }
    }

    public func stopScreenShare() {
        guard let mediaRoom,
              let space = selectedSpace,
              let roomID = space.activeVoiceRoomID else { return }
        let shares = space.projection.activeScreenShares.values.filter {
            $0.roomID == roomID && $0.descriptor.presenter == space.currentMember
        }
        Task {
            do {
                try await mediaRoom.stopScreenShare()
                callSnapshot = await mediaRoom.snapshot()
                for share in shares {
                    await publishAndRefresh(
                        .stopScreenShare(
                            roomID: roomID,
                            shareID: share.descriptor.shareID
                        ),
                        spaceID: space.id
                    )
                }
            } catch {
                connectionState = .failed(error.localizedDescription)
            }
        }
    }

    public func setIdentityScope(_ scope: NoctCordIdentityScope) {
        if let selectedSpaceID {
            identityScopes[selectedSpaceID] = scope
        }
        updateSelectedSpace { space in
            space.identityScope = scope
        }
    }

    public func sendAttachment(at url: URL) {
        guard !previewMode,
              let transport,
              let spaceID = selectedSpaceID,
              let channelID = selectedChannelID else { return }
        activityMessage = "Sanitizing attachment…"
        Task {
            do {
                let sanitized = try await NoctCordAttachmentSanitizer.sanitize(url: url)
                activityMessage = "Encrypting and uploading…"
                let transfer = await transport.attachmentTransfer()
                let uploaded = try await transfer.upload(
                    sanitized,
                    spaceID: spaceID,
                    channelID: channelID
                )
                do {
                    let publication = try await transport.publishOperation(
                        spaceID: spaceID,
                        operation: .addAttachment(
                            id: uploaded.id,
                            channelID: channelID,
                            manifest: uploaded.manifest
                        )
                    )
                    guard publication.complete else {
                        throw NoctCordTransportError.transportIncomplete
                    }
                } catch {
                    try? await transfer.release(manifest: uploaded.manifest)
                    throw error
                }
                cachedAttachments[uploaded.id] = NoctCordDownloadedAttachment(
                    id: uploaded.id,
                    bytes: sanitized.bytes,
                    mediaType: sanitized.mimeType
                )
                try await reloadSpace(spaceID, using: transport)
                activityMessage = nil
            } catch {
                activityMessage = nil
                connectionState = .failed(error.localizedDescription)
            }
        }
    }

    public func downloadAttachment(_ id: UUID) {
        guard !previewMode,
              cachedAttachments[id] == nil,
              let transport,
              let space = selectedSpace,
              let channelID = selectedChannelID,
              let manifest = space.projection.attachments[id] else { return }
        activityMessage = "Downloading encrypted attachment…"
        Task {
            do {
                let transfer = await transport.attachmentTransfer()
                let downloaded = try await transfer.download(
                    manifest: manifest,
                    spaceID: space.id,
                    channelID: channelID
                )
                cachedAttachments[id] = downloaded
                activityMessage = nil
            } catch {
                activityMessage = nil
                connectionState = .failed(error.localizedDescription)
            }
        }
    }

    private func enterVoiceRoom(spaceID: UUID, roomID: UUID) async {
        guard let transport,
              let space = spaces.first(where: { $0.id == spaceID }),
              let initialRoom = space.projection.voiceRooms[roomID],
              !initialRoom.isArchived else { return }
        if let active = space.activeVoiceRoomID, active != roomID {
            await leaveVoiceRoom(spaceID: spaceID, roomID: active)
        }
        activityMessage = "Joining encrypted voice room…"
        do {
            var projectedRoom = initialRoom
            // Never rotate an otherwise valid route from a single joining
            // client: peers already in the room are still bound to that
            // route and signaling key. Expired routes are replaced before a
            // new media session starts; live routes remain stable for the
            // duration advertised by the room descriptor.
            if projectedRoom.realtimeRoute.expiresAt <= Date() {
                guard space.canManageChannels else {
                    throw NoctCordTransportError.voiceRouteExpired
                }
                activityMessage = "Renewing the encrypted voice route…"
                let route = try await transport.createRealtimeRoute()
                let rotatedKey = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
                let renewal = try await transport.publishOperation(
                    spaceID: spaceID,
                    operation: .updateVoiceRoom(
                        id: roomID,
                        spec: NoctCordVoiceRoomSpecV1(
                            name: projectedRoom.name,
                            maxParticipants: projectedRoom.maxParticipants,
                            signalingKey: rotatedKey,
                            realtimeRoute: route
                        )
                    )
                )
                guard renewal.complete else {
                    throw NoctCordTransportError.transportIncomplete
                }
                try await reloadSpace(spaceID, using: transport)
                guard let renewed = spaces.first(where: { $0.id == spaceID })?
                    .projection.voiceRooms[roomID] else {
                    throw NoctCordTransportError.spaceNotFound
                }
                projectedRoom = renewed
            }
            let joinedState = NoctCordVoiceParticipantStateV1(
                member: space.currentMember,
                isJoined: true
            )
            let publication = try await transport.publishOperation(
                spaceID: spaceID,
                operation: .joinVoiceRoom(id: roomID, state: joinedState)
            )
            guard publication.complete else {
                throw NoctCordTransportError.transportIncomplete
            }
            try await reloadSpace(spaceID, using: transport)

            let participantID = try NoctCordMediaParticipantID(
                NoctCordCallSignalCrypto.participantID(for: space.currentMember)
            )
            let mediaConfiguration = NoctCordMediaRoomConfiguration(
                roomID: try NoctCordMediaRoomID(roomID.uuidString),
                participant: NoctCordMediaParticipant(
                    id: participantID,
                    displayName: currentMember?.displayName ?? "Member"
                ),
                wantsMicrophone: true,
                iceServers: iceServers
            )
            let sink = NoctCordRelayMediaSignalingSink(
                coordinator: transport,
                spaceID: spaceID,
                room: projectedRoom,
                author: space.currentMember
            )
            let room = NoctCordMediaRoom(
                configuration: mediaConfiguration,
                driver: NoctCordWebRTCMediaDriver(),
                permissionProvider: NoctCordAVAudioPermissionProvider(),
                signalingSink: sink
            )
            // Subscribe and drain the existing route before announcing this
            // media session. This establishes a replay floor without copying
            // ephemeral SDP/ICE into permanent group history.
            for _ in 0..<8 {
                let stale = try await transport.synchronizeRealtimeCallSignals(
                    spaceID: spaceID,
                    roomID: roomID
                )
                if stale.isEmpty { break }
            }
            processedCallSignalIDs.removeAll()
            try await room.join()
            mediaRoom = room
            callSnapshot = await room.snapshot()
            beginRealtimeCallRefresh(
                coordinator: transport,
                mediaRoom: room,
                spaceID: spaceID,
                room: projectedRoom,
                localMember: space.currentMember
            )
            activityMessage = nil
            connectionState = .ready
        } catch {
            mediaRoom = nil
            callSnapshot = nil
            activityMessage = nil
            connectionState = .failed(error.localizedDescription)
            _ = try? await transport.publishOperation(
                spaceID: spaceID,
                operation: .leaveVoiceRoom(
                    id: roomID,
                    state: NoctCordVoiceParticipantStateV1(
                        member: space.currentMember,
                        isJoined: false
                    )
                )
            )
            try? await reloadSpace(spaceID, using: transport)
        }
    }

    private func leaveVoiceRoom(spaceID: UUID, roomID: UUID) async {
        mediaRefreshTask?.cancel()
        mediaRefreshTask = nil
        if let mediaRoom {
            await mediaRoom.leave()
        }
        self.mediaRoom = nil
        callSnapshot = nil
        processedCallSignalIDs.removeAll()
        guard let transport,
              let space = spaces.first(where: { $0.id == spaceID }) else { return }
        activityMessage = "Leaving voice room…"
        do {
            let publication = try await transport.publishOperation(
                spaceID: spaceID,
                operation: .leaveVoiceRoom(
                    id: roomID,
                    state: NoctCordVoiceParticipantStateV1(
                        member: space.currentMember,
                        isJoined: false
                    )
                )
            )
            guard publication.complete else {
                throw NoctCordTransportError.transportIncomplete
            }
            await transport.closeRealtimeRoom(roomID: roomID)
            try await reloadSpace(spaceID, using: transport)
            activityMessage = nil
        } catch {
            activityMessage = nil
            connectionState = .failed(error.localizedDescription)
        }
    }

    private func beginRealtimeCallRefresh(
        coordinator: NoctCordTransportCoordinator,
        mediaRoom: NoctCordMediaRoom,
        spaceID: UUID,
        room: NoctCordCore.NoctCordVoiceRoom,
        localMember: GroupScopedMemberHandleV2
    ) {
        mediaRefreshTask?.cancel()
        mediaRefreshTask = Task { [weak self] in
            while !Task.isCancelled {
                if let realtime = try? await coordinator.synchronizeRealtimeCallSignals(
                    spaceID: spaceID,
                    roomID: room.id
                ) {
                    for received in realtime where received.author != localMember {
                        await self?.deliverCallSignal(
                            received.signal,
                            author: received.author,
                            spaceID: spaceID,
                            room: room,
                            localMember: localMember,
                            mediaRoom: mediaRoom
                        )
                    }
                }
                if let snapshot = await self?.mediaRoom?.snapshot() {
                    self?.callSnapshot = snapshot
                }
                try? await Task.sleep(for: .milliseconds(150))
            }
        }
    }

    private func deliverCallSignal(
        _ signal: NoctCordEncryptedCallSignalV1,
        author: GroupScopedMemberHandleV2,
        spaceID: UUID,
        room: NoctCordCore.NoctCordVoiceRoom,
        localMember: GroupScopedMemberHandleV2,
        mediaRoom: NoctCordMediaRoom
    ) async {
        guard !processedCallSignalIDs.contains(signal.signalID) else { return }
        do {
            let envelope = try NoctCordCallSignalCrypto.open(
                signal,
                spaceID: spaceID,
                room: room,
                author: author,
                localMember: localMember
            )
            try await mediaRoom.handleIncomingSignal(envelope)
            processedCallSignalIDs.insert(signal.signalID)
        } catch {
            // Invalid or misaddressed realtime records are quarantined by
            // omission. They never tear down a healthy room.
        }
    }

    private func publishAndRefresh(
        _ operation: NoctCordOperation,
        spaceID: UUID,
        activity: String? = nil
    ) async {
        guard let transport else { return }
        if let activity { activityMessage = activity }
        do {
            let publication = try await transport.publishOperation(
                spaceID: spaceID,
                operation: operation
            )
            guard publication.complete else {
                throw NoctCordTransportError.transportIncomplete
            }
            try await reloadSpace(spaceID, using: transport)
            connectionState = .ready
            activityMessage = nil
        } catch {
            activityMessage = nil
            connectionState = .failed(error.localizedDescription)
        }
    }

    private func beginAutomaticRefresh() {
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled, let self, let transport = self.transport else { return }
                do {
                    try await self.reloadAllSpaces(using: transport)
                } catch {
                    // A transient poll failure must not discard visible state or
                    // interrupt an active call. User actions surface hard errors.
                }
            }
        }
    }

    private func reloadAllSpaces() async throws {
        guard let transport else { throw NoctCordTransportError.invalidConfiguration }
        try await reloadAllSpaces(using: transport)
    }

    private func reloadAllSpaces(using transport: NoctCordTransportCoordinator) async throws {
        let previousSpaceID = selectedSpaceID
        let previousChannelID = selectedChannelID
        var loaded: [NoctCordSpaceSession] = []
        for spaceID in await transport.storedSpaceIDs() {
            _ = try? await transport.synchronize(spaceID: spaceID)
            loaded.append(try await makeSession(spaceID: spaceID, using: transport))
        }
        spaces = loaded.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
        if let previousSpaceID, spaces.contains(where: { $0.id == previousSpaceID }) {
            selectedSpaceID = previousSpaceID
        } else {
            selectedSpaceID = spaces.first?.id
        }
        if let previousChannelID,
           selectedSpace?.projection.channels[previousChannelID] != nil {
            selectedChannelID = previousChannelID
        } else {
            selectedChannelID = selectedSpace?.textChannels.first?.id
        }
    }

    private func reloadSpace(
        _ spaceID: UUID,
        using transport: NoctCordTransportCoordinator
    ) async throws {
        _ = try? await transport.synchronize(spaceID: spaceID)
        let session = try await makeSession(spaceID: spaceID, using: transport)
        if let index = spaces.firstIndex(where: { $0.id == spaceID }) {
            spaces[index] = session
        } else {
            spaces.append(session)
        }
        if selectedSpaceID == spaceID,
           selectedChannelID.flatMap({ session.projection.channels[$0] }) == nil {
            selectedChannelID = session.textChannels.first?.id
        }
    }

    private func makeSession(
        spaceID: UUID,
        using transport: NoctCordTransportCoordinator
    ) async throws -> NoctCordSpaceSession {
        let snapshot = try await transport.storedSpaceSnapshot(spaceID: spaceID)
        let activeMembers = Set(snapshot.members.map(\.handle))
        let projection = NoctCordSpaceProjection.project(
            spaceID: spaceID,
            owner: snapshot.owner,
            activeMembers: activeMembers,
            events: snapshot.events
        ).projection
        let members = snapshot.members.map { member in
            NoctCordMemberViewState(
                id: member.handle,
                displayName: member.isCurrentMember
                    ? "You"
                    : "Member \(Self.compactHandle(member.handle))",
                roleName: member.roleName,
                presence: member.isCurrentMember ? .active : .offline
            )
        }
        let voiceRooms = projection.voiceRooms.values
            .filter { !$0.isArchived }
            .map { room in
                NoctCordVoiceRoom(
                    id: room.id,
                    name: room.name,
                    participantCount: projection.voiceParticipants[room.id, default: [:]]
                        .values.filter(\.isJoined).count
                )
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        let activeVoiceRoomID = projection.voiceParticipants.first(where: { _, participants in
            participants[snapshot.currentMember]?.isJoined == true
        })?.key
        let relay = await transport.relayEndpoint()
        return NoctCordSpaceSession(
            id: spaceID,
            shortName: Self.shortName(projection.name ?? "Space"),
            currentMember: snapshot.currentMember,
            identityScope: identityScopes[spaceID] ?? .isolated,
            members: members,
            events: snapshot.events,
            projection: projection,
            unreadByChannel: spaces.first(where: { $0.id == spaceID })?.unreadByChannel ?? [:],
            voiceRooms: voiceRooms,
            activeVoiceRoomID: activeVoiceRoomID,
            relayName: relay.host,
            relayAssessment: snapshot.relayAssessment
        )
    }

    private static func compactHandle(_ handle: GroupScopedMemberHandleV2) -> String {
        String(handle.rawValue.prefix(7))
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
                RelayModuleCapabilityV2(module: "nw.media-blobs", versions: [1], status: .provisional),
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
