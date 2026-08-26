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

struct NoctCordConnectionFailurePresentation: Equatable {
    let message: String
    let permitsLocalStateReset: Bool

    init(error: Error) {
        guard let storeError = error as? ClientStateStoreError else {
            message = error.localizedDescription
            permitsLocalStateReset = false
            return
        }
        permitsLocalStateReset = storeError == .rollbackDetected
        switch storeError {
        case .encryptionFailed:
            message = "Noct Cord could not decrypt its protected local transport state. No relay request was sent."
        case .stateTooLarge:
            message = "The protected local transport state exceeds the safe size limit. No relay request was sent."
        case .rollbackAnchorUnavailable:
            message = "The Keychain rollback anchor is unavailable. Unlock Keychain access and try again."
        case .rollbackDetected:
            message = "Protected local transport state does not match its Keychain rollback anchor. No relay request was sent. Restore the matching app data, or explicitly reset local transport state."
        case .concurrentUpdate:
            message = "Another Noct Cord process changed local transport state. Close the other copy and try again."
        case .storageUnavailable:
            message = "Protected local transport storage is unavailable. No relay request was sent."
        }
    }
}

public struct NoctCordMemberViewState: Identifiable, Equatable {
    public let id: GroupScopedMemberHandleV2
    public let displayName: String
    public let roleName: String
    public let presence: NoctCordPresence
    public let isBot: Bool

    public init(
        id: GroupScopedMemberHandleV2,
        displayName: String,
        roleName: String,
        presence: NoctCordPresence,
        isBot: Bool = false
    ) {
        self.id = id
        self.displayName = displayName
        self.roleName = roleName
        self.presence = presence
        self.isBot = isBot
    }

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
            .filter {
                !$0.isArchived
                    && projection.permissions(for: currentMember, in: $0.id)
                        .contains(.readMessages)
            }
            .sorted { lhs, rhs in
                if lhs.name == "general" { return rhs.name != "general" }
                if rhs.name == "general" { return false }
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
    }

    public var canManageChannels: Bool {
        projection.permissions(for: currentMember).contains(.manageChannels)
    }

    public var canManageRoles: Bool {
        projection.permissions(for: currentMember).contains(.manageRoles)
    }

    public var canManageBots: Bool {
        projection.permissions(for: currentMember).contains(.manageBots)
    }

    public var isCurrentUserOwner: Bool {
        currentMember == projection.owner
    }
}

@MainActor
public final class NoctCordAppModel: ObservableObject {
    @Published public private(set) var spaces: [NoctCordSpaceSession]
    @Published public var selectedSpaceID: UUID?
    @Published public var selectedChannelID: UUID?
    @Published public var composerText = ""
    @Published public var searchQuery = ""
    @Published public var showsMemberInspector = false
    @Published public var showsCreateSpace = false
    @Published public var showsJoinSpace = false
    @Published public var showsInvitationExchange = false
    @Published public var stagedInvitationCode = ""
    @Published public var showsCreateChannel = false
    @Published public var showsCommunitySettings = false
    @Published public var showsUserSettings = false
    @Published public var appearance: NoctCordAppearance = .system
    @Published public private(set) var privacySettings = PrivacySettings()
    @Published public private(set) var relayProfiles: [NoctCordRelayProfile] = []
    @Published public private(set) var userDisplayName: String
    @Published public private(set) var settingsNotice: String?
    @Published public private(set) var connectionState: NoctCordConnectionState
    @Published public private(set) var permitsLocalStateReset = false
    @Published public private(set) var activityMessage: String?
    @Published public private(set) var cachedAttachments: [UUID: NoctCordDownloadedAttachment] = [:]
    @Published public var showsAttachmentImporter = false
    @Published public var selectedAttachmentID: UUID?
    @Published public var showsCreateVoiceRoom = false
    @Published public private(set) var callSnapshot: NoctCordMediaRoomSnapshot?
    @Published public private(set) var composerNotice: String?
    @Published public private(set) var communityLifecycleOperationSpaceID: UUID?
    @Published public private(set) var callConnectivityDescription =
        "Call traversal will be discovered from the relay when available."

    private let previewMode: Bool
    private let identityVault: NoctCordIdentityVault
    private var transport: NoctCordTransportCoordinator?
    private var refreshTask: Task<Void, Never>?
    private var communityLifecycleRecoveryTask: Task<Void, Never>?
    private var identityScopes: [UUID: NoctCordIdentityScope] = [:]
    private var mediaRoom: NoctCordMediaRoom?
    private var mediaRefreshTask: Task<Void, Never>?
    private var processedCallSignalIDs: Set<UUID> = []
    private var iceServers: [NoctCordMediaICEServer] = []
    private var usesRelayDiscoveredICE = true
    private var relayICECredentialExpiresAt: Date?

    public init(
        seedPreviewData: Bool = false,
        liveUITestConfiguration: NoctCordTransportConfiguration? = nil
    ) {
        #if DEBUG
        let liveConfiguration = liveUITestConfiguration
        #else
        let liveConfiguration: NoctCordTransportConfiguration? = nil
        #endif
        let usesPreview = seedPreviewData && liveConfiguration == nil
        previewMode = usesPreview
        let savedName = UserDefaults.standard.string(forKey: "NoctCord.displayName")?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        userDisplayName = liveConfiguration?.displayName
            ?? (usesPreview ? "You" : (savedName.isEmpty ? "Member" : savedName))
        if let liveConfiguration {
            identityVault = NoctCordIdentityVault(
                fileURL: liveConfiguration.stateURL
                    .appendingPathExtension("identity-vault"),
                encryptionKey: SymmetricKey(data: Data(repeating: 0x43, count: 32))
            )
        } else if usesPreview {
            identityVault = NoctCordIdentityVault(
                fileURL: FileManager.default.temporaryDirectory
                    .appendingPathComponent("noctcord-preview-\(UUID().uuidString).vault"),
                encryptionKey: SymmetricKey(size: .bits256)
            )
        } else {
            let base = (try? FileManager.default.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )) ?? FileManager.default.temporaryDirectory
            identityVault = NoctCordIdentityVault(
                fileURL: base
                    .appendingPathComponent("NoctCord", isDirectory: true)
                    .appendingPathComponent("identity-vault.noctcord")
            )
        }
        spaces = usesPreview ? Self.previewSpaces() : []
        connectionState = usesPreview
            ? .preview
            : (liveConfiguration == nil ? .needsSetup : .connecting)
        selectedSpaceID = spaces.first?.id
        selectedChannelID = spaces.first?.textChannels.first?.id
        if let liveConfiguration {
            Task { [weak self] in
                await self?.connect(configuration: liveConfiguration)
            }
        }
    }

    deinit {
        refreshTask?.cancel()
        communityLifecycleRecoveryTask?.cancel()
        mediaRefreshTask?.cancel()
    }

    public var selectedSpace: NoctCordSpaceSession? {
        guard let selectedSpaceID else { return nil }
        return spaces.first { $0.id == selectedSpaceID }
    }

    public var selectedChannel: NoctCordChannel? {
        guard let selectedChannelID,
              let space = selectedSpace,
              space.projection.permissions(for: space.currentMember, in: selectedChannelID)
                .contains(.readMessages) else { return nil }
        return space.projection.channels[selectedChannelID]
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

    public var selectedChannelPermissions: Set<NoctCordPermission> {
        guard let space = selectedSpace,
              let channelID = selectedChannelID else { return [] }
        return space.projection.permissions(for: space.currentMember, in: channelID)
    }

    public var canSendInSelectedChannel: Bool {
        selectedChannelPermissions.contains(.sendMessages)
    }

    public var canAttachInSelectedChannel: Bool {
        canSendInSelectedChannel && selectedChannelPermissions.contains(.attachFiles)
    }

    public var canInviteToSelectedSpace: Bool {
        guard let space = selectedSpace else { return false }
        return space.isCurrentUserOwner
    }

    public var isSelectedCommunityLifecycleOperationInFlight: Bool {
        communityLifecycleOperationSpaceID == selectedSpaceID
    }

    public var availableBotCommands: [(bot: NoctCordBotApplication, command: NoctCordBotCommand)] {
        guard selectedChannelPermissions.contains(.useApplicationCommands),
              let space = selectedSpace else { return [] }
        return space.projection.botApplications.values
            .flatMap { bot in bot.commands.map { (bot: bot, command: $0) } }
            .sorted {
                if $0.command.name != $1.command.name {
                    return $0.command.name < $1.command.name
                }
                return $0.bot.name < $1.bot.name
            }
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
        permitsLocalStateReset = false
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
            // A setup relay is only a bootstrap default. Once local community
            // state exists, an outage on that relay must not lock the user out
            // of communities whose independent relays are still reachable.
            let storedSpaceIDs = await coordinator.storedSpaceIDs()
            let hasStoredCommunities = !storedSpaceIDs.isEmpty
            if !hasStoredCommunities {
                try await coordinator.testRelay()
            }
            transport = coordinator
            userDisplayName = configuration.displayName
            UserDefaults.standard.set(
                configuration.displayName,
                forKey: "NoctCord.displayName"
            )
            var loadedPrivacySettings = await coordinator.privacySettings()
            #if DEBUG
            if configuration.usesInsecurePlaintextStateForTesting {
                // Live UI evidence must remain inspectable while the two test
                // windows trade focus. Production capture and focus shielding
                // stay enabled by their persisted settings.
                loadedPrivacySettings.hideSensitiveWhenUnfocused = false
                loadedPrivacySettings.macBlockWindowCapture = false
            }
            #endif
            privacySettings = loadedPrivacySettings
            relayProfiles = await coordinator.relayProfiles()
            usesRelayDiscoveredICE = iceServers.isEmpty
            if iceServers.isEmpty {
                if hasStoredCommunities {
                    self.iceServers = []
                    relayICECredentialExpiresAt = nil
                    callConnectivityDescription =
                        "Call traversal will refresh from this community's relay."
                } else {
                    await refreshRelayCallConnectivity(using: coordinator)
                }
            } else {
                self.iceServers = iceServers
                relayICECredentialExpiresAt = nil
                callConnectivityDescription =
                    "Using your manual ICE override for this session."
            }
            try await reloadAllSpaces(
                using: coordinator,
                synchronize: false,
                assessRelays: false
            )
            connectionState = .ready
            activityMessage = nil
            beginAutomaticRefresh()
            if usesRelayDiscoveredICE, let selectedSpaceID {
                Task {
                    await refreshRelayCallConnectivity(
                        using: coordinator,
                        for: selectedSpaceID
                    )
                }
            }
        } catch {
            transport = nil
            let presentation = NoctCordConnectionFailurePresentation(error: error)
            permitsLocalStateReset = presentation.permitsLocalStateReset
            connectionState = .failed(presentation.message)
            activityMessage = nil
        }
    }

    public func resetLocalStateAndConnect(
        configuration: NoctCordTransportConfiguration,
        iceServers: [NoctCordMediaICEServer] = []
    ) async {
        refreshTask?.cancel()
        connectionState = .connecting
        activityMessage = "Resetting protected local transport state…"
        do {
            try await NoctCordTransportCoordinator.eraseLocalState(
                configuration: configuration
            )
            permitsLocalStateReset = false
            await connect(configuration: configuration, iceServers: iceServers)
        } catch {
            let presentation = NoctCordConnectionFailurePresentation(error: error)
            permitsLocalStateReset = presentation.permitsLocalStateReset
            connectionState = .failed(presentation.message)
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
        if !previewMode, usesRelayDiscoveredICE, let transport {
            Task {
                await refreshRelayCallConnectivity(using: transport, for: id)
            }
        }
    }

    public func selectChannel(_ id: UUID) {
        guard selectedSpace?.textChannels.contains(where: { $0.id == id }) == true else {
            return
        }
        selectedChannelID = id
        searchQuery = ""
        composerNotice = nil
        updateSelectedSpace { space in
            space.unreadByChannel[id] = 0
        }
    }

    public func clearComposerNotice() {
        composerNotice = nil
    }

    public func sendCurrentMessage() {
        let text = composerText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty,
              let channelID = selectedChannelID,
              let spaceID = selectedSpaceID else { return }
        guard canSendInSelectedChannel else {
            composerNotice = "You can read this channel, but your roles cannot send here."
            return
        }

        let operation: NoctCordOperation
        if text.hasPrefix("/") {
            guard selectedChannelPermissions.contains(.useApplicationCommands) else {
                composerNotice = "Application commands are disabled in this channel."
                return
            }
            let commandLine = String(text.dropFirst())
            let parts = commandLine.split(maxSplits: 1, whereSeparator: \.isWhitespace)
            guard let commandName = parts.first.map(String.init), !commandName.isEmpty else {
                composerNotice = "Enter a command after the slash."
                return
            }
            let matches = availableBotCommands.filter { $0.command.name == commandName.lowercased() }
            guard matches.count == 1, let match = matches.first else {
                composerNotice = matches.isEmpty
                    ? "No installed app exposes /\(commandName)."
                    : "More than one app exposes /\(commandName); remove the duplicate command."
                return
            }
            operation = .invokeBot(
                NoctCordBotCommandInvocation(
                    botID: match.bot.id,
                    channelID: channelID,
                    commandName: match.command.name,
                    arguments: parts.count > 1 ? String(parts[1]) : ""
                )
            )
        } else {
            operation = .postMessage(id: UUID(), channelID: channelID, text: text)
        }

        composerText = ""
        composerNotice = nil
        perform(
            operation,
            spaceID: spaceID,
            activity: operation.kind == .botCommandInvoked
                ? "Invoking application…"
                : "Sending message…"
        )
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

    public func createSpace(
        name: String,
        identityScope: NoctCordIdentityScope,
        relayPreferenceID: UUID? = nil
    ) {
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
                    let bootstrap = try await transport.createSpace(
                        name: cleanName,
                        relayPreferenceID: relayPreferenceID
                    )
                    identityScopes[bootstrap.spaceID] = identityScope
                    do {
                        let binding = try await identityVault.binding(
                            scope: identityScope,
                            displayName: userDisplayName,
                            spaceID: bootstrap.spaceID,
                            memberHandle: bootstrap.owner
                        )
                        let publication = try await transport.publishOperation(
                            spaceID: bootstrap.spaceID,
                            operation: .bindIdentity(binding)
                        )
                        if !publication.complete {
                            try await transport.maintain(spaceID: bootstrap.spaceID)
                        }
                    } catch {
                        identityScopes[bootstrap.spaceID] = .isolated
                        composerNotice = "The community was created with its isolated group identity, but the optional profile binding could not be saved: \(error.localizedDescription)"
                    }
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

    public func makeCommunityInvitation(
        lifetime: TimeInterval = 60 * 60
    ) async throws -> String {
        guard let transport, let space = selectedSpace else {
            throw NoctCordTransportError.invalidConfiguration
        }
        guard canInviteToSelectedSpace else {
            throw NoctCordTransportError.invitationPermissionDenied
        }
        activityMessage = "Preparing a one-use invitation…"
        defer { activityMessage = nil }
        let invitation = try await transport.makeCommunityInvitation(
            spaceID: space.id,
            spaceName: space.name,
            lifetime: lifetime
        )
        return try invitation.encoded()
    }

    public func prepareCommunityAdmission(
        invitationCode: String,
        identityScope: NoctCordIdentityScope
    ) async throws -> NoctCordPreparedCommunityAdmission {
        guard let transport else {
            throw NoctCordTransportError.invalidConfiguration
        }
        let invitation = try NoctCordCommunityInvitationV1.decode(invitationCode)
        activityMessage = "Creating a fresh community identity…"
        defer { activityMessage = nil }
        let prepared = try await transport.prepareCommunityAdmission(
            invitation: invitation
        )
        relayProfiles = await transport.relayProfiles()
        identityScopes[invitation.spaceID] = identityScope
        return prepared
    }

    public func approveCommunityAdmissionRequest(
        _ requestCode: String
    ) async throws -> String {
        guard let transport, let spaceID = selectedSpaceID else {
            throw NoctCordTransportError.invalidConfiguration
        }
        guard canInviteToSelectedSpace else {
            throw NoctCordTransportError.invitationPermissionDenied
        }
        activityMessage = "Adding the new member…"
        defer { activityMessage = nil }
        let response = try await transport.approveCommunityAdmissionRequest(
            requestCode,
            for: spaceID
        )
        try await reloadSpace(spaceID, using: transport)
        return response
    }

    @discardableResult
    public func acceptCommunityAdmissionResponse(
        _ responseCode: String
    ) async throws -> UUID {
        guard let transport else {
            throw NoctCordTransportError.invalidConfiguration
        }
        activityMessage = "Verifying the signed community welcome…"
        defer { activityMessage = nil }
        let spaceID = try await transport.acceptCommunityAdmissionResponse(responseCode)
        let snapshot = try await transport.storedSpaceSnapshot(spaceID: spaceID)
        let scope = identityScopes[spaceID] ?? .isolated
        do {
            let binding = try await identityVault.binding(
                scope: scope,
                displayName: userDisplayName,
                spaceID: spaceID,
                memberHandle: snapshot.currentMember
            )
            let publication = try await transport.publishOperation(
                spaceID: spaceID,
                operation: .bindIdentity(binding)
            )
            if !publication.complete {
                try await transport.maintain(spaceID: spaceID)
            }
        } catch {
            identityScopes[spaceID] = .isolated
            composerNotice = "You joined with a fresh group-only identity, but the optional profile binding could not be saved: \(error.localizedDescription)"
        }
        try await reloadSpace(spaceID, using: transport)
        selectedSpaceID = spaceID
        selectedChannelID = spaces.first { $0.id == spaceID }?.textChannels.first?.id
        connectionState = .ready
        return spaceID
    }

    /// Publishes a signed self-removal epoch and then removes the community
    /// from the active UI. The transport keeps its encrypted terminal record
    /// so old ciphertext cannot silently recreate membership.
    public func leaveSelectedCommunity() async throws {
        guard let space = selectedSpace else {
            throw NoctCordTransportError.spaceNotFound
        }
        guard !space.isCurrentUserOwner else {
            throw NoctCordTransportError.ownerCannotLeave
        }
        try await performCommunityLifecycle(.leave, spaceID: space.id)
    }

    /// Publishes the owner's terminal group tombstone and removes the
    /// community from the active UI only after relay acknowledgement.
    public func destroySelectedCommunity() async throws {
        guard let space = selectedSpace else {
            throw NoctCordTransportError.spaceNotFound
        }
        guard space.isCurrentUserOwner else {
            throw NoctCordTransportError.communityOwnerRequired
        }
        try await performCommunityLifecycle(.destroy, spaceID: space.id)
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
                    let route = try await transport.createRealtimeRoute(for: space.id)
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

    @discardableResult
    public func updateDisplayName(
        _ value: String,
        acrossAllCommunities: Bool
    ) async -> Bool {
        let cleanName = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanName.isEmpty, cleanName.utf8.count <= 128 else {
            settingsNotice = "Enter a display name of 128 bytes or fewer."
            return false
        }

        userDisplayName = cleanName
        if !previewMode {
            UserDefaults.standard.set(cleanName, forKey: "NoctCord.displayName")
        }
        let targetIDs: [UUID]
        if acrossAllCommunities {
            targetIDs = spaces.map(\.id)
        } else if let selectedSpaceID {
            targetIDs = [selectedSpaceID]
        } else {
            targetIDs = []
        }

        if previewMode {
            let targets = Set(targetIDs)
            for index in spaces.indices where targets.contains(spaces[index].id) {
                let currentMember = spaces[index].currentMember
                spaces[index].members = spaces[index].members.map { member in
                    guard member.id == currentMember else { return member }
                    return NoctCordMemberViewState(
                        id: member.id,
                        displayName: cleanName,
                        roleName: member.roleName,
                        presence: member.presence,
                        isBot: member.isBot
                    )
                }
            }
            settingsNotice = targetIDs.isEmpty
                ? "Your default display name was saved."
                : "Your display name was updated."
            return true
        }

        guard let transport else {
            settingsNotice = "Connect at least one relay before publishing a community profile."
            return targetIDs.isEmpty
        }
        var updated = 0
        var firstFailure: Error?
        for spaceID in targetIDs {
            guard let space = spaces.first(where: { $0.id == spaceID }) else { continue }
            do {
                let binding = try await identityVault.binding(
                    scope: space.identityScope,
                    displayName: cleanName,
                    spaceID: spaceID,
                    memberHandle: space.currentMember
                )
                let publication = try await transport.publishOperation(
                    spaceID: spaceID,
                    operation: .bindIdentity(binding)
                )
                if !publication.complete {
                    try await transport.maintain(spaceID: spaceID)
                }
                try await reloadSpace(spaceID, using: transport)
                updated += 1
            } catch {
                if firstFailure == nil { firstFailure = error }
            }
        }
        if let firstFailure {
            settingsNotice = updated == 0
                ? "The local default was saved, but the community profile could not be updated: \(firstFailure.localizedDescription)"
                : "Updated \(updated) communities. At least one community could not be reached: \(firstFailure.localizedDescription)"
        } else {
            settingsNotice = targetIDs.isEmpty
                ? "Your default display name was saved."
                : "Your display name was updated in \(updated) \(updated == 1 ? "community" : "communities")."
        }
        return firstFailure == nil
    }

    public func setPrivacySettings(_ settings: PrivacySettings) {
        let previous = privacySettings
        privacySettings = settings
        guard !previewMode, let transport else {
            settingsNotice = "Privacy preferences are active on this device."
            return
        }
        Task {
            do {
                try await transport.updatePrivacySettings(settings)
                settingsNotice = "Privacy preferences saved locally."
            } catch {
                privacySettings = previous
                settingsNotice = "Privacy preferences were not saved: \(error.localizedDescription)"
            }
        }
    }

    @discardableResult
    public func addRelay(
        address: String,
        name: String,
        accessPassword: String
    ) async -> Bool {
        guard let transport else {
            settingsNotice = "Finish initial setup before adding another relay."
            return false
        }
        do {
            let endpoint = try RelayEndpointParser.parse(address)
            let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
            activityMessage = "Verifying the relay…"
            _ = try await transport.addRelay(
                endpoint: endpoint,
                name: cleanName.isEmpty ? endpoint.host : cleanName,
                accessPassword: accessPassword.isEmpty ? nil : accessPassword
            )
            relayProfiles = await transport.relayProfiles()
            activityMessage = nil
            settingsNotice = "Relay saved. New communities can use it independently."
            return true
        } catch {
            activityMessage = nil
            settingsNotice = error.localizedDescription
            return false
        }
    }

    public func setIdentityScope(_ scope: NoctCordIdentityScope) {
        if previewMode {
            updateSelectedSpace { $0.identityScope = scope }
            return
        }
        guard let selectedSpaceID, let transport, let space = selectedSpace else { return }
        activityMessage = "Updating the community profile…"
        Task {
            do {
                let binding = try await identityVault.binding(
                    scope: scope,
                    displayName: userDisplayName,
                    spaceID: selectedSpaceID,
                    memberHandle: space.currentMember
                )
                let publication = try await transport.publishOperation(
                    spaceID: selectedSpaceID,
                    operation: .bindIdentity(binding)
                )
                if !publication.complete {
                    try await transport.maintain(spaceID: selectedSpaceID)
                }
                identityScopes[selectedSpaceID] = scope
                try await reloadSpace(selectedSpaceID, using: transport)
                composerNotice = scope == .portable
                    ? "This community can now correlate your portable profile where you disclose it."
                    : "A fresh profile is now bound only to this community. Existing observations cannot be erased."
            } catch {
                composerNotice = error.localizedDescription
            }
            activityMessage = nil
        }
    }

    public func saveRole(
        id: UUID = UUID(),
        name: String,
        position: UInt16,
        permissions: Set<NoctCordPermission>
    ) {
        guard let spaceID = selectedSpaceID else { return }
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let role = NoctCordRole(
            id: id,
            name: cleanName,
            position: position,
            permissions: permissions
        )
        perform(.defineRole(role), spaceID: spaceID, activity: "Saving role…")
    }

    public func deleteRole(_ roleID: UUID) {
        guard let spaceID = selectedSpaceID else { return }
        perform(.deleteRole(id: roleID), spaceID: spaceID, activity: "Deleting role…")
    }

    public func setRole(_ roleID: UUID, for member: GroupScopedMemberHandleV2, assigned: Bool) {
        guard let spaceID = selectedSpaceID else { return }
        let operation: NoctCordOperation = assigned
            ? .grantRole(id: roleID, to: member)
            : .revokeRole(id: roleID, from: member)
        perform(operation, spaceID: spaceID, activity: "Updating member roles…")
    }

    public func setChannelPermissions(
        channelID: UUID,
        roleID: UUID?,
        allow: Set<NoctCordPermission>,
        deny: Set<NoctCordPermission>
    ) {
        guard let spaceID = selectedSpaceID, !allow.isEmpty || !deny.isEmpty else { return }
        perform(
            .setChannelPermissions(
                channelID: channelID,
                roleID: roleID,
                allow: allow,
                deny: deny
            ),
            spaceID: spaceID,
            activity: "Updating channel access…"
        )
    }

    public func clearChannelPermissions(channelID: UUID, roleID: UUID?) {
        guard let spaceID = selectedSpaceID else { return }
        perform(
            .removeChannelPermissions(channelID: channelID, roleID: roleID),
            spaceID: spaceID,
            activity: "Clearing channel override…"
        )
    }

    public func installBot(
        name: String,
        member: GroupScopedMemberHandleV2,
        commands: Set<NoctCordBotCommand>
    ) {
        guard let spaceID = selectedSpaceID else { return }
        let bot = NoctCordBotApplication(
            memberHandle: member,
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            commands: commands
        )
        perform(.installBot(bot), spaceID: spaceID, activity: "Installing application…")
    }

    public func removeBot(_ botID: UUID) {
        guard let spaceID = selectedSpaceID else { return }
        perform(.removeBot(id: botID), spaceID: spaceID, activity: "Removing application…")
    }

    public func sendAttachment(at url: URL) {
        guard let spaceID = selectedSpaceID,
              let channelID = selectedChannelID else { return }
        activityMessage = "Sanitizing attachment…"
        Task {
            do {
                let sanitized = try await NoctCordAttachmentSanitizer.sanitize(url: url)
                if previewMode {
                    let attachmentID = UUID()
                    let keyMaterial = SymmetricKey(size: .bits256)
                        .withUnsafeBytes { Data($0) }
                    let nonceMaterial = SymmetricKey(size: .bits256)
                        .withUnsafeBytes { Data($0) }
                    let manifest = NoctCordAttachmentManifestV1(
                        blobID: Data(attachmentID.uuidString.lowercased().utf8),
                        blobCapability: SymmetricKey(size: .bits256)
                            .withUnsafeBytes { Data($0) },
                        mediaType: sanitized.mimeType,
                        size: UInt64(sanitized.bytes.count),
                        digest: Data(SHA256.hash(data: sanitized.bytes)),
                        expiresAt: Date().addingTimeInterval(24 * 60 * 60),
                        encryption: NoctCordAttachmentEncryptionMetadataV1(
                            keyID: Data(UUID().uuidString.lowercased().utf8),
                            contentKey: keyMaterial,
                            nonce: Data(nonceMaterial.prefix(12))
                        )
                    )
                    cachedAttachments[attachmentID] = NoctCordDownloadedAttachment(
                        id: attachmentID,
                        bytes: sanitized.bytes,
                        mediaType: sanitized.mimeType
                    )
                    perform(
                        .addAttachment(
                            id: attachmentID,
                            channelID: channelID,
                            manifest: manifest
                        ),
                        spaceID: spaceID
                    )
                    activityMessage = nil
                    return
                }

                guard let transport else {
                    throw NoctCordTransportError.invalidConfiguration
                }
                activityMessage = "Encrypting and uploading…"
                let transfer = try await transport.attachmentTransfer(for: spaceID)
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
                if previewMode {
                    composerNotice = "The attachment could not be sanitized: \(error.localizedDescription)"
                } else {
                    connectionState = .failed(error.localizedDescription)
                }
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
                let transfer = try await transport.attachmentTransfer(for: space.id)
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
            if usesRelayDiscoveredICE,
               let expiry = relayICECredentialExpiresAt,
               expiry.timeIntervalSinceNow <= 60 {
                await refreshRelayCallConnectivity(using: transport)
            }
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
                let route = try await transport.createRealtimeRoute(for: space.id)
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

    private func refreshRelayCallConnectivity(
        using coordinator: NoctCordTransportCoordinator,
        for spaceID: UUID? = nil
    ) async {
        do {
            let discovered: NoctCordRelayICEConfiguration
            if let spaceID {
                discovered = try await coordinator.discoverCallConnectivity(for: spaceID)
            } else {
                discovered = try await coordinator.discoverCallConnectivity()
            }
            iceServers = discovered.servers
            relayICECredentialExpiresAt = discovered.credentialExpiresAt
            if discovered.servers.contains(where: { $0.credential != nil }) {
                callConnectivityDescription =
                    "Relay-provided TURN is ready. Media remains application-encrypted."
            } else if !discovered.servers.isEmpty {
                callConnectivityDescription =
                    "Relay-provided STUN is ready; direct peers may see each other's network address."
            } else {
                callConnectivityDescription =
                    "This relay does not advertise call traversal. Calls are limited to directly reachable peers."
            }
        } catch {
            if relayICECredentialExpiresAt.map({ $0 <= Date() }) != false {
                iceServers.removeAll { $0.credential != nil }
                relayICECredentialExpiresAt = nil
            }
            callConnectivityDescription =
                "Messaging is connected, but relay call traversal could not be verified. Direct paths may still work."
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
            await transport.closeRealtimeRoom(spaceID: spaceID, roomID: roomID)
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

    private func perform(
        _ operation: NoctCordOperation,
        spaceID: UUID,
        activity: String? = nil
    ) {
        if !previewMode {
            Task {
                await publishAndRefresh(operation, spaceID: spaceID, activity: activity)
            }
            return
        }

        guard let index = spaces.firstIndex(where: { $0.id == spaceID }) else { return }
        var space = spaces[index]
        let event = NoctCordEvent(
            spaceID: space.id,
            author: space.currentMember,
            logicalClock: Self.nextClock(in: space.events),
            operation: operation
        )
        do {
            try space.projection.apply(event)
            space.events.append(event)
            Self.refreshMemberPresentation(in: &space)
            spaces[index] = space
            connectionState = .preview
        } catch {
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

    private func reloadAllSpaces(
        using transport: NoctCordTransportCoordinator,
        synchronize: Bool = true,
        assessRelays: Bool = true
    ) async throws {
        let previousSpaceID = selectedSpaceID
        let previousChannelID = selectedChannelID
        var loaded: [NoctCordSpaceSession] = []
        for spaceID in await transport.storedSpaceIDs() {
            if synchronize {
                _ = try? await transport.synchronize(spaceID: spaceID)
                _ = try? await transport.ensureCommunityBootstrap(spaceID: spaceID)
            }
            loaded.append(try await makeSession(
                spaceID: spaceID,
                using: transport,
                assessRelay: assessRelays
            ))
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
           selectedSpace?.textChannels.contains(where: { $0.id == previousChannelID }) == true {
            selectedChannelID = previousChannelID
        } else {
            selectedChannelID = selectedSpace?.textChannels.first?.id
        }
        resumePendingCommunityLifecycleOperations(using: transport)
    }

    private func resumePendingCommunityLifecycleOperations(
        using transport: NoctCordTransportCoordinator
    ) {
        guard communityLifecycleRecoveryTask == nil else { return }
        communityLifecycleRecoveryTask = Task { [weak self] in
            await transport.maintainAllStoredCommunities()
            guard !Task.isCancelled else { return }
            self?.communityLifecycleRecoveryTask = nil
        }
    }

    private func performCommunityLifecycle(
        _ action: NoctCordCommunityLifecycleAction,
        spaceID: UUID
    ) async throws {
        guard communityLifecycleOperationSpaceID == nil else {
            throw NoctCordTransportError.transportIncomplete
        }
        communityLifecycleOperationSpaceID = spaceID
        activityMessage = action == .leave
            ? "Leaving community securely…"
            : "Destroying community securely…"
        defer {
            communityLifecycleOperationSpaceID = nil
            activityMessage = nil
        }

        if previewMode {
            await removeCommunityFromActiveUI(spaceID)
            return
        }
        guard let transport else {
            throw NoctCordTransportError.invalidConfiguration
        }
        switch action {
        case .leave:
            let result = try await transport.leaveCommunity(spaceID: spaceID)
            guard result.complete else {
                throw NoctCordTransportError.transportIncomplete
            }
        case .destroy:
            let result = try await transport.destroyCommunity(spaceID: spaceID)
            guard result.complete else {
                throw NoctCordTransportError.transportIncomplete
            }
        }
        await removeCommunityFromActiveUI(spaceID)
    }

    private func removeCommunityFromActiveUI(_ spaceID: UUID) async {
        guard let departingSpace = spaces.first(where: { $0.id == spaceID }) else {
            return
        }
        if selectedSpaceID == spaceID {
            mediaRefreshTask?.cancel()
            mediaRefreshTask = nil
            if let mediaRoom {
                await mediaRoom.leave()
            }
            mediaRoom = nil
            callSnapshot = nil
            processedCallSignalIDs.removeAll()
        }

        let attachmentIDs = Set(departingSpace.projection.attachments.keys)
        cachedAttachments = cachedAttachments.filter { !attachmentIDs.contains($0.key) }
        if let selectedAttachmentID, attachmentIDs.contains(selectedAttachmentID) {
            self.selectedAttachmentID = nil
        }
        identityScopes.removeValue(forKey: spaceID)
        spaces.removeAll { $0.id == spaceID }

        if selectedSpaceID == spaceID {
            selectedSpaceID = spaces.first?.id
            selectedChannelID = selectedSpace?.textChannels.first?.id
            composerText = ""
            searchQuery = ""
        }
        showsCommunitySettings = false
        showsInvitationExchange = false

        if !previewMode,
           usesRelayDiscoveredICE,
           let transport,
           let selectedSpaceID {
            await refreshRelayCallConnectivity(using: transport, for: selectedSpaceID)
        }
    }

    private func reloadSpace(
        _ spaceID: UUID,
        using transport: NoctCordTransportCoordinator
    ) async throws {
        _ = try? await transport.synchronize(spaceID: spaceID)
        _ = try? await transport.ensureCommunityBootstrap(spaceID: spaceID)
        let session = try await makeSession(spaceID: spaceID, using: transport)
        if let index = spaces.firstIndex(where: { $0.id == spaceID }) {
            spaces[index] = session
        } else {
            spaces.append(session)
        }
        if selectedSpaceID == spaceID,
           selectedChannelID.map({ selected in
               session.textChannels.contains(where: { $0.id == selected })
           }) != true {
            selectedChannelID = session.textChannels.first?.id
        }
    }

    private func makeSession(
        spaceID: UUID,
        using transport: NoctCordTransportCoordinator,
        assessRelay: Bool = true
    ) async throws -> NoctCordSpaceSession {
        let snapshot = try await transport.storedSpaceSnapshot(
            spaceID: spaceID,
            assessRelay: assessRelay
        )
        let activeMembers = Set(snapshot.members.map(\.handle))
        let projection = NoctCordSpaceProjection.project(
            spaceID: spaceID,
            owner: snapshot.owner,
            activeMembers: activeMembers,
            historicalMembers: Set(snapshot.events.map(\.author)),
            events: snapshot.events
        ).projection
        let botMembers = Set(projection.botApplications.values.map(\.memberHandle))
        let members = snapshot.members.map { member in
            let projectedRoleName: String
            if member.handle == projection.owner {
                projectedRoleName = "Owner"
            } else if botMembers.contains(member.handle) {
                projectedRoleName = "App"
            } else {
                projectedRoleName = projection.roles(for: member.handle).first?.name ?? "Member"
            }
            return NoctCordMemberViewState(
                id: member.handle,
                displayName: projection.identityBindings[member.handle]?.profile.displayName
                    ?? (member.isCurrentMember
                        ? "You"
                        : "Member \(Self.compactHandle(member.handle))"),
                roleName: projectedRoleName,
                presence: member.isCurrentMember ? .active : .offline,
                isBot: botMembers.contains(member.handle)
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
        return NoctCordSpaceSession(
            id: spaceID,
            shortName: Self.shortName(projection.name ?? "Space"),
            currentMember: snapshot.currentMember,
            identityScope: projection.identityBindings[snapshot.currentMember]?.profile.scope
                ?? identityScopes[spaceID]
                ?? .isolated,
            members: members,
            events: snapshot.events,
            projection: projection,
            unreadByChannel: spaces.first(where: { $0.id == spaceID })?.unreadByChannel ?? [:],
            voiceRooms: voiceRooms,
            activeVoiceRoomID: activeVoiceRoomID,
            relayName: snapshot.relayName,
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
            historicalMembers: Set(space.events.map(\.author)),
            events: space.events
        ).projection
        refreshMemberPresentation(in: &space)
    }

    private static func refreshMemberPresentation(in space: inout NoctCordSpaceSession) {
        let botMembers = Set(space.projection.botApplications.values.map(\.memberHandle))
        space.members = space.members.map { member in
            let roleName: String
            if member.id == space.projection.owner {
                roleName = "Owner"
            } else if botMembers.contains(member.id) {
                roleName = "App"
            } else {
                roleName = space.projection.roles(for: member.id).first?.name ?? "Member"
            }
            return NoctCordMemberViewState(
                id: member.id,
                displayName: space.projection.identityBindings[member.id]?.profile.displayName
                    ?? member.displayName,
                roleName: roleName,
                presence: member.presence,
                isBot: botMembers.contains(member.id)
            )
        }
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
        let botMember = handle(7)
        let maintainerRole = NoctCordRole(
            id: UUID(uuidString: "30000000-0000-0000-0000-000000000001")!,
            name: "Maintainer",
            position: 50,
            permissions: [
                .manageChannels,
                .manageMessages,
                .manageRoles,
                .manageBots,
            ]
        )
        let relayGuide = NoctCordBotApplication(
            id: UUID(uuidString: "40000000-0000-0000-0000-000000000001")!,
            memberHandle: botMember,
            name: "Relay Guide",
            commands: [
                NoctCordBotCommand(
                    name: "status",
                    summary: "Summarize relay and channel health"
                ),
            ]
        )
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
        append(owner, .defineRole(maintainerRole), now.addingTimeInterval(-4_450))
        append(owner, .grantRole(id: maintainerRole.id, to: aster), now.addingTimeInterval(-4_440))
        append(owner, .installBot(relayGuide), now.addingTimeInterval(-4_430))
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
            NoctCordMemberViewState(
                id: botMember,
                displayName: "Relay Guide",
                roleName: "App",
                presence: .active,
                isBot: true
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
        let staffChannelID = UUID(uuidString: "21000000-0000-0000-0000-000000000002")!
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
            NoctCordEvent(
                spaceID: spaceID,
                author: owner,
                logicalClock: 4,
                createdAt: now.addingTimeInterval(-1_700),
                operation: .setChannelPermissions(
                    channelID: channelID,
                    roleID: nil,
                    allow: [],
                    deny: [.sendMessages]
                )
            ),
            NoctCordEvent(
                spaceID: spaceID,
                author: owner,
                logicalClock: 5,
                createdAt: now.addingTimeInterval(-1_600),
                operation: .createChannel(id: staffChannelID, name: "staff")
            ),
            NoctCordEvent(
                spaceID: spaceID,
                author: owner,
                logicalClock: 6,
                createdAt: now.addingTimeInterval(-1_500),
                operation: .setChannelPermissions(
                    channelID: staffChannelID,
                    roleID: nil,
                    allow: [],
                    deny: [.readMessages]
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
