import Foundation
import CryptoKit
import NoctCordCore
import NoctCordMedia
@preconcurrency import NoctweaveCore

#if !NOCTCORD_VERIFIED_CORE
#error("NoctCord transport requires authenticated Core receipts and NOCTCORD_VERIFIED_CORE; legacy policy authoring is disabled.")
#endif

// Noctweave's sync result is immutable value state, but its current public
// declaration predates Swift 6 Sendable annotations. This local conformance
// allows the dedicated transport actor to pass verified events to the UI.
extension GroupInboundSyncResultV2: @retroactive @unchecked Sendable {}

public enum NoctCordTransportError: Error, Equatable, LocalizedError {
    case invalidConfiguration
    case spaceNotFound
    case eventRejected
    case transportIncomplete
    case unsupportedEvent
    case voiceRouteExpired
    case invitationPermissionDenied
    case ownerCannotLeave
    case communityOwnerRequired
    case communityTerminal
    case checkpointCapacityReached
    case snapshotProposalMismatch

    public var errorDescription: String? {
        switch self {
        case .invalidConfiguration:
            "The Noct Cord transport configuration is invalid."
        case .spaceNotFound:
            "The encrypted space is not present in this client."
        case .eventRejected:
            "The encrypted space event was rejected before publication."
        case .transportIncomplete:
            "The relay did not acknowledge every intended recipient. The operation can be retried."
        case .unsupportedEvent:
            "The received group event is not a supported Noct Cord operation."
        case .voiceRouteExpired:
            "This voice room needs an administrator to renew its encrypted realtime route."
        case .invitationPermissionDenied:
            "Only the community owner can complete this admission flow."
        case .ownerCannotLeave:
            "The community owner cannot leave. Destroy the community instead."
        case .communityOwnerRequired:
            "Only the community owner can destroy this community."
        case .communityTerminal:
            "This community has already been left or destroyed."
        case .checkpointCapacityReached:
            "The verified policy history is full while retained messages still depend on it. Wait for safe history compaction before another policy change."
        case .snapshotProposalMismatch:
            "A different owner snapshot is already signed. Resume that exact proposal or review it before trying again."
        }
    }
}

public struct NoctCordTransportConfiguration: Sendable {
    public let stateURL: URL
    public let storageScopeIdentifier: String
    public let displayName: String
    public let relay: RelayEndpoint
    public let relayName: String
    public let relayAccessPassword: String?
    public let usesInsecurePlaintextStateForTesting: Bool

    public init(
        stateURL: URL,
        storageScopeIdentifier: String? = nil,
        displayName: String,
        relay: RelayEndpoint,
        relayName: String,
        relayAccessPassword: String? = nil,
        usesInsecurePlaintextStateForTesting: Bool = false
    ) {
        self.stateURL = stateURL
        self.storageScopeIdentifier = storageScopeIdentifier
            ?? Self.defaultStorageScopeIdentifier(for: stateURL)
        self.displayName = displayName
        self.relay = relay
        self.relayName = relayName
        self.relayAccessPassword = relayAccessPassword
        self.usesInsecurePlaintextStateForTesting = usesInsecurePlaintextStateForTesting
    }

    #if DEBUG
    public static func liveUITest(
        stateURL: URL,
        displayName: String,
        relayPort: UInt16
    ) -> NoctCordTransportConfiguration {
        NoctCordTransportConfiguration(
            stateURL: stateURL,
            storageScopeIdentifier: "org.noctcord.live-ui-test.\(displayName.lowercased())",
            displayName: displayName,
            relay: RelayEndpoint(host: "127.0.0.1", port: relayPort, transport: .tcp),
            relayName: "Local live UI-test relay",
            usesInsecurePlaintextStateForTesting: true
        )
    }
    #endif

    /// The sandboxed app and local `swift run` builds have different storage
    /// containers. They must not share one Keychain rollback anchor because a
    /// valid state file in either container is intentionally invisible to the
    /// other and would otherwise look like a rollback attack.
    public static func defaultStorageScopeIdentifier(for stateURL: URL) -> String {
        let path = stateURL.standardizedFileURL.path
        if path.contains("/Library/Containers/") {
            return "org.noctcord.client-state.macos-sandbox.v1"
        }
        // Preserve the deployed development scope so existing unsandboxed
        // state remains readable while production state is isolated.
        return "org.noctcord.client-state.v1"
    }

    public var isStructurallyValid: Bool {
        !storageScopeIdentifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && storageScopeIdentifier.utf8.count <= 256
            && !displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && displayName.utf8.count <= 256
            && !relayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && relayName.utf8.count <= 512
            && (relayAccessPassword?.utf8.count ?? 0) <= RelayClient.maxAuthenticationBytes
            && (try? relay.isStructurallyValidThrowing) == true
    }
}

public struct NoctCordSpaceBootstrap: Sendable {
    public let spaceID: UUID
    public let owner: GroupScopedMemberHandleV2
    public let generalChannelID: UUID
    public let events: [NoctCordEvent]
    public let relayAssessment: NoctCordRelayAssessment
}

public struct NoctCordRelayProfile: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let name: String
    public let endpoint: RelayEndpoint
    public let hasAccessPassword: Bool

    public init(
        id: UUID,
        name: String,
        endpoint: RelayEndpoint,
        hasAccessPassword: Bool
    ) {
        self.id = id
        self.name = name
        self.endpoint = endpoint
        self.hasAccessPassword = hasAccessPassword
    }

    public var address: String {
        let scheme: String
        switch endpoint.transport {
        case .tcp:
            scheme = endpoint.useTLS ? "tls" : "tcp"
        case .http:
            scheme = endpoint.useTLS ? "https" : "http"
        case .websocket:
            scheme = endpoint.useTLS ? "wss" : "ws"
        }
        return "\(scheme)://\(endpoint.host):\(endpoint.port)"
    }
}

public struct NoctCordTransportPublication: Sendable {
    public let event: NoctCordEvent
    public let operationID: UUID?
    public let complete: Bool
}

public enum NoctCordCommunityLifecycleAction: String, Equatable, Sendable {
    case leave
    case destroy
}

public struct NoctCordCommunityLifecycleResult: Sendable {
    public let spaceID: UUID
    public let action: NoctCordCommunityLifecycleAction
    public let operationID: UUID?
    public let complete: Bool
}

public struct NoctCordTransportMember: Sendable {
    public let handle: GroupScopedMemberHandleV2
    public let roleName: String
    public let isCurrentMember: Bool
}

public enum NoctCordPolicyMode: String, Equatable, Sendable {
    /// Compatibility mode for the published Core pin before verified receipts
    /// become available. This mode must not be used after v2 activation.
    case legacyWritable
    case legacyReadOnly
    case awaitingOwnerCheckpoint
    case verified
}

public struct NoctCordStoredSpaceSnapshot: Sendable {
    public let spaceID: UUID
    public let groupEpoch: UInt64
    public let owner: GroupScopedMemberHandleV2
    public let currentMember: GroupScopedMemberHandleV2
    public let members: [NoctCordTransportMember]
    public let events: [NoctCordEvent]
    public let policyMode: NoctCordPolicyMode
    public let verifiedProjection: NoctCordProjectionResult?
    /// Bounded v1 history for display only. It never supplies current roles,
    /// ACLs, bot dispatch, or realtime permission decisions.
    public let legacyArchiveEvents: [NoctCordEvent]
    public let relay: RelayEndpoint
    public let relayName: String
    public let relayAssessment: NoctCordRelayAssessment
}

public struct NoctCordReceivedRealtimeSignal: Sendable {
    public let author: GroupScopedMemberHandleV2
    public let signal: NoctCordEncryptedCallSignalV1
}

public struct NoctCordRelayICEConfiguration: Sendable {
    public let servers: [NoctCordMediaICEServer]
    public let relayAdvertised: Bool
    public let relayOnlySupported: Bool
    public let credentialExpiresAt: Date?

    public init(
        servers: [NoctCordMediaICEServer],
        relayAdvertised: Bool,
        relayOnlySupported: Bool,
        credentialExpiresAt: Date?
    ) {
        self.servers = servers
        self.relayAdvertised = relayAdvertised
        self.relayOnlySupported = relayOnlySupported
        self.credentialExpiresAt = credentialExpiresAt
    }
}

private struct NoctCordRealtimeSubscriptionState: Sendable {
    let spaceID: UUID
    let routeCapability: Data
    let subscriptionCapability: Data
    var cursor: UInt64
    let expiresAt: Date
}

/// Production transport bridge between Noct Cord application events and the
/// durable Noctweave group runtime. It does not expose group secrets, receive
/// capabilities, or relay credentials to the SwiftUI layer.
public actor NoctCordTransportCoordinator {
    private let client: HeadlessMessagingClient
    /// Bootstrap/default relay for creating a community when the caller has
    /// not selected one. Existing communities always resolve their own relay
    /// from their encrypted group receive-route state.
    private let relay: RelayEndpoint
    private let relayAccessPassword: String?
    private var realtimeSubscriptions: [UUID: NoctCordRealtimeSubscriptionState] = [:]

    public static func open(
        configuration: NoctCordTransportConfiguration
    ) async throws -> NoctCordTransportCoordinator {
        guard configuration.isStructurallyValid else {
            throw NoctCordTransportError.invalidConfiguration
        }
        #if DEBUG
        let protection: ClientStateStoreProtection = configuration
            .usesInsecurePlaintextStateForTesting
            ? .insecurePlaintextForTesting
            : .encrypted
        #else
        guard !configuration.usesInsecurePlaintextStateForTesting else {
            throw NoctCordTransportError.invalidConfiguration
        }
        let protection: ClientStateStoreProtection = .encrypted
        #endif
        let store = ClientStateStore(
            fileURL: configuration.stateURL,
            protection: protection,
            storageScopeIdentifier: configuration.storageScopeIdentifier
        )
        let client = try await HeadlessMessagingClient.open(
            stateStore: store,
            displayName: configuration.displayName
        )
        try await client.upsertRelayPreference(
            endpoint: configuration.relay,
            name: configuration.relayName,
            accessPassword: configuration.relayAccessPassword
        )
        return try NoctCordTransportCoordinator(
            client: client,
            relay: configuration.relay,
            relayAccessPassword: configuration.relayAccessPassword
        )
    }

    /// Destructive recovery is deliberately explicit. The state store writes
    /// a trusted tombstone before removing ciphertext, so replaying an older
    /// database remains detectable after the reset.
    public static func eraseLocalState(
        configuration: NoctCordTransportConfiguration
    ) async throws {
        guard configuration.isStructurallyValid else {
            throw NoctCordTransportError.invalidConfiguration
        }
        let store = ClientStateStore(
            fileURL: configuration.stateURL,
            protection: .encrypted,
            storageScopeIdentifier: configuration.storageScopeIdentifier
        )
        try await store.eraseAllLocalState()
    }

    /// Test and embedding initializer. The caller owns the client's encrypted
    /// state-store policy and lifecycle.
    public init(
        client: HeadlessMessagingClient,
        relay: RelayEndpoint,
        relayAccessPassword: String? = nil
    ) throws {
        guard (try? relay.isStructurallyValidThrowing) == true else {
            throw NoctCordTransportError.invalidConfiguration
        }
        self.client = client
        self.relay = relay
        self.relayAccessPassword = relayAccessPassword
    }

    /// Called after polling tasks stop. Full local reset must work offline and
    /// does not need to wait for remote unsubscribe acknowledgements.
    public func discardRealtimeRooms() {
        realtimeSubscriptions.removeAll()
    }

    public func storedSpaceIDs() async -> [UUID] {
        await client.snapshot().activePersona.groupRuntimes
            .filter { $0.localRemoval == nil && $0.deletionState == nil }
            .map(\.groupId).sorted {
            $0.uuidString < $1.uuidString
        }
    }

    /// Retries only already-persisted work for every retained runtime,
    /// including terminal records hidden from the active community list.
    /// This is what lets an interrupted leave or destruction finish after a
    /// restart without discarding the replay-rejection record.
    public func maintainAllStoredCommunities(at date: Date = Date()) async {
        let groupIDs = await client.snapshot().activePersona.groupRuntimes
            .filter { runtime in
                if let deletion = runtime.deletionState {
                    return deletion.publicationState != .published
                }
                return runtime.localRemoval == nil
                    && runtime.epochIntents.contains {
                        $0.isLocalSelfRemoval && $0.phase != .finalized
                    }
            }
            .map(\.groupId)
            .sorted { $0.uuidString < $1.uuidString }
        for groupID in groupIDs {
            _ = try? await client.maintainGroup(groupID: groupID, at: date)
        }
    }

    public func relayProfiles() async -> [NoctCordRelayProfile] {
        await client.snapshot().relayPreferences
            .map(Self.profile(from:))
            .sorted {
                if $0.name != $1.name {
                    return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
                }
                return $0.address < $1.address
            }
    }

    @discardableResult
    public func addRelay(
        endpoint: RelayEndpoint,
        name: String,
        accessPassword: String?
    ) async throws -> NoctCordRelayProfile {
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanPassword = accessPassword?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanName.isEmpty,
              cleanName.utf8.count <= 512,
              cleanPassword?.utf8.count ?? 0 <= RelayClient.maxAuthenticationBytes,
              (try? endpoint.isStructurallyValidThrowing) == true else {
            throw NoctCordTransportError.invalidConfiguration
        }
        let response = try await RelayClient(
            endpoint: endpoint,
            authToken: cleanPassword?.isEmpty == false ? cleanPassword : nil
        ).send(.health(), timeout: 5)
        guard response.status == .success, response.error == nil else {
            throw NoctCordTransportError.transportIncomplete
        }
        try await client.upsertRelayPreference(
            endpoint: endpoint,
            name: cleanName,
            accessPassword: cleanPassword?.isEmpty == false ? cleanPassword : nil
        )
        guard let preference = await client.snapshot().relayPreferences.first(where: {
            $0.endpoint == endpoint
        }) else {
            throw NoctCordTransportError.invalidConfiguration
        }
        return Self.profile(from: preference)
    }

    public func privacySettings() async -> PrivacySettings {
        await client.snapshot().privacy
    }

    public func updatePrivacySettings(_ settings: PrivacySettings) async throws {
        try await client.updatePrivacySettings(settings)
    }

    public func createSpace(
        name: String,
        relayPreferenceID: UUID? = nil,
        createdAt: Date = Date()
    ) async throws -> NoctCordSpaceBootstrap {
        guard NoctCordValidationBridge.isName(name),
              createdAt.timeIntervalSince1970.isFinite else {
            throw NoctCordTransportError.invalidConfiguration
        }
        let selectedRelay = try await relayEndpoint(
            forPreferenceID: relayPreferenceID
        )
        let groupID = UUID()
        let generalChannelID = UUID()
        _ = try await client.createGroup(
            groupID: groupID,
            relay: selectedRelay,
            contentTypes: NoctCordCodec.contentCapabilities,
            createdAt: createdAt
        )
        let runtime = try await client.openGroupRuntime(groupID: groupID)
        let snapshot = await runtime.snapshot()
        let owner = snapshot.localCredential.memberHandle
        let events = [
            NoctCordEvent(
                spaceID: groupID,
                author: owner,
                logicalClock: 1,
                createdAt: createdAt,
                operation: .createSpace(name: name)
            ),
            NoctCordEvent(
                spaceID: groupID,
                author: owner,
                logicalClock: 2,
                createdAt: createdAt.addingTimeInterval(1),
                operation: .createChannel(id: generalChannelID, name: "general")
            ),
        ]
        #if NOCTCORD_VERIFIED_CORE
        let genesis = try await publishVerifiedCheckpoint(
            spaceID: groupID,
            operation: .applyBootstrap(events),
            kind: .snapshot,
            at: createdAt.addingTimeInterval(2)
        )
        guard genesis.complete else {
            throw NoctCordTransportError.transportIncomplete
        }
        #else
        for event in events {
            let publication = try await publish(event)
            guard publication.complete else {
                throw NoctCordTransportError.transportIncomplete
            }
        }
        #endif
        let infoResponse = try? await relayClient(for: selectedRelay).send(.info())
        let assessment: NoctCordRelayAssessment
        if case .relayInfo(let info)? = infoResponse?.successBody {
            assessment = NoctCordRelaySupport.assess(info)
        } else {
            assessment = NoctCordRelaySupport.assess(
                RelayCapabilityManifestV2.advertised(
                    attachmentsEnabled: false,
                    wakeEnabled: false,
                    hiddenRetrievalEnabled: false,
                    onionEnabled: false,
                    mixnetEnabled: false
                ),
                temporalBucketSeconds: 0
            )
        }
        return NoctCordSpaceBootstrap(
            spaceID: groupID,
            owner: owner,
            generalChannelID: generalChannelID,
            events: events,
            relayAssessment: assessment
        )
    }

    /// Creates the bounded first artifact in Noct Cord's offline community
    /// admission exchange. The invitation contains no relay password or group
    /// secret and must be delivered through a channel where the recipient can
    /// authenticate the inviter.
    public func makeCommunityInvitation(
        spaceID: UUID,
        spaceName: String,
        lifetime: TimeInterval = 60 * 60,
        issuedAt: Date = Date()
    ) async throws -> NoctCordCommunityInvitationV1 {
        let runtime = try await client.openGroupRuntime(groupID: spaceID)
        let snapshot = await runtime.snapshot()
        guard snapshot.deletionState == nil,
              snapshot.localRemoval == nil,
              let member = snapshot.signedState.members.first(where: {
                  $0.id == snapshot.localCredential.memberHandle
                      && $0.isActive(at: snapshot.signedState.epoch)
              }),
              member.role == .owner,
              snapshot.signedState.permissions.allows(
                  .manageInvitations,
                  for: member.role
              ) else {
            throw NoctCordTransportError.invitationPermissionDenied
        }
        #if NOCTCORD_VERIFIED_CORE
        let verified = try NoctCordSecureProjectionV2.project(verified: snapshot)
        let configuration = try verified.projection.checkpointConfiguration(
            createdAt: issuedAt
        )
        _ = try Self.plannedSnapshotChunks(
            configuration, snapshot: snapshot,
            extraCredential: GroupScopedCredentialHandleV2.generate()
        )
        #endif
        guard let digest = snapshot.signedState.digest else {
            throw NoctCordTransportError.eventRejected
        }
        let communityRelay = try await relayEndpoint(for: spaceID)
        return try NoctCordCommunityInvitationV1.create(
            spaceID: spaceID,
            spaceName: spaceName,
            relay: communityRelay,
            baseEpoch: snapshot.signedState.epoch,
            baseStateDigest: digest,
            lifetime: lifetime,
            issuedAt: issuedAt
        )
    }

    /// Generates a fresh group-only credential and receive route for one
    /// invitation. The returned request is safe to transfer only through the
    /// same authenticated exchange used for the invitation.
    public func prepareCommunityAdmission(
        invitation: NoctCordCommunityInvitationV1,
        createdAt: Date = Date()
    ) async throws -> NoctCordPreparedCommunityAdmission {
        guard invitation.isValid(at: createdAt) else {
            throw NoctCordCommunityInvitationError.expiredInvitation
        }
        try await ensureRelayPreference(
            endpoint: invitation.relay,
            name: invitation.relay.host
        )
        let prepared = try await client.prepareGroupAdmission(
            groupID: invitation.spaceID,
            invitationBindingDigest: invitation.invitationBindingDigest,
            relay: invitation.relay,
            contentTypes: NoctCordCodec.contentCapabilities,
            expiresAt: invitation.expiresAt,
            createdAt: createdAt
        )
        let route = try await client.resumeGroupAdmissionRoute(
            admissionID: prepared.admissionID,
            at: createdAt
        )
        let request = try NoctweaveGroupAdmissionRequestLinkV1(
            admissionID: prepared.admissionID,
            groupID: prepared.groupID,
            invitationBindingDigest: invitation.invitationBindingDigest,
            admission: route.admission,
            initialRouteSet: route.routeSet
        )
        return NoctCordPreparedCommunityAdmission(
            invitation: invitation,
            admissionID: prepared.admissionID,
            requestCode: try request.encoded()
        )
    }

    /// Verifies and admits one prospective member. Explicit invocation is the
    /// authorization boundary: importing an arbitrary request never adds a
    /// member until a locally authorized user approves it.
    public func approveCommunityAdmissionRequest(
        _ requestCode: String,
        for spaceID: UUID,
        role: GroupRole = .member,
        createdAt: Date = Date()
    ) async throws -> String {
        let request = try NoctweaveGroupAdmissionRequestLinkV1.decode(requestCode)
        guard request.groupID == spaceID else {
            throw NoctCordCommunityInvitationError.invalidExchange
        }
        let runtime = try await client.openGroupRuntime(groupID: spaceID)
        let snapshot = await runtime.snapshot()
        guard snapshot.deletionState == nil,
              snapshot.localRemoval == nil,
              let member = snapshot.signedState.members.first(where: {
                  $0.id == snapshot.localCredential.memberHandle
                      && $0.isActive(at: snapshot.signedState.epoch)
              }),
              member.role == .owner,
              snapshot.signedState.permissions.allows(
                  .manageInvitations,
                  for: member.role
              ) else {
            throw NoctCordTransportError.invitationPermissionDenied
        }
        #if NOCTCORD_VERIFIED_CORE
        let verified = try NoctCordSecureProjectionV2.project(verified: snapshot)
        let configuration = try verified.projection.checkpointConfiguration(
            createdAt: createdAt
        )
        _ = try Self.plannedSnapshotChunks(
            configuration, snapshot: snapshot,
            extraCredential: request.admission.credentialHandle
        )
        #endif
        let prepared = try await client.prepareGroupMemberAddition(
            groupID: spaceID,
            admission: request.admission,
            initialRouteSet: request.initialRouteSet,
            role: role,
            anchorExpiresAt: request.admission.expiresAt,
            idempotencyKey: try request.requestDigest,
            createdAt: createdAt
        )
        let response = try NoctweaveGroupAdmissionResponseLinkV1(
            request: request,
            prepared: prepared
        )
        if let operation = prepared.transportOperation {
            let resumed = try await client.resumeGroupTransport(
                groupID: spaceID,
                operationID: operation.id,
                at: createdAt
            )
            guard resumed.complete else {
                throw NoctCordTransportError.transportIncomplete
            }
        }
        _ = try? await client.maintainGroup(groupID: spaceID)
        #if NOCTCORD_VERIFIED_CORE
        // Admission changes the group epoch. The owner must publish a
        // current-epoch snapshot for the joiner; failure leaves the joiner
        // explicitly awaiting that snapshot and can be retried later.
        _ = try? await ensureCommunityBootstrap(spaceID: spaceID)
        #endif
        return try response.encoded()
    }

    /// Accepts the exact signed epoch and Welcome returned by an authorized
    /// existing member. Every step is durable and replay-idempotent inside the
    /// Noctweave client state.
    public func acceptCommunityAdmissionResponse(
        _ responseCode: String,
        observedAt: Date = Date()
    ) async throws -> UUID {
        let response = try NoctweaveGroupAdmissionResponseLinkV1.decode(responseCode)
        if await storedSpaceIDs().contains(response.groupID) {
            return response.groupID
        }
        _ = try await client.pinGroupJoinAnchor(
            admissionID: response.admissionID,
            anchor: response.anchor,
            invitationBindingDigest: response.invitationBindingDigest,
            observedAt: observedAt
        )
        for announcement in response.existingMemberRouteAnnouncements {
            _ = try await client.acceptGroupAdmissionRouteAnnouncement(
                admissionID: response.admissionID,
                announcement: announcement,
                observedAt: observedAt
            )
        }
        _ = try await client.acceptGroupAdmissionTransition(
            admissionID: response.admissionID,
            transition: response.transition,
            observedAt: observedAt
        )
        let completed = try await client.acceptGroupAdmissionWelcome(
            admissionID: response.admissionID,
            welcome: response.welcome,
            observedAt: observedAt
        )
        guard completed.completed else {
            throw NoctCordTransportError.transportIncomplete
        }
        _ = try await client.maintainGroup(groupID: response.groupID)
        #if NOCTCORD_VERIFIED_CORE
        // This one signed control request learns the joiner's current route.
        // It is v1-shaped for wire compatibility but never enters v2 policy
        // projection and grants no application authority.
        try await publishVerifiedJoinControlRequest(
            spaceID: response.groupID, at: observedAt
        )
        return response.groupID
        #else
        let bootstrapRequest = try await publishOperation(
            spaceID: response.groupID,
            operation: .requestBootstrap(),
            at: observedAt
        )
        guard bootstrapRequest.complete else {
            throw NoctCordTransportError.transportIncomplete
        }
        return response.groupID
        #endif
    }

    /// Answers encrypted bootstrap requests once the owner's route cache has
    /// learned the new member's announced receive route. Calls are idempotent:
    /// request IDs already covered by an owner batch are not sent again.
    @discardableResult
    public func ensureCommunityBootstrap(spaceID: UUID) async throws -> Bool {
        let runtime = try await client.openGroupRuntime(groupID: spaceID)
        var snapshot = await runtime.snapshot()
        guard snapshot.localCredential.memberHandle
                == snapshot.signedState.members.first(where: {
                    $0.role == .owner && $0.isActive(at: snapshot.signedState.epoch)
                })?.id else {
            return false
        }
        #if NOCTCORD_VERIFIED_CORE
        try await pinReceivedCheckpoints(snapshot.events, runtime: runtime)
        snapshot = await runtime.snapshot()
        let pendingFragment = snapshot.pendingApplicationPublications.contains {
            guard let secure = try? NoctCordCodec.unwrapSecure($0.event),
                  let checkpoint = secure.checkpoint else { return false }
            return checkpoint.groupEpoch == snapshot.signedState.epoch
                && checkpoint.snapshotFragment != nil
        }
        if try Self.incompleteSnapshotFragment(in: snapshot) != nil
            || pendingFragment {
            let previous = try NoctCordSecureProjectionV2.projectForOwnerRebind(
                verified: snapshot
            )
            let configuration = try previous.projection.checkpointConfiguration(
                createdAt: Date()
            )
            let publication: NoctCordTransportPublication
            do {
                publication = try await publishVerifiedSnapshotSeries(
                    spaceID: spaceID, configuration: configuration, at: Date()
                )
            } catch NoctCordTransportError.snapshotProposalMismatch {
                publication = try await publishVerifiedSnapshotSeries(
                    spaceID: spaceID, configuration: configuration,
                    rotateVoiceRoutes: true, at: Date()
                )
            }
            guard publication.complete else {
                throw NoctCordTransportError.transportIncomplete
            }
            return true
        }
        if let pending = snapshot.pendingApplicationPublications.first(where: {
            guard let secure = try? NoctCordCodec.unwrapSecure($0.event),
                  let checkpoint = secure.checkpoint else { return false }
            return checkpoint.kind == .snapshot
                && checkpoint.groupEpoch == snapshot.signedState.epoch
        }), let secure = try? NoctCordCodec.unwrapSecure(pending.event),
           secure.checkpoint?.snapshotFragment == nil {
            // Resume the exact signed snapshot. Rebuilding configuration here
            // would generate new nested event IDs and fork the owner chain.
            let resumed = try await publishVerifiedCheckpoint(
                spaceID: spaceID,
                operation: secure.event.operation,
                kind: .snapshot,
                snapshotFragment: secure.checkpoint?.snapshotFragment,
                at: Date()
            )
            guard resumed.complete else {
                throw NoctCordTransportError.transportIncomplete
            }
            return true
        }
        guard try Self.latestCheckpointDigest(in: snapshot) != nil else {
            return false
        }
        if snapshot.protectedApplicationEventIDs.contains(where: { id in
            guard let outer = snapshot.events.first(where: { $0.id == id }),
                  let secure = try? NoctCordCodec.unwrapSecure(outer),
                  let checkpoint = secure.checkpoint else { return false }
            let isCompleteSnapshot = checkpoint.snapshotFragment.map {
                $0.index + 1 == $0.count
            } ?? true
            return isCompleteSnapshot
                && checkpoint.groupEpoch == snapshot.signedState.epoch
                && checkpoint.groupTranscriptHash
                    == snapshot.signedState.confirmedTranscriptHash
        }) {
            return false
        }
        let previous = try NoctCordSecureProjectionV2.projectForOwnerRebind(
            verified: snapshot
        )
        let configuration = try previous.projection.checkpointConfiguration(
            createdAt: Date()
        )
        let publication = try await publishVerifiedSnapshotSeries(
            spaceID: spaceID,
            configuration: configuration,
            rotateVoiceRoutes: true,
            at: Date()
        )
        guard publication.complete else {
            throw NoctCordTransportError.transportIncomplete
        }
        return true
        #else
        let events = Self.acceptedBootstrapHistory(
            spaceID: spaceID,
            owner: snapshot.localCredential.memberHandle,
            activeMembers: Set(snapshot.signedState.members.filter {
                $0.isActive(at: snapshot.signedState.epoch)
            }.map(\.id)),
            events: snapshot.events.compactMap { try? NoctCordCodec.unwrap($0) }
        )
        let fulfilled = Set(events.flatMap {
            $0.operation.kind == .bootstrapApplied
                ? ($0.operation.bootstrapRequestIDs ?? [])
                : []
        })
        let pending = events
            .filter { $0.operation.kind == .bootstrapRequested && !fulfilled.contains($0.id) }
            .map(\.id)
            .sorted { $0.uuidString < $1.uuidString }
        guard !pending.isEmpty else { return false }

        let batches = try Self.bootstrapBatches(
            from: events,
            spaceID: spaceID,
            owner: snapshot.localCredential.memberHandle,
            createdAt: Date()
        )
        guard !batches.isEmpty else {
            throw NoctCordTransportError.eventRejected
        }
        let coveredRequests = Array(pending.prefix(128))
        for (index, batch) in batches.enumerated() {
            let publication = try await publishOperation(
                spaceID: spaceID,
                operation: .applyBootstrap(
                    batch,
                    satisfying: index == batches.indices.last ? coveredRequests : []
                )
            )
            guard publication.complete else {
                throw NoctCordTransportError.transportIncomplete
            }
        }
        return true
        #endif
    }

    @discardableResult
    public func publish(
        _ event: NoctCordEvent,
        at date: Date? = nil
    ) async throws -> NoctCordTransportPublication {
        guard event.isStructurallyValid else {
            throw NoctCordTransportError.eventRejected
        }
        let runtime = try await client.openGroupRuntime(groupID: event.spaceID)
        let snapshot = await runtime.snapshot()
        guard snapshot.localCredential.memberHandle == event.author else {
            throw NoctCordTransportError.eventRejected
        }
        #if NOCTCORD_VERIFIED_CORE
        guard !event.operation.kind.isBootstrapConfiguration,
              event.operation.kind != .bootstrapApplied else {
            throw NoctCordTransportError.eventRejected
        }
        let verified = try NoctCordSecureProjectionV2.project(verified: snapshot)
        var authorizationProjection = verified.projection
        do {
            try authorizationProjection.applyVerifiedV2(
                event, permittingHistoricalAuthor: false
            )
        } catch {
            throw NoctCordTransportError.eventRejected
        }
        let groupEvent = try NoctCordCodec.wrapSecure(
            NoctCordSecureEventV2(
                event: event,
                credential: snapshot.localCredential.credentialHandle
            ),
            usingLegacyCapability: Self.requiresLegacyContentCapability(snapshot)
        )
        #else
        let decodedEvents = snapshot.events.compactMap { try? NoctCordCodec.unwrap($0) }
        let activeMembers = Set(
            snapshot.signedState.members
                .filter { $0.isActive(at: snapshot.signedState.epoch) }
                .map(\.id)
        )
        guard let owner = snapshot.signedState.members.first(where: {
            $0.role == .owner && $0.isActive(at: snapshot.signedState.epoch)
        })?.id else {
            throw NoctCordTransportError.eventRejected
        }
        var authorizationProjection = NoctCordSpaceProjection.project(
            spaceID: event.spaceID,
            owner: owner,
            activeMembers: activeMembers,
            historicalMembers: Set(decodedEvents.map(\.author)),
            events: decodedEvents
        ).projection
        do {
            try authorizationProjection.apply(event)
        } catch {
            throw NoctCordTransportError.eventRejected
        }
        let groupEvent = try NoctCordCodec.wrap(
            event,
            credential: snapshot.localCredential.credentialHandle
        )
        #endif
        let prepared = try await client.prepareGroupApplication(
            groupEvent,
            at: date ?? event.createdAt
        )
        guard let operation = prepared.transportOperation else {
            return NoctCordTransportPublication(
                event: event,
                operationID: nil,
                complete: true
            )
        }
        let resumed = try await client.resumeGroupTransport(
            groupID: event.spaceID,
            operationID: operation.id,
            at: date ?? event.createdAt
        )
        return NoctCordTransportPublication(
            event: event,
            operationID: operation.id,
            complete: resumed.complete
        )
    }

    public func synchronize(spaceID: UUID) async throws -> [NoctCordEvent] {
        guard await storedSpaceIDs().contains(spaceID) else {
            throw NoctCordTransportError.spaceNotFound
        }
        let pages = try await client.syncGroup(groupID: spaceID)
        #if NOCTCORD_VERIFIED_CORE
        let runtime = try await client.openGroupRuntime(groupID: spaceID)
        let beforePin = await runtime.snapshot()
        try await pinReceivedCheckpoints(beforePin.events, runtime: runtime)
        let snapshot = await runtime.snapshot()
        guard snapshot.protectedApplicationEventIDs.contains(where: { id in
            snapshot.events.contains {
                $0.id == id && NoctCordCodec.isSecureContent($0.content)
            }
        }) else { return [] }
        return try NoctCordSecureProjectionV2.project(verified: snapshot)
            .acceptedEvents.sorted(by: Self.canonicalEventOrder)
        #else
        return pages
            .flatMap(\.receivedEvents)
            .compactMap { try? NoctCordCodec.unwrap($0) }
            .sorted(by: NoctCordTransportCoordinator.canonicalEventOrder)
        #endif
    }

    public func allStoredEvents(spaceID: UUID) async throws -> [NoctCordEvent] {
        let runtime = try await client.openGroupRuntime(groupID: spaceID)
        let snapshot = await runtime.snapshot()
        #if NOCTCORD_VERIFIED_CORE
        return try NoctCordSecureProjectionV2.project(verified: snapshot)
            .acceptedEvents.sorted(by: Self.canonicalEventOrder)
        #else
        return snapshot.events
            .compactMap { try? NoctCordCodec.unwrap($0) }
            .sorted(by: NoctCordTransportCoordinator.canonicalEventOrder)
        #endif
    }

    /// Returns an owner-authored *proposal* based on bounded v1 history. The
    /// caller must show its effective channels, roles, ACLs, bots, and voice
    /// rooms for explicit owner approval; it is never silently promoted into
    /// v2 authority.
    public func proposedLegacyConfigurationForReview(
        spaceID: UUID,
        at date: Date = Date()
    ) async throws -> [NoctCordEvent] {
        let runtime = try await client.openGroupRuntime(groupID: spaceID)
        let snapshot = await runtime.snapshot()
        guard let owner = snapshot.signedState.members.first(where: {
            $0.role == .owner && $0.isActive(at: snapshot.signedState.epoch)
        })?.id,
        owner == snapshot.localCredential.memberHandle else {
            throw NoctCordTransportError.communityOwnerRequired
        }
        #if NOCTCORD_VERIFIED_CORE
        if let pending = snapshot.pendingApplicationPublications.first(where: {
            guard let secure = try? NoctCordCodec.unwrapSecure($0.event),
                  let checkpoint = secure.checkpoint else { return false }
            return checkpoint.kind == .snapshot
                && checkpoint.previousCheckpointDigest == nil
        }), let secure = try? NoctCordCodec.unwrapSecure(pending.event),
           secure.checkpoint?.snapshotFragment == nil,
           let signedConfiguration = secure.event.operation.bootstrapEvents {
            // A pending signed genesis is the exact artifact awaiting owner
            // confirmation/retry, including its original nested event IDs.
            return signedConfiguration
        }
        #endif
        let legacy = snapshot.events.compactMap { try? NoctCordCodec.unwrap($0) }
        let projection = NoctCordSpaceProjection.project(
            spaceID: spaceID,
            owner: owner,
            activeMembers: Set(snapshot.signedState.activeCredentials.map(\.memberHandle)),
            historicalMembers: Set(legacy.map(\.author)),
            events: legacy
        ).projection
        return try projection.checkpointConfiguration(createdAt: date)
    }

    /// Promotes only the exact owner-reviewed configuration into the verified
    /// policy protocol. A legacy Core record must cross into a fresh signed
    /// group epoch first; old v1 events remain display-only history.
    public func migrateCommunityToVerifiedPolicy(
        spaceID: UUID,
        approvedConfiguration: [NoctCordEvent],
        at date: Date = Date()
    ) async throws -> NoctCordTransportPublication {
        #if NOCTCORD_VERIFIED_CORE
        _ = try await client.maintainGroup(groupID: spaceID, at: date)
        let runtime = try await client.openGroupRuntime(groupID: spaceID)
        var snapshot = await runtime.snapshot()
        let pendingEpochs = snapshot.outboundTransportOperations.filter {
            $0.kind == .epoch && !$0.isComplete
        }
        for transport in pendingEpochs {
            guard snapshot.epochIntents.contains(where: {
                $0.id == transport.logicalID
                    && $0.signedCommit.operation == .updateMetadata
            }) else {
                throw NoctCordTransportError.transportIncomplete
            }
            let resumed = try await client.resumeGroupTransport(
                groupID: spaceID, operationID: transport.id, at: date
            )
            guard resumed.complete else {
                throw NoctCordTransportError.transportIncomplete
            }
        }
        if !pendingEpochs.isEmpty {
            snapshot = await (try await client.openGroupRuntime(groupID: spaceID)).snapshot()
        }
        let incompleteSeries = try Self.incompleteSnapshotFragment(in: snapshot)
        let interruptedOldGenesis = Self.hasInterruptedOldEpochGenesis(in: snapshot)
        guard let owner = snapshot.signedState.members.first(where: {
            $0.role == .owner && $0.isActive(at: snapshot.signedState.epoch)
        })?.id,
        owner == snapshot.localCredential.memberHandle,
        !approvedConfiguration.isEmpty,
        approvedConfiguration.allSatisfy({
            $0.spaceID == spaceID && $0.author == owner
                && $0.operation.kind.isBootstrapConfiguration
        }),
        (incompleteSeries != nil || interruptedOldGenesis
            || !snapshot.protectedApplicationEventIDs.contains(where: { id in
            snapshot.events.contains {
                $0.id == id && NoctCordCodec.isSecureContent($0.content)
            }
        })) else {
            throw NoctCordTransportError.communityOwnerRequired
        }
        if let pending = snapshot.pendingApplicationPublications.first(where: {
            guard let secure = try? NoctCordCodec.unwrapSecure($0.event),
                  let checkpoint = secure.checkpoint else { return false }
            return checkpoint.kind == .snapshot
                && checkpoint.previousCheckpointDigest == nil
        }), let secure = try? NoctCordCodec.unwrapSecure(pending.event),
           secure.checkpoint?.snapshotFragment == nil {
            guard secure.event.operation.bootstrapEvents == approvedConfiguration else {
                throw NoctCordTransportError.transportIncomplete
            }
            return try await publishVerifiedCheckpoint(
                spaceID: spaceID,
                operation: secure.event.operation,
                kind: .snapshot,
                snapshotFragment: secure.checkpoint?.snapshotFragment,
                at: date
            )
        }
        var reviewed = NoctCordSpaceProjection(
            spaceID: spaceID, owner: owner,
            activeMembers: Set(snapshot.signedState.activeCredentials.map(\.memberHandle))
        )
        do { try reviewed.applyVerifiedConfigurationSnapshot(approvedConfiguration) }
        catch { throw NoctCordTransportError.eventRejected }
        _ = try Self.plannedSnapshotChunks(
            approvedConfiguration, snapshot: snapshot
        )

        if snapshot.currentVerificationFrontiers() == nil {
            let configurationDigest = Data(SHA256.hash(data:
                try NoctweaveCoder.encode(approvedConfiguration, sortedKeys: true)
            ))
            var material = Data("NoctCord/verified-policy-migration/v2\0".utf8)
            material.append(Data(spaceID.uuidString.utf8))
            material.append(snapshot.signedState.digest ?? Data())
            material.append(configurationDigest)
            let metadataDigest = Data(SHA256.hash(data: material))
            let idempotencyKey = Data(SHA256.hash(data:
                Data("NoctCord/migration-epoch-idempotency/v2\0".utf8)
                    + material
            ))
            let prepared = try await client.prepareGroupEpoch(
                groupID: spaceID,
                operation: .updateMetadata,
                proposedMembers: snapshot.signedState.members,
                proposedCredentials: snapshot.signedState.memberCredentials,
                proposedPermissions: snapshot.signedState.permissions,
                proposedMetadataDigest: metadataDigest,
                idempotencyKey: idempotencyKey,
                createdAt: date
            )
            if let transport = prepared.transportOperation {
                let resumed = try await client.resumeGroupTransport(
                    groupID: spaceID, operationID: transport.id, at: date
                )
                guard resumed.complete else {
                    throw NoctCordTransportError.transportIncomplete
                }
            }
            snapshot = await (try await client.openGroupRuntime(groupID: spaceID)).snapshot()
            guard snapshot.currentVerificationFrontiers() != nil else {
                throw NoctCordTransportError.eventRejected
            }
        }
        return try await publishVerifiedSnapshotSeries(
            spaceID: spaceID,
            configuration: approvedConfiguration,
            at: date.addingTimeInterval(1)
        )
        #else
        throw NoctCordTransportError.unsupportedEvent
        #endif
    }

    /// Gives upgraded members a fresh Core-verifiable policy root in the same
    /// community. Old clients may have consumed earlier schema-2 traffic
    /// without v6 receipts; they remain read-only until this owner epoch and
    /// linked snapshot arrive after their upgrade.
    @discardableResult
    public func rebindVerifiedCommunityAfterUpgrade(
        spaceID: UUID,
        at date: Date = Date()
    ) async throws -> Bool {
        #if NOCTCORD_VERIFIED_CORE
        _ = try await client.maintainGroup(groupID: spaceID, at: date)
        let runtime = try await client.openGroupRuntime(groupID: spaceID)
        var snapshot = await runtime.snapshot()
        guard let owner = snapshot.signedState.members.first(where: {
            $0.role == .owner && $0.isActive(at: snapshot.signedState.epoch)
        })?.id,
        owner == snapshot.localCredential.memberHandle,
        try Self.latestCheckpointDigest(in: snapshot) != nil else {
            throw NoctCordTransportError.communityOwnerRequired
        }
        _ = try NoctCordSecureProjectionV2.projectForOwnerRebind(
            verified: snapshot
        )
        if try Self.incompleteSnapshotFragment(in: snapshot) != nil
            || snapshot.pendingApplicationPublications.contains(where: {
                guard let secure = try? NoctCordCodec.unwrapSecure($0.event),
                      let checkpoint = secure.checkpoint else { return false }
                return checkpoint.groupEpoch == snapshot.signedState.epoch
                    && checkpoint.snapshotFragment != nil
            }) {
            // A member can force a later epoch by leaving, so complete any
            // owner series already in this epoch before choosing another
            // epoch. The continuation is exact and Core-bound.
            guard try await ensureCommunityBootstrap(spaceID: spaceID) else {
                throw NoctCordTransportError.transportIncomplete
            }
            snapshot = await (try await client.openGroupRuntime(
                groupID: spaceID
            )).snapshot()
        }
        let pending = snapshot.outboundTransportOperations.filter {
            $0.kind == .epoch && !$0.isComplete
        }
        if !pending.isEmpty {
            for transport in pending {
                guard snapshot.epochIntents.contains(where: {
                    $0.id == transport.logicalID
                        && $0.signedCommit.operation == .updateMetadata
                }) else {
                    throw NoctCordTransportError.transportIncomplete
                }
                let resumed = try await client.resumeGroupTransport(
                    groupID: spaceID, operationID: transport.id, at: date
                )
                guard resumed.complete else {
                    throw NoctCordTransportError.transportIncomplete
                }
            }
            snapshot = await (try await client.openGroupRuntime(groupID: spaceID)).snapshot()
        } else if (try Self.latestCheckpointEpoch(in: snapshot))
                    == snapshot.signedState.epoch {
            guard let stateDigest = snapshot.signedState.digest else {
                throw NoctCordTransportError.eventRejected
            }
            var material = Data("NoctCord/upgrade-rebind-epoch/v2\0".utf8)
            material.append(Data(spaceID.uuidString.utf8))
            material.append(stateDigest)
            let prepared = try await client.prepareGroupEpoch(
                groupID: spaceID,
                operation: .updateMetadata,
                proposedMembers: snapshot.signedState.members,
                proposedCredentials: snapshot.signedState.memberCredentials,
                proposedPermissions: snapshot.signedState.permissions,
                proposedMetadataDigest: Data(SHA256.hash(data: material)),
                idempotencyKey: Data(SHA256.hash(data:
                    Data("NoctCord/upgrade-rebind-idempotency/v2\0".utf8)
                        + material
                )),
                createdAt: date
            )
            if let transport = prepared.transportOperation {
                let resumed = try await client.resumeGroupTransport(
                    groupID: spaceID, operationID: transport.id, at: date
                )
                guard resumed.complete else {
                    throw NoctCordTransportError.transportIncomplete
                }
            }
        }
        return try await ensureCommunityBootstrap(spaceID: spaceID)
        #else
        throw NoctCordTransportError.unsupportedEvent
        #endif
    }

    @discardableResult
    public func publishOperation(
        spaceID: UUID,
        operation: NoctCordOperation,
        at date: Date = Date()
    ) async throws -> NoctCordTransportPublication {
        #if NOCTCORD_VERIFIED_CORE
        if operation.kind.isBootstrapConfiguration {
            return try await publishVerifiedCheckpoint(
                spaceID: spaceID, operation: operation,
                kind: .delta, at: date
            )
        }
        guard operation.kind != .bootstrapApplied else {
            throw NoctCordTransportError.eventRejected
        }
        #endif
        let runtime = try await client.openGroupRuntime(groupID: spaceID)
        let snapshot = await runtime.snapshot()
        #if NOCTCORD_VERIFIED_CORE
        let projection = try NoctCordSecureProjectionV2.project(verified: snapshot).projection
        #else
        let existing = snapshot.events.compactMap { try? NoctCordCodec.unwrap($0) }
        guard let owner = snapshot.signedState.members.first(where: {
            $0.role == .owner && $0.isActive(at: snapshot.signedState.epoch)
        })?.id else {
            throw NoctCordTransportError.eventRejected
        }
        let projection = NoctCordSpaceProjection.project(
            spaceID: spaceID,
            owner: owner,
            activeMembers: Set(snapshot.signedState.members.filter {
                $0.isActive(at: snapshot.signedState.epoch)
            }.map(\.id)),
            historicalMembers: Set(existing.map(\.author)),
            events: existing
        ).projection
        #endif
        let event = NoctCordEvent(
            spaceID: spaceID,
            author: snapshot.localCredential.memberHandle,
            logicalClock: try projection.nextLogicalClock(),
            createdAt: date,
            operation: operation
        )
        return try await publish(event, at: date)
    }

    public func storedSpaceSnapshot(
        spaceID: UUID,
        assessRelay: Bool = true
    ) async throws -> NoctCordStoredSpaceSnapshot {
        let runtime = try await client.openGroupRuntime(groupID: spaceID)
        var snapshot = await runtime.snapshot()
        #if NOCTCORD_VERIFIED_CORE
        try await pinReceivedCheckpoints(snapshot.events, runtime: runtime)
        snapshot = await runtime.snapshot()
        #endif
        let local = snapshot.localCredential.memberHandle
        let members = snapshot.signedState.members
            .filter { $0.isActive(at: snapshot.signedState.epoch) }
            .map { member in
                NoctCordTransportMember(
                    handle: member.id,
                    roleName: member.role.rawValue.capitalized,
                    isCurrentMember: member.id == local
                )
            }
            .sorted { lhs, rhs in
                if lhs.isCurrentMember != rhs.isCurrentMember { return lhs.isCurrentMember }
                return lhs.handle.rawValue.lexicographicallyPrecedes(rhs.handle.rawValue)
            }
        guard let owner = snapshot.signedState.members.first(where: {
            $0.role == .owner && $0.isActive(at: snapshot.signedState.epoch)
        })?.id else {
            throw NoctCordTransportError.eventRejected
        }
        let communityRelay = try Self.relayEndpoint(from: snapshot)
        let preference = await relayPreference(for: communityRelay)
        #if NOCTCORD_VERIFIED_CORE
        let legacyArchive = Self.legacyArchiveBeforeVerifiedCutoff(snapshot)
            .sorted(by: Self.canonicalEventOrder)
        let hasSecureTraffic = snapshot.events.contains {
            NoctCordCodec.isSecureContent($0.content)
        }
        let hasProtectedCheckpoint = snapshot.protectedApplicationEventIDs.contains { id in
            snapshot.events.contains {
                $0.id == id && NoctCordCodec.isSecureContent($0.content)
            }
        }
        let policyMode: NoctCordPolicyMode
        let verifiedProjection: NoctCordProjectionResult?
        if hasProtectedCheckpoint {
            policyMode = .verified
            verifiedProjection = try NoctCordSecureProjectionV2.project(verified: snapshot)
        } else if hasSecureTraffic {
            policyMode = .awaitingOwnerCheckpoint
            verifiedProjection = nil
        } else if snapshot.applicationVerificationLegacyThroughEpoch > 0
                    || !legacyArchive.isEmpty {
            policyMode = .legacyReadOnly
            verifiedProjection = nil
        } else {
            policyMode = .awaitingOwnerCheckpoint
            verifiedProjection = nil
        }
        let projectedEvents = verifiedProjection?.acceptedEvents ?? []
        #else
        let legacyArchive: [NoctCordEvent] = []
        let policyMode: NoctCordPolicyMode = .legacyWritable
        let verifiedProjection: NoctCordProjectionResult? = nil
        let projectedEvents = snapshot.events
            .compactMap { try? NoctCordCodec.unwrap($0) }
            .sorted(by: Self.canonicalEventOrder)
        #endif
        return NoctCordStoredSpaceSnapshot(
            spaceID: spaceID,
            groupEpoch: snapshot.signedState.epoch,
            owner: owner,
            currentMember: local,
            members: members,
            events: projectedEvents,
            policyMode: policyMode,
            verifiedProjection: verifiedProjection,
            legacyArchiveEvents: legacyArchive,
            relay: communityRelay,
            relayName: preference?.name ?? communityRelay.host,
            relayAssessment: assessRelay
                ? await relayAssessment(for: communityRelay)
                : Self.offlineRelayAssessment()
        )
    }

    /// Removes the local member through a signed group epoch transition. The
    /// terminal runtime remains encrypted on this device so stale epochs and
    /// replayed application traffic continue to fail closed.
    @discardableResult
    public func leaveCommunity(
        spaceID: UUID,
        createdAt: Date = Date()
    ) async throws -> NoctCordCommunityLifecycleResult {
        guard createdAt.timeIntervalSince1970.isFinite else {
            throw NoctCordTransportError.invalidConfiguration
        }
        let runtime = try await client.openGroupRuntime(groupID: spaceID)
        let snapshot = await runtime.snapshot()
        guard snapshot.localRemoval == nil, snapshot.deletionState == nil else {
            throw NoctCordTransportError.communityTerminal
        }
        let epoch = snapshot.signedState.epoch
        let localHandle = snapshot.localCredential.memberHandle
        guard let localMember = snapshot.signedState.members.first(where: {
            $0.id == localHandle && $0.isActive(at: epoch)
        }) else {
            throw NoctCordTransportError.communityTerminal
        }
        guard localMember.role != .owner else {
            throw NoctCordTransportError.ownerCannotLeave
        }
        let (nextEpoch, overflow) = epoch.addingReportingOverflow(1)
        guard !overflow, let stateDigest = snapshot.signedState.digest else {
            throw NoctCordTransportError.eventRejected
        }
        let proposedMembers = snapshot.signedState.members.map { member in
            member.id == localHandle
                ? GroupMemberV2(
                    id: member.id,
                    role: member.role,
                    addedEpoch: member.addedEpoch,
                    removedEpoch: nextEpoch
                )
                : member
        }
        let proposedCredentials = snapshot.signedState.memberCredentials.map { credential in
            credential.memberHandle == localHandle && credential.isActive(at: epoch)
                ? GroupMemberCredentialV2(
                    memberHandle: credential.memberHandle,
                    credentialHandle: credential.credentialHandle,
                    admissionDigest: credential.admissionDigest,
                    signingPublicKey: credential.signingPublicKey,
                    agreementPublicKey: credential.agreementPublicKey,
                    contentTypes: credential.contentTypes,
                    addedEpoch: credential.addedEpoch,
                    removedEpoch: nextEpoch
                )
                : credential
        }
        let idempotencyKey = Self.communityLifecycleIdempotencyKey(
            action: .leave,
            spaceID: spaceID,
            epoch: epoch,
            stateDigest: stateDigest,
            memberHandle: localHandle
        )
        let prepared = try await client.prepareGroupEpoch(
            groupID: spaceID,
            operation: .removeMember,
            proposedMembers: proposedMembers,
            proposedCredentials: proposedCredentials,
            proposedPermissions: snapshot.signedState.permissions,
            proposedMetadataDigest: snapshot.signedState.metadataDigest,
            idempotencyKey: idempotencyKey,
            createdAt: createdAt
        )
        var complete = prepared.complete
        if let operation = prepared.transportOperation {
            complete = try await client.resumeGroupTransport(
                groupID: spaceID,
                operationID: operation.id,
                at: createdAt
            ).complete
        }
        guard complete else {
            throw NoctCordTransportError.transportIncomplete
        }
        let finalizedRuntime = try await client.openGroupRuntime(groupID: spaceID)
        guard await finalizedRuntime.snapshot().localRemoval != nil else {
            throw NoctCordTransportError.eventRejected
        }
        await discardRealtimeSubscriptions(for: spaceID)
        return NoctCordCommunityLifecycleResult(
            spaceID: spaceID,
            action: .leave,
            operationID: prepared.transportOperation?.id,
            complete: true
        )
    }

    /// Publishes the owner's signed terminal tombstone to every currently
    /// active remote credential. Relay-retained ciphertext is governed by the
    /// operator's retention policy; the group itself cannot be resurrected.
    @discardableResult
    public func destroyCommunity(
        spaceID: UUID,
        createdAt: Date = Date()
    ) async throws -> NoctCordCommunityLifecycleResult {
        guard createdAt.timeIntervalSince1970.isFinite else {
            throw NoctCordTransportError.invalidConfiguration
        }
        let runtime = try await client.openGroupRuntime(groupID: spaceID)
        let snapshot = await runtime.snapshot()
        guard snapshot.localRemoval == nil else {
            throw NoctCordTransportError.communityTerminal
        }
        if let deletion = snapshot.deletionState,
           deletion.origin != .local || deletion.publicationState != .pending {
            throw NoctCordTransportError.communityTerminal
        }
        let epoch = snapshot.signedState.epoch
        let localHandle = snapshot.localCredential.memberHandle
        guard let localMember = snapshot.signedState.members.first(where: {
            $0.id == localHandle && $0.isActive(at: epoch)
        }), localMember.role == .owner else {
            throw NoctCordTransportError.communityOwnerRequired
        }
        guard let stateDigest = snapshot.signedState.digest else {
            throw NoctCordTransportError.eventRejected
        }
        let idempotencyKey = Self.communityLifecycleIdempotencyKey(
            action: .destroy,
            spaceID: spaceID,
            epoch: epoch,
            stateDigest: stateDigest,
            memberHandle: localHandle
        )
        let prepared = try await client.prepareGroupDeletion(
            groupID: spaceID,
            idempotencyKey: idempotencyKey,
            createdAt: createdAt
        )
        var complete = prepared.complete
        if let operation = prepared.transportOperation {
            complete = try await client.resumeGroupTransport(
                groupID: spaceID,
                operationID: operation.id,
                at: createdAt
            ).complete
        }
        guard complete else {
            throw NoctCordTransportError.transportIncomplete
        }
        let finalizedRuntime = try await client.openGroupRuntime(groupID: spaceID)
        guard await finalizedRuntime.snapshot().deletionState?.publicationState == .published else {
            throw NoctCordTransportError.eventRejected
        }
        await discardRealtimeSubscriptions(for: spaceID)
        return NoctCordCommunityLifecycleResult(
            spaceID: spaceID,
            action: .destroy,
            operationID: prepared.transportOperation?.id,
            complete: true
        )
    }

    public func maintain(spaceID: UUID) async throws {
        _ = try await client.maintainGroup(groupID: spaceID)
    }

    public func relayEndpoint() -> RelayEndpoint { relay }

    public func relayEndpoint(for spaceID: UUID) async throws -> RelayEndpoint {
        let runtime = try await client.openGroupRuntime(groupID: spaceID)
        return try Self.relayEndpoint(from: await runtime.snapshot())
    }

    public func testRelay(timeout: TimeInterval = 5) async throws {
        let response = try await RelayClient(
            endpoint: relay,
            authToken: relayAccessPassword
        ).send(.health(), timeout: timeout)
        guard response.status == .success, response.error == nil else {
            throw NoctCordTransportError.transportIncomplete
        }
    }

    /// Resolves the relay's optional ICE service and acquires a fresh coturn
    /// credential when required. The returned credential is session state;
    /// callers must not persist it with community or identity data.
    public func discoverCallConnectivity(
        timeout: TimeInterval = 5
    ) async throws -> NoctCordRelayICEConfiguration {
        try await discoverCallConnectivity(endpoint: relay, timeout: timeout)
    }

    public func discoverCallConnectivity(
        for spaceID: UUID,
        timeout: TimeInterval = 5
    ) async throws -> NoctCordRelayICEConfiguration {
        let endpoint = try await relayEndpoint(for: spaceID)
        return try await discoverCallConnectivity(
            endpoint: endpoint,
            timeout: timeout
        )
    }

    private func discoverCallConnectivity(
        endpoint: RelayEndpoint,
        timeout: TimeInterval
    ) async throws -> NoctCordRelayICEConfiguration {
        let client = await relayClient(for: endpoint)
        let infoResponse = try await client.send(.info(), timeout: timeout)
        guard infoResponse.error == nil,
              case .relayInfo(let info)? = infoResponse.successBody else {
            throw NoctCordTransportError.transportIncomplete
        }
        guard let descriptor = info.iceService else {
            return NoctCordRelayICEConfiguration(
                servers: [],
                relayAdvertised: false,
                relayOnlySupported: false,
                credentialExpiresAt: nil
            )
        }
        guard descriptor.isStructurallyValid,
              info.protocolCapabilities?.supports(
                module: "nw.ice-service",
                version: 1
              ) == true else {
            throw NoctCordTransportError.transportIncomplete
        }

        let stunURLs = descriptor.urls.filter {
            $0.hasPrefix("stun:") || $0.hasPrefix("stuns:")
        }
        var servers: [NoctCordMediaICEServer] = []
        if !stunURLs.isEmpty {
            servers.append(try NoctCordMediaICEServer(urls: stunURLs))
        }

        switch descriptor.credentialMode {
        case .none:
            let turnURLs = descriptor.urls.filter {
                $0.hasPrefix("turn:") || $0.hasPrefix("turns:")
            }
            if !turnURLs.isEmpty {
                servers.append(try NoctCordMediaICEServer(urls: turnURLs))
            }
            return NoctCordRelayICEConfiguration(
                servers: servers,
                relayAdvertised: true,
                relayOnlySupported: descriptor.relayOnlySupported,
                credentialExpiresAt: nil
            )
        case .turnREST:
            let credentialResponse = try await client.send(
                .acquireICECredentialsV1(.fresh()),
                timeout: timeout
            )
            guard credentialResponse.error == nil,
                  case .iceCredentials(let credentials)? = credentialResponse.successBody,
                  credentials.isStructurallyValid,
                  credentials.expiresAt > Date() else {
                throw NoctCordTransportError.transportIncomplete
            }
            servers.append(try NoctCordMediaICEServer(
                urls: credentials.urls,
                username: credentials.username,
                credential: credentials.credential
            ))
            return NoctCordRelayICEConfiguration(
                servers: servers,
                relayAdvertised: true,
                relayOnlySupported: descriptor.relayOnlySupported,
                credentialExpiresAt: credentials.expiresAt
            )
        }
    }

    public func attachmentTransfer() -> NoctCordAttachmentTransfer {
        NoctCordAttachmentTransfer(
            relay: relay,
            accessPassword: relayAccessPassword
        )
    }

    public func attachmentTransfer(
        for spaceID: UUID
    ) async throws -> NoctCordAttachmentTransfer {
        let endpoint = try await relayEndpoint(for: spaceID)
        return NoctCordAttachmentTransfer(
            relay: endpoint,
            accessPassword: await resolvedAccessPassword(for: endpoint)
        )
    }

    public func createRealtimeRoute(
        lifetime: TimeInterval = 23 * 60 * 60,
        now: Date = Date()
    ) async throws -> NoctCordRealtimeRouteV1 {
        try await createRealtimeRoute(
            endpoint: relay,
            lifetime: lifetime,
            now: now
        )
    }

    public func createRealtimeRoute(
        for spaceID: UUID,
        lifetime: TimeInterval = 23 * 60 * 60,
        now: Date = Date()
    ) async throws -> NoctCordRealtimeRouteV1 {
        let endpoint = try await relayEndpoint(for: spaceID)
        return try await createRealtimeRoute(
            endpoint: endpoint,
            lifetime: lifetime,
            now: now
        )
    }

    private func createRealtimeRoute(
        endpoint: RelayEndpoint,
        lifetime: TimeInterval,
        now: Date
    ) async throws -> NoctCordRealtimeRouteV1 {
        guard lifetime.isFinite, lifetime >= 60, lifetime <= 24 * 60 * 60 else {
            throw NoctCordTransportError.invalidConfiguration
        }
        let request = RealtimeRouteCreateRequestV1(
            routeCapability: OpaqueCapabilityV1.generate(),
            appendCapability: OpaqueCapabilityV1.generate(),
            readCapability: OpaqueCapabilityV1.generate(),
            expiresAt: now.addingTimeInterval(lifetime)
        )
        return try await createRealtimeRoute(endpoint: endpoint, request: request)
    }

    private func createRealtimeRoute(
        endpoint: RelayEndpoint,
        request: RealtimeRouteCreateRequestV1
    ) async throws -> NoctCordRealtimeRouteV1 {
        guard request.isStructurallyValid else {
            throw NoctCordTransportError.invalidConfiguration
        }
        let response = try await relayClient(for: endpoint)
            .send(.createRealtimeRouteV1(request))
        guard response.error == nil,
              case .realtimeRouteCreated(let created)? = response.successBody,
              created.routeCapability == request.routeCapability,
              created.appendCapability == request.appendCapability,
              created.readCapability == request.readCapability else {
            throw NoctCordTransportError.transportIncomplete
        }
        return NoctCordRealtimeRouteV1(
            routeCapability: created.routeCapability,
            appendCapability: created.appendCapability,
            readCapability: created.readCapability,
            expiresAt: created.expiresAt
        )
    }

    private func createRotatedRoutes(
        for spaceID: UUID,
        requests: [RealtimeRouteCreateRequestV1]
    ) async throws {
        guard !requests.isEmpty else { return }
        let endpoint = try await relayEndpoint(for: spaceID)
        for request in requests {
            // After a long offline retry, the owner must still finish the
            // already signed policy transition. An expired route grants no
            // calling capability; the normal owner voice-room renewal delta
            // can mint a fresh route after the policy series is complete.
            if request.expiresAt <= Date() { continue }
            _ = try await createRealtimeRoute(
                endpoint: endpoint, request: request
            )
        }
    }

    public func publishRealtimeCallSignal(
        spaceID: UUID,
        roomID: UUID,
        signal: NoctCordEncryptedCallSignalV1,
        at date: Date = Date()
    ) async throws {
        let runtime = try await client.openGroupRuntime(groupID: spaceID)
        let snapshot = await runtime.snapshot()
        let projection = try Self.projectedSpace(from: snapshot)
        guard let room = projection.voiceRooms[roomID], !room.isArchived,
              projection.permissions(for: snapshot.localCredential.memberHandle).contains(.connectVoice),
              projection.voiceParticipants[roomID]?[snapshot.localCredential.memberHandle]?.isJoined == true,
              signal.callID == roomID,
              signal.keyID == room.signalingKeyID,
              room.realtimeRoute.expiresAt > date else {
            throw NoctCordTransportError.eventRejected
        }
        let body = NoctCordRealtimeSignedSignalBodyV1(
            spaceID: spaceID,
            roomID: roomID,
            author: snapshot.localCredential.memberHandle,
            credential: snapshot.localCredential.credentialHandle,
            signal: signal,
            createdAt: date
        )
        let envelope = NoctCordRealtimeSignedSignalEnvelopeV1(
            body: body,
            signature: try snapshot.localCredential.signingKey.sign(
                try NoctCordRealtimeSignalWire.signedBytes(body)
            )
        )
        let payload = try NoctCordRealtimeSignalWire.seal(
            envelope,
            room: room,
            spaceID: spaceID
        )
        let append = RealtimeRouteAppendRequestV1(
            routeCapability: room.realtimeRoute.routeCapability,
            appendCapability: room.realtimeRoute.appendCapability,
            recordID: signal.signalID,
            payload: payload
        )
        let response = try await relayClient(for: spaceID)
            .send(.appendRealtimeRouteV1(append))
        guard response.error == nil,
              case .realtimeRouteAppend(let receipt)? = response.successBody,
              receipt.recordID == signal.signalID else {
            throw NoctCordTransportError.transportIncomplete
        }

        // SDP and ICE remain on the bounded, expiring realtime route. Writing
        // every negotiation record into permanent group history would grow
        // state and force a full post-quantum fanout for latency-sensitive
        // traffic. Durable room membership and share state still use group
        // events; ephemeral negotiation does not.
    }

    public func synchronizeRealtimeCallSignals(
        spaceID: UUID,
        roomID: UUID,
        now: Date = Date()
    ) async throws -> [NoctCordReceivedRealtimeSignal] {
        let runtime = try await client.openGroupRuntime(groupID: spaceID)
        var snapshot = await runtime.snapshot()
        var projection = try Self.projectedSpace(from: snapshot)
        guard let room = projection.voiceRooms[roomID], !room.isArchived else {
            throw NoctCordTransportError.spaceNotFound
        }
        guard room.realtimeRoute.expiresAt > now else {
            throw NoctCordTransportError.transportIncomplete
        }
        let communityRelayClient = try await relayClient(for: spaceID)
        var subscription = try await realtimeSubscription(
            spaceID: spaceID,
            room: room,
            now: now,
            relayClient: communityRelayClient
        )
        var received: [NoctCordReceivedRealtimeSignal] = []
        var refreshedMembership = false
        for _ in 0..<4 {
            let response = try await communityRelayClient.send(.syncRealtimeRouteV1(
                RealtimeRouteSyncRequestV1(
                    routeCapability: room.realtimeRoute.routeCapability,
                    subscriptionCapability: subscription.subscriptionCapability,
                    afterSequence: subscription.cursor,
                    maxRecords: 128
                )
            ))
            guard response.error == nil,
                  case .realtimeRouteSync(let batch)? = response.successBody else {
                throw NoctCordTransportError.transportIncomplete
            }
            for record in batch.records {
                guard let opened = try? NoctCordRealtimeSignalWire.open(
                    record.payload,
                    room: room,
                    spaceID: spaceID
                ) else { continue }
                if !Self.authorizeRealtimeEnvelope(opened, state: snapshot.signedState, projection: projection),
                   !refreshedMembership {
                    // A valid room join can arrive on the realtime route before
                    // this peer has synchronized its durable membership event.
                    // Refresh once, then fail closed; a signed group credential
                    // alone does not authorize entering a voice room.
                    _ = try await synchronize(spaceID: spaceID)
                    let refreshedRuntime = try await client.openGroupRuntime(groupID: spaceID)
                    snapshot = await refreshedRuntime.snapshot()
                    projection = try Self.projectedSpace(from: snapshot)
                    refreshedMembership = true
                }
                guard Self.authorizeRealtimeEnvelope(opened, state: snapshot.signedState, projection: projection) else {
                    continue
                }
                received.append(NoctCordReceivedRealtimeSignal(
                    author: opened.body.author,
                    signal: opened.body.signal
                ))
            }
            subscription.cursor = batch.nextSequence
            realtimeSubscriptions[roomID] = subscription
            if !batch.hasMore { break }
        }
        return received
    }

    public func closeRealtimeRoom(roomID: UUID) async {
        await closeRealtimeRoom(roomID: roomID, relayClient: relayClient())
    }

    public func closeRealtimeRoom(spaceID: UUID, roomID: UUID) async {
        guard let client = try? await relayClient(for: spaceID) else { return }
        await closeRealtimeRoom(roomID: roomID, relayClient: client)
    }

    private func closeRealtimeRoom(
        roomID: UUID,
        relayClient: RelayClient
    ) async {
        guard let subscription = realtimeSubscriptions.removeValue(forKey: roomID) else {
            return
        }
        _ = try? await relayClient.send(.unsubscribeRealtimeRouteV1(
            RealtimeRouteUnsubscribeRequestV1(
                routeCapability: subscription.routeCapability,
                subscriptionCapability: subscription.subscriptionCapability
            )
        ))
    }

    public func relayAssessment() async -> NoctCordRelayAssessment {
        await relayAssessment(for: relay)
    }

    public func relayAssessment(
        for endpoint: RelayEndpoint
    ) async -> NoctCordRelayAssessment {
        guard let response = try? await relayClient(for: endpoint).send(.info()),
              case .relayInfo(let info)? = response.successBody else {
            return Self.offlineRelayAssessment()
        }
        return NoctCordRelaySupport.assess(info)
    }

    public func underlyingClient() -> HeadlessMessagingClient { client }

    private func relayClient() -> RelayClient {
        RelayClient(endpoint: relay, authToken: relayAccessPassword)
    }

    private func relayClient(for spaceID: UUID) async throws -> RelayClient {
        let endpoint = try await relayEndpoint(for: spaceID)
        return await relayClient(for: endpoint)
    }

    private func relayClient(for endpoint: RelayEndpoint) async -> RelayClient {
        return RelayClient(
            endpoint: endpoint,
            authToken: await resolvedAccessPassword(for: endpoint)
        )
    }

    private func resolvedAccessPassword(for endpoint: RelayEndpoint) async -> String? {
        await relayPreference(for: endpoint)?.accessPassword
            ?? (endpoint == relay ? relayAccessPassword : nil)
    }

    private func relayPreference(
        for endpoint: RelayEndpoint
    ) async -> LocalRelayPreference? {
        await client.snapshot().relayPreferences.first { $0.endpoint == endpoint }
    }

    private func relayEndpoint(
        forPreferenceID preferenceID: UUID?
    ) async throws -> RelayEndpoint {
        guard let preferenceID else { return relay }
        guard let preference = await client.snapshot().relayPreferences.first(where: {
            $0.id == preferenceID
        }) else {
            throw NoctCordTransportError.invalidConfiguration
        }
        return preference.endpoint
    }

    private func ensureRelayPreference(
        endpoint: RelayEndpoint,
        name: String
    ) async throws {
        if await relayPreference(for: endpoint) != nil { return }
        try await client.upsertRelayPreference(
            endpoint: endpoint,
            name: name,
            accessPassword: nil
        )
    }

    private static func profile(
        from preference: LocalRelayPreference
    ) -> NoctCordRelayProfile {
        NoctCordRelayProfile(
            id: preference.id,
            name: preference.name,
            endpoint: preference.endpoint,
            hasAccessPassword: preference.accessPassword?.isEmpty == false
        )
    }

    private static func offlineRelayAssessment() -> NoctCordRelayAssessment {
        NoctCordRelaySupport.assess(
            RelayCapabilityManifestV2.advertised(
                attachmentsEnabled: false,
                wakeEnabled: false,
                hiddenRetrievalEnabled: false,
                onionEnabled: false,
                mixnetEnabled: false
            ),
            temporalBucketSeconds: 0
        )
    }

    private static func relayEndpoint(
        from snapshot: GroupRuntimeRecord
    ) throws -> RelayEndpoint {
        if let active = snapshot.inboundTransport.localRoutes.first(where: {
            $0.advertisedState == .active
        }) {
            return active.localRoute.relay
        }
        if let retained = snapshot.inboundTransport.localRoutes.first {
            return retained.localRoute.relay
        }
        if let pending = snapshot.inboundTransport.pendingRoute {
            return pending.relay
        }
        throw NoctCordTransportError.spaceNotFound
    }

    private func realtimeSubscription(
        spaceID: UUID,
        room: NoctCordCore.NoctCordVoiceRoom,
        now: Date,
        relayClient: RelayClient
    ) async throws -> NoctCordRealtimeSubscriptionState {
        if let existing = realtimeSubscriptions[room.id],
           existing.routeCapability == room.realtimeRoute.routeCapability,
           existing.expiresAt > now {
            return existing
        }
        if let obsolete = realtimeSubscriptions.removeValue(forKey: room.id) {
            _ = try? await relayClient.send(.unsubscribeRealtimeRouteV1(
                RealtimeRouteUnsubscribeRequestV1(
                    routeCapability: obsolete.routeCapability,
                    subscriptionCapability: obsolete.subscriptionCapability
                )
            ))
        }
        let response = try await relayClient.send(.subscribeRealtimeRouteV1(
            RealtimeRouteSubscribeRequestV1(
                routeCapability: room.realtimeRoute.routeCapability,
                readCapability: room.realtimeRoute.readCapability
            )
        ))
        guard response.error == nil,
              case .realtimeRouteSubscription(let created)? = response.successBody,
              created.routeCapability == room.realtimeRoute.routeCapability else {
            throw NoctCordTransportError.transportIncomplete
        }
        let state = NoctCordRealtimeSubscriptionState(
            spaceID: spaceID,
            routeCapability: created.routeCapability,
            subscriptionCapability: created.subscriptionCapability,
            cursor: created.nextSequence,
            expiresAt: created.expiresAt
        )
        realtimeSubscriptions[room.id] = state
        return state
    }

    private func discardRealtimeSubscriptions(for spaceID: UUID) async {
        let roomIDs = realtimeSubscriptions.compactMap { roomID, state in
            state.spaceID == spaceID ? roomID : nil
        }
        guard !roomIDs.isEmpty else { return }
        let relayClient = try? await relayClient(for: spaceID)
        for roomID in roomIDs {
            guard let state = realtimeSubscriptions.removeValue(forKey: roomID) else {
                continue
            }
            if let relayClient {
                _ = try? await relayClient.send(.unsubscribeRealtimeRouteV1(
                    RealtimeRouteUnsubscribeRequestV1(
                        routeCapability: state.routeCapability,
                        subscriptionCapability: state.subscriptionCapability
                    )
                ))
            }
        }
    }

    private static func communityLifecycleIdempotencyKey(
        action: NoctCordCommunityLifecycleAction,
        spaceID: UUID,
        epoch: UInt64,
        stateDigest: Data,
        memberHandle: GroupScopedMemberHandleV2
    ) -> Data {
        var material = Data("org.noctcord/community-lifecycle/v1\0".utf8)
        material.append(Data(action.rawValue.utf8))
        material.append(0)
        material.append(Data(spaceID.uuidString.lowercased().utf8))
        material.append(0)
        material.append(Data(String(epoch).utf8))
        material.append(0)
        material.append(stateDigest)
        material.append(Data(memberHandle.rawValue.utf8))
        return Data(SHA256.hash(data: material))
    }

    #if NOCTCORD_VERIFIED_CORE
    private static func legacyArchiveBeforeVerifiedCutoff(
        _ snapshot: GroupRuntimeRecord
    ) -> [NoctCordEvent] {
        let genesis = snapshot.protectedApplicationEventIDs.compactMap { id
            -> NoctCordPolicyCheckpointV2? in
            guard let outer = snapshot.events.first(where: { $0.id == id }),
                  let secure = try? NoctCordCodec.unwrapSecure(outer),
                  let checkpoint = secure.checkpoint,
                  checkpoint.previousCheckpointDigest == nil else { return nil }
            return checkpoint
        }.first
        let hasProtectedSecureRoot = snapshot.protectedApplicationEventIDs.contains { id in
            snapshot.events.contains {
                $0.id == id && NoctCordCodec.isSecureContent($0.content)
            }
        }
        return snapshot.events.compactMap { outer in
            guard outer.content.type == NoctCordCodec.contentType,
                  !NoctCordCodec.isSecureContent(outer.content),
                  let event = try? NoctCordCodec.unwrap(outer),
                  event.operation.kind != .bootstrapRequested else {
                return nil
            }
            guard let genesis else {
                if !hasProtectedSecureRoot { return event }
                return snapshot.applicationVerificationReceipt(for: outer.id) == nil
                    && snapshot.applicationVerificationLegacyThroughEpoch > 0
                    ? event : nil
            }
            if let receipt = snapshot.applicationVerificationReceipt(for: outer.id) {
                if receipt.epoch < genesis.groupEpoch { return event }
                guard receipt.epoch == genesis.groupEpoch,
                      let frontier = genesis.frontiers.first(where: {
                          $0.epoch == receipt.epoch
                              && $0.credential == receipt.credentialHandle
                      }),
                      receipt.messageCounter < frontier.nextCounter else {
                    return nil
                }
                return event
            }
            // A v5-migrated record has no Core receipts for historical v1
            // events. Once v2 starts, every newly consumed envelope has a
            // receipt, so absence can denote only old local archive data.
            return snapshot.applicationVerificationLegacyThroughEpoch > 0
                ? event : nil
        }
    }

    /// Computes the complete bounded series before an epoch transition. Size
    /// checks include the outer Core event and a worst-case 64-part fragment
    /// header, so a later part cannot unexpectedly exceed Core's padded limit.
    static func plannedSnapshotChunks(
        _ configuration: [NoctCordEvent],
        snapshot: GroupRuntimeRecord,
        extraCredential: GroupScopedCredentialHandleV2? = nil
    ) throws -> [[NoctCordEvent]] {
        guard !configuration.isEmpty,
              configuration.count <= NoctCordSnapshotFragmentV2.maximumParts * 128,
              configuration.allSatisfy({
                  $0.spaceID == snapshot.groupId
                      && $0.author == snapshot.localCredential.memberHandle
                      && $0.operation.kind.isBootstrapConfiguration
                      && $0.isStructurallyValid
              }) else {
            throw NoctCordTransportError.invalidConfiguration
        }
        var handles = Set(snapshot.signedState.activeCredentials.map(\.credentialHandle))
        if let extraCredential { handles.insert(extraCredential) }
        guard !handles.isEmpty,
              handles.count <= NoctCordPolicyCheckpointV2.maximumFrontiers else {
            throw NoctCordTransportError.invalidConfiguration
        }
        let dummyHash = Data(repeating: 0, count: SHA256.byteCount)
        let frontiers = handles.map {
            NoctCordCredentialFrontierV2(
                epoch: NoctCordEvent.maximumLogicalClock,
                transcriptHash: dummyHash,
                credential: $0,
                nextCounter: NoctCordEvent.maximumLogicalClock,
                prefixDigest: dummyHash
            )
        }.sorted(by: NoctCordPolicyCheckpointV2.frontierOrder)
        func fits(_ chunk: [NoctCordEvent], fragmented: Bool) -> Bool {
            guard !chunk.isEmpty, chunk.count <= 128,
                  let bytes = try? NoctweaveCoder.encode(chunk, sortedKeys: true) else {
                return false
            }
            let event = NoctCordEvent(
                spaceID: snapshot.groupId,
                author: snapshot.localCredential.memberHandle,
                logicalClock: NoctCordEvent.maximumLogicalClock,
                createdAt: Date(timeIntervalSince1970: 4_000_000_000),
                operation: .applyBootstrap(chunk)
            )
            let checkpoint = NoctCordPolicyCheckpointV2(
                spaceID: snapshot.groupId,
                owner: snapshot.localCredential.memberHandle,
                groupEpoch: NoctCordEvent.maximumLogicalClock,
                groupTranscriptHash: dummyHash,
                previousCheckpointDigest: dummyHash,
                configurationDigest: Data(SHA256.hash(data: bytes)),
                frontiers: frontiers,
                snapshotFragment: fragmented
                    ? NoctCordSnapshotFragmentV2(
                        seriesID: UUID(), index: 63, count: 64,
                        fullConfigurationDigest: dummyHash,
                        seriesSeed: dummyHash
                    ) : nil
            )
            let secure = NoctCordSecureEventV2(
                event: event,
                credential: snapshot.localCredential.credentialHandle,
                checkpoint: checkpoint
            )
            guard secure.isStructurallyValid,
                  let outer = try? NoctCordCodec.wrapSecure(
                      secure, usingLegacyCapability: true
                  ),
                  let outerBytes = try? NoctweaveCoder.encode(outer, sortedKeys: true)
            else { return false }
            return outerBytes.count <= NoctCordCodec.maximumEventBytes - 1_024
        }
        if fits(configuration, fragmented: false) { return [configuration] }
        var chunks: [[NoctCordEvent]] = []
        var offset = 0
        while offset < configuration.count {
            var lower = 1
            var upper = min(128, configuration.count - offset)
            var best = 0
            while lower <= upper {
                let candidate = lower + (upper - lower) / 2
                let chunk = Array(configuration[offset..<(offset + candidate)])
                if fits(chunk, fragmented: true) {
                    best = candidate
                    lower = candidate + 1
                } else {
                    upper = candidate - 1
                }
            }
            guard best > 0 else { throw NoctCordTransportError.invalidConfiguration }
            chunks.append(Array(configuration[offset..<(offset + best)]))
            guard chunks.count <= NoctCordSnapshotFragmentV2.maximumParts else {
                throw NoctCordTransportError.invalidConfiguration
            }
            offset += best
        }
        return chunks
    }

    package static func rotateVoiceRoutesForEpochRebind(
        _ configuration: [NoctCordEvent],
        spaceID: UUID,
        epoch: UInt64,
        seed: Data,
        at date: Date
    ) throws -> (events: [NoctCordEvent], routes: [RealtimeRouteCreateRequestV1]) {
        guard seed.count == SHA256.byteCount else {
            throw NoctCordTransportError.invalidConfiguration
        }
        var result: [NoctCordEvent] = []
        var routes: [RealtimeRouteCreateRequestV1] = []
        result.reserveCapacity(configuration.count)
        let seedKey = SymmetricKey(data: seed)
        func derived(_ label: String, roomID: UUID) -> Data {
            var info = Data("NoctCord/epoch-voice-credential/v2\0".utf8)
            info.append(Data(spaceID.uuidString.lowercased().utf8))
            var networkEpoch = epoch.bigEndian
            withUnsafeBytes(of: &networkEpoch) { info.append(contentsOf: $0) }
            info.append(Data(roomID.uuidString.lowercased().utf8))
            info.append(0)
            info.append(Data(label.utf8))
            let key = HKDF<SHA256>.deriveKey(
                inputKeyMaterial: seedKey,
                salt: Data("NoctCord/epoch-voice-rotation/v2".utf8),
                info: info,
                outputByteCount: SHA256.byteCount
            )
            return key.withUnsafeBytes { Data($0) }
        }
        for event in configuration {
            guard event.operation.kind == .voiceRoomCreated,
                  let roomID = event.operation.voiceRoomID,
                  let spec = event.operation.voiceRoomSpec else {
                result.append(event)
                continue
            }
            let request = RealtimeRouteCreateRequestV1(
                routeCapability: derived("route", roomID: roomID),
                appendCapability: derived("append", roomID: roomID),
                readCapability: derived("read", roomID: roomID),
                expiresAt: date.addingTimeInterval(23 * 60 * 60)
            )
            guard request.isStructurallyValid else {
                throw NoctCordTransportError.invalidConfiguration
            }
            routes.append(request)
            result.append(NoctCordEvent(
                id: event.id,
                spaceID: event.spaceID,
                author: event.author,
                logicalClock: event.logicalClock,
                createdAt: event.createdAt,
                operation: .createVoiceRoom(
                    id: roomID,
                    spec: NoctCordVoiceRoomSpecV1(
                        name: spec.name,
                        maxParticipants: spec.maxParticipants,
                        signalingKey: derived("signal", roomID: roomID),
                        realtimeRoute: NoctCordRealtimeRouteV1(
                            routeCapability: request.routeCapability,
                            appendCapability: request.appendCapability,
                            readCapability: request.readCapability,
                            expiresAt: request.expiresAt
                        )
                    )
                )
            ))
        }
        return (result, routes)
    }

    private func publishVerifiedJoinControlRequest(
        spaceID: UUID,
        at date: Date
    ) async throws {
        let runtime = try await client.openGroupRuntime(groupID: spaceID)
        let snapshot = await runtime.snapshot()
        guard snapshot.originJoinAnchorID != nil,
              !snapshot.protectedApplicationEventIDs.contains(where: { id in
                  snapshot.events.contains {
                      $0.id == id && NoctCordCodec.isSecureContent($0.content)
                  }
              }) else {
            throw NoctCordTransportError.eventRejected
        }
        let event = NoctCordEvent(
            spaceID: spaceID,
            author: snapshot.localCredential.memberHandle,
            logicalClock: 1,
            createdAt: date,
            operation: .requestBootstrap()
        )
        let outer = try NoctCordCodec.wrap(
            event, credential: snapshot.localCredential.credentialHandle
        )
        let prepared = try await client.prepareGroupApplication(outer, at: date)
        if let transport = prepared.transportOperation {
            let resumed = try await client.resumeGroupTransport(
                groupID: spaceID, operationID: transport.id, at: date
            )
            guard resumed.complete else {
                throw NoctCordTransportError.transportIncomplete
            }
        }
    }

    private static func requiresLegacyContentCapability(
        _ snapshot: GroupRuntimeRecord
    ) -> Bool {
        !snapshot.signedState.activeCredentials.allSatisfy { credential in
            credential.contentTypes.contains {
                $0.supports(NoctCordCodec.secureContentType)
            }
        }
    }

    private static func latestCheckpointDigest(
        in snapshot: GroupRuntimeRecord
    ) throws -> Data? {
        let checkpoints = try snapshot.protectedApplicationEventIDs.compactMap { id
            -> (digest: Data, previous: Data?)? in
            guard let outer = snapshot.events.first(where: { $0.id == id }),
                  NoctCordCodec.isSecureContent(outer.content) else { return nil }
            let secure = try NoctCordCodec.unwrapSecure(outer)
            guard let checkpoint = secure.checkpoint else {
                throw NoctCordTransportError.eventRejected
            }
            return (try secure.canonicalDigest(), checkpoint.previousCheckpointDigest)
        }
        guard !checkpoints.isEmpty else { return nil }
        let predecessors = Set(checkpoints.compactMap(\.previous))
        let tails = checkpoints.filter { !predecessors.contains($0.digest) }
        guard tails.count == 1 else { throw NoctCordTransportError.eventRejected }
        return tails[0].digest
    }

    private static func latestCheckpointEpoch(
        in snapshot: GroupRuntimeRecord
    ) throws -> UInt64? {
        let checkpoints = try snapshot.protectedApplicationEventIDs.compactMap { id
            -> (digest: Data, previous: Data?, epoch: UInt64)? in
            guard let outer = snapshot.events.first(where: { $0.id == id }),
                  NoctCordCodec.isSecureContent(outer.content) else { return nil }
            let secure = try NoctCordCodec.unwrapSecure(outer)
            guard let checkpoint = secure.checkpoint else {
                throw NoctCordTransportError.eventRejected
            }
            return (try secure.canonicalDigest(), checkpoint.previousCheckpointDigest,
                    checkpoint.groupEpoch)
        }
        guard !checkpoints.isEmpty else { return nil }
        let predecessors = Set(checkpoints.compactMap(\.previous))
        let tails = checkpoints.filter { !predecessors.contains($0.digest) }
        guard tails.count == 1 else { throw NoctCordTransportError.eventRejected }
        return tails[0].epoch
    }

    private static func incompleteSnapshotFragment(
        in snapshot: GroupRuntimeRecord,
        currentEpochOnly: Bool = true
    ) throws -> NoctCordSnapshotFragmentV2? {
        guard let digest = try latestCheckpointDigest(in: snapshot) else { return nil }
        for id in snapshot.protectedApplicationEventIDs {
            guard let outer = snapshot.events.first(where: { $0.id == id }),
                  NoctCordCodec.isSecureContent(outer.content),
                  let secure = try? NoctCordCodec.unwrapSecure(outer),
                  (try? secure.canonicalDigest()) == digest,
                  let checkpoint = secure.checkpoint,
                  (!currentEpochOnly
                    || checkpoint.groupEpoch == snapshot.signedState.epoch),
                  let fragment = checkpoint.snapshotFragment else {
                continue
            }
            return fragment.index + 1 < fragment.count ? fragment : nil
        }
        return nil
    }

    /// An owner-reviewed v1 genesis can be interrupted by another member's
    /// signed epoch transition. The partial old-epoch proposal never became
    /// policy; the owner may explicitly review a fresh proposal and link a
    /// new current-epoch snapshot to that inert authenticated prefix.
    private static func hasInterruptedOldEpochGenesis(
        in snapshot: GroupRuntimeRecord
    ) -> Bool {
        let protected = Set(snapshot.protectedApplicationEventIDs)
        let checkpoints = snapshot.events.compactMap { outer
            -> (policy: NoctCordPolicyCheckpointV2, digest: Data)? in
            guard protected.contains(outer.id),
                  let secure = try? NoctCordCodec.unwrapSecure(outer),
                  let checkpoint = secure.checkpoint,
                  let digest = try? secure.canonicalDigest() else {
                return nil
            }
            return (checkpoint, digest)
        }
        guard let first = checkpoints.first,
              let fragment = first.policy.snapshotFragment,
              first.policy.previousCheckpointDigest == nil,
              first.policy.groupEpoch < snapshot.signedState.epoch,
              checkpoints.count < fragment.count else { return false }
        return checkpoints.enumerated().allSatisfy { index, entry in
            let checkpoint = entry.policy
            let expectedPrevious = index == 0 ? nil : checkpoints[index - 1].digest
            return checkpoint.kind == .snapshot
                && checkpoint.previousCheckpointDigest == expectedPrevious
                && checkpoint.groupEpoch == first.policy.groupEpoch
                && checkpoint.groupTranscriptHash
                    == first.policy.groupTranscriptHash
                && checkpoint.snapshotFragment?.seriesID == fragment.seriesID
                && checkpoint.snapshotFragment?.index == index
                && checkpoint.snapshotFragment?.count == fragment.count
                && checkpoint.snapshotFragment?.seriesSeed == fragment.seriesSeed
                && checkpoint.snapshotFragment?.fullConfigurationDigest
                    == fragment.fullConfigurationDigest
        }
    }

    /// Keep every checkpoint needed by retained content. A later complete
    /// full snapshot may become the local root only when replay from that
    /// root preserves all currently authorized ordinary events and the exact
    /// visible state. Core atomically records tombstones for the retired
    /// checkpoint IDs so their retained ciphertext cannot be reinterpreted.
    private func retireObsoleteCheckpointPrefix(
        runtime: NoctweavePQGroupRuntimeV2,
        allowStaleOwnerEpoch: Bool = false
    ) async throws {
        let snapshot = await runtime.snapshot()
        let full = try allowStaleOwnerEpoch
            ? NoctCordSecureProjectionV2.projectForOwnerRebind(verified: snapshot)
            : NoctCordSecureProjectionV2.project(verified: snapshot)
        let protected = Set(snapshot.protectedApplicationEventIDs)
        let checkpoints = snapshot.events.filter { outer in
            protected.contains(outer.id)
                && NoctCordCodec.isSecureContent(outer.content)
                && (try? NoctCordCodec.unwrapSecure(outer).checkpoint) != nil
        }
        guard checkpoints.count > 1 else { return }
        let ordinaryIDs = Set(snapshot.events.compactMap { outer -> UUID? in
            guard let secure = try? NoctCordCodec.unwrapSecure(outer),
                  secure.checkpoint == nil else { return nil }
            return outer.id
        })
        let acceptedOrdinary = Set(full.acceptedEvents.map(\.id))
            .intersection(ordinaryIDs)
        for index in stride(from: checkpoints.count - 1, through: 1, by: -1) {
            let root = checkpoints[index]
            guard let secure = try? NoctCordCodec.unwrapSecure(root),
                  let policy = secure.checkpoint,
                  policy.kind == .snapshot,
                  (policy.snapshotFragment == nil
                    || policy.snapshotFragment?.index == 0) else { continue }
            let retiring = Set(checkpoints[..<index].map(\.id))
            guard let candidate = try? NoctCordSecureProjectionV2
                .projectAfterRetiring(
                    retiring, verified: snapshot,
                    allowStaleOwnerEpoch: allowStaleOwnerEpoch
                ),
                candidate.projection.hasSameRetainedState(as: full.projection),
                Set(candidate.acceptedEvents.map(\.id))
                    .intersection(ordinaryIDs) == acceptedOrdinary,
                let bound = snapshot.protectedVerificationFrontiers(for: root.id) else {
                continue
            }
            try await runtime.replaceProtectedApplicationEventSeries(
                retiring: Array(retiring),
                with: [GroupProtectedApplicationVerificationBindingV2(
                    eventID: root.id,
                    frontiers: bound
                )]
            )
            return
        }
    }

    private func publishVerifiedSnapshotSeries(
        spaceID: UUID,
        configuration: [NoctCordEvent],
        rotateVoiceRoutes: Bool = false,
        at date: Date
    ) async throws -> NoctCordTransportPublication {
        let runtime = try await client.openGroupRuntime(groupID: spaceID)
        let beforeRetirement = await runtime.snapshot()
        if (try? Self.latestCheckpointDigest(in: beforeRetirement)) != nil,
           (try? Self.incompleteSnapshotFragment(
               in: beforeRetirement, currentEpochOnly: false
           )) == nil,
           !beforeRetirement.pendingApplicationPublications.contains(where: {
               (try? NoctCordCodec.unwrapSecure($0.event).checkpoint) != nil
           }) {
            // Old content may have aged out since the last policy change.
            // Free only a prefix whose removal preserves all *retained*
            // authorized content before reserving pins for a new series.
            try await retireObsoleteCheckpointPrefix(
                runtime: runtime, allowStaleOwnerEpoch: true
            )
        }
        let snapshot = await runtime.snapshot()
        let pending = snapshot.pendingApplicationPublications.compactMap {
            try? NoctCordCodec.unwrapSecure($0.event)
        }.first {
            $0.checkpoint?.snapshotFragment != nil
                && $0.checkpoint?.groupEpoch == snapshot.signedState.epoch
        }
        let incomplete = try Self.incompleteSnapshotFragment(in: snapshot)
        let existing = pending?.checkpoint?.snapshotFragment ?? incomplete
        let seriesID = existing?.seriesID ?? UUID()
        let seed = existing?.seriesSeed
            ?? SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
        let firstExisting = snapshot.events.compactMap {
            try? NoctCordCodec.unwrapSecure($0)
        }.first {
            $0.checkpoint?.snapshotFragment?.seriesID == seriesID
                && $0.checkpoint?.snapshotFragment?.index == 0
        }
        let baseDate = firstExisting?.event.createdAt ?? date
        let rotated = rotateVoiceRoutes
            ? try Self.rotateVoiceRoutesForEpochRebind(
                configuration, spaceID: spaceID,
                epoch: snapshot.signedState.epoch,
                seed: seed, at: baseDate
            )
            : (events: configuration, routes: [RealtimeRouteCreateRequestV1]())
        let effectiveConfiguration = rotated.events
        var chunks = try Self.plannedSnapshotChunks(
            effectiveConfiguration, snapshot: snapshot
        )
        if rotateVoiceRoutes && !rotated.routes.isEmpty && chunks.count == 1 {
            guard effectiveConfiguration.count >= 2 else {
                throw NoctCordTransportError.invalidConfiguration
            }
            let split = effectiveConfiguration.count / 2
            chunks = [Array(effectiveConfiguration[..<split]),
                      Array(effectiveConfiguration[split...])]
        }
        if chunks.count == 1 {
            let published = try await publishVerifiedCheckpoint(
                spaceID: spaceID,
                operation: .applyBootstrap(chunks[0]),
                kind: .snapshot,
                at: date
            )
            if published.complete {
                try await retireObsoleteCheckpointPrefix(
                    runtime: try await client.openGroupRuntime(groupID: spaceID)
                )
            }
            return published
        }
        let fullDigest = try NoctCordSnapshotFragmentV2.fullDigest(
            of: effectiveConfiguration
        )
        if let existing {
            guard existing.count == chunks.count,
                  existing.fullConfigurationDigest == fullDigest,
                  pending == nil || incomplete == nil
                    || existing.index == incomplete!.index + 1 else {
                throw NoctCordTransportError.snapshotProposalMismatch
            }
        }
        let firstIndex = pending?.checkpoint?.snapshotFragment?.index
            ?? incomplete.map { $0.index + 1 } ?? 0
        guard snapshot.protectedApplicationEventIDs.count
                + (chunks.count - firstIndex)
                <= GroupRuntimeRecord.maximumProtectedApplicationEvents else {
            throw NoctCordTransportError.checkpointCapacityReached
        }
        var last: NoctCordTransportPublication?
        if firstIndex > 0 {
            // Fragment zero already durably records the seed and base date.
            // The exact relay requests are idempotent across a crash/reopen.
            try await createRotatedRoutes(
                for: spaceID, requests: rotated.routes
            )
        }
        for index in firstIndex..<chunks.count {
            let fragment = NoctCordSnapshotFragmentV2(
                seriesID: seriesID,
                index: index,
                count: chunks.count,
                fullConfigurationDigest: fullDigest,
                seriesSeed: seed
            )
            let publication = try await publishVerifiedCheckpoint(
                spaceID: spaceID,
                operation: .applyBootstrap(chunks[index]),
                kind: .snapshot,
                snapshotFragment: fragment,
                beforeFanoutRoutes: index == 0 ? rotated.routes : [],
                at: date.addingTimeInterval(TimeInterval(index))
            )
            last = publication
            if !publication.complete { return publication }
        }
        guard let last else { throw NoctCordTransportError.eventRejected }
        try await retireObsoleteCheckpointPrefix(
            runtime: try await client.openGroupRuntime(groupID: spaceID)
        )
        return last
    }

    private func publishVerifiedCheckpoint(
        spaceID: UUID,
        operation: NoctCordOperation,
        kind: NoctCordPolicyCheckpointKindV2,
        snapshotFragment: NoctCordSnapshotFragmentV2? = nil,
        beforeFanoutRoutes: [RealtimeRouteCreateRequestV1] = [],
        at date: Date
    ) async throws -> NoctCordTransportPublication {
        let runtime = try await client.openGroupRuntime(groupID: spaceID)
        var snapshot = await runtime.snapshot()
        try await pinReceivedCheckpoints(snapshot.events, runtime: runtime)
        snapshot = await runtime.snapshot()
        guard let owner = snapshot.signedState.members.first(where: {
            $0.role == .owner && $0.isActive(at: snapshot.signedState.epoch)
        })?.id,
        snapshot.localCredential.memberHandle == owner else {
            throw NoctCordTransportError.eventRejected
        }

        for stalePending in snapshot.pendingApplicationPublications {
            guard let secure = try? NoctCordCodec.unwrapSecure(stalePending.event),
                  let checkpoint = secure.checkpoint,
                  checkpoint.groupEpoch < snapshot.signedState.epoch else {
                continue
            }
            var transport = snapshot.outboundTransportOperations.first {
                $0.logicalID == stalePending.event.id
            }
            if transport == nil {
                transport = try await client.prepareGroupApplication(
                    stalePending.event, at: max(date, stalePending.event.createdAt)
                ).transportOperation
            }
            if let transport {
                let resumed = try await client.resumeGroupTransport(
                    groupID: spaceID, operationID: transport.id, at: date
                )
                guard resumed.complete else {
                    throw NoctCordTransportError.transportIncomplete
                }
            }
            let recovered = try await client.openGroupRuntime(groupID: spaceID)
            try await recovered.replaceProtectedApplicationEvent(
                previousEventID: nil,
                with: stalePending.event.id,
                verificationFrontiers: checkpoint.frontiers.map {
                    $0.coreFrontier(groupID: spaceID)
                }
            )
            snapshot = await recovered.snapshot()
        }

        // A failed or interrupted fanout must resume the exact signed event.
        // Publishing a new checkpoint here could split the owner chain.
        if let pending = snapshot.pendingApplicationPublications.first(where: {
            (try? NoctCordCodec.unwrapSecure($0.event).checkpoint) != nil
        }) {
            guard let secure = try? NoctCordCodec.unwrapSecure(pending.event),
                  secure.event.operation == operation,
                  secure.checkpoint?.kind == kind,
                  secure.checkpoint?.snapshotFragment == snapshotFragment else {
                throw NoctCordTransportError.transportIncomplete
            }
            var transport = snapshot.outboundTransportOperations.first(where: {
                $0.logicalID == pending.event.id
            })
            if transport == nil {
                // Core can persist the sender ratchet and exact envelope just
                // before preparing the transport journal. Retrying the same
                // event materializes that journal without signing a fork.
                let recovered = try await client.prepareGroupApplication(
                    pending.event, at: max(date, pending.event.createdAt)
                )
                transport = recovered.transportOperation
            }
            try await createRotatedRoutes(
                for: spaceID, requests: beforeFanoutRoutes
            )
            if let transport {
                let resumed = try await client.resumeGroupTransport(
                    groupID: spaceID, operationID: transport.id, at: date
                )
                guard resumed.complete else {
                    return NoctCordTransportPublication(
                        event: secure.event,
                        operationID: transport.id,
                        complete: false
                    )
                }
            }
            let resumedRuntime = try await client.openGroupRuntime(groupID: spaceID)
            try await resumedRuntime.replaceProtectedApplicationEvent(
                previousEventID: nil,
                with: pending.event.id,
                verificationFrontiers: secure.checkpoint!.frontiers.map {
                    $0.coreFrontier(groupID: spaceID)
                }
            )
            return NoctCordTransportPublication(
                event: secure.event,
                operationID: transport?.id,
                complete: true
            )
        }

        if kind == .delta,
           snapshot.protectedApplicationEventIDs.count
                >= GroupRuntimeRecord.maximumProtectedApplicationEvents
                    - NoctCordSnapshotFragmentV2.maximumParts {
            let current = try NoctCordSecureProjectionV2.project(
                verified: snapshot
            ).projection
            let configuration = try current.checkpointConfiguration(
                createdAt: date
            )
            let refresh = try await publishVerifiedSnapshotSeries(
                spaceID: spaceID, configuration: configuration, at: date
            )
            guard refresh.complete else {
                throw NoctCordTransportError.transportIncomplete
            }
            snapshot = await (try await client.openGroupRuntime(
                groupID: spaceID
            )).snapshot()
            guard snapshot.protectedApplicationEventIDs.count
                    < GroupRuntimeRecord.maximumProtectedApplicationEvents
                        - NoctCordSnapshotFragmentV2.maximumParts else {
                throw NoctCordTransportError.checkpointCapacityReached
            }
        }
        guard snapshot.protectedApplicationEventIDs.count
                < GroupRuntimeRecord.maximumProtectedApplicationEvents else {
            throw NoctCordTransportError.checkpointCapacityReached
        }

        let previousDigest = try Self.latestCheckpointDigest(in: snapshot)
        if let incomplete = try Self.incompleteSnapshotFragment(in: snapshot) {
            guard let snapshotFragment,
                  snapshotFragment.seriesID == incomplete.seriesID,
                  snapshotFragment.index == incomplete.index + 1,
                  snapshotFragment.count == incomplete.count,
                  snapshotFragment.seriesSeed == incomplete.seriesSeed,
                  snapshotFragment.fullConfigurationDigest
                    == incomplete.fullConfigurationDigest else {
                throw NoctCordTransportError.transportIncomplete
            }
        } else if let snapshotFragment, snapshotFragment.index != 0 {
            throw NoctCordTransportError.eventRejected
        }
        switch kind {
        case .snapshot:
            guard operation.kind == .bootstrapApplied,
                  !operation.bootstrapEvents!.isEmpty else {
                throw NoctCordTransportError.eventRejected
            }
        case .delta:
            guard previousDigest != nil,
                  operation.kind.isBootstrapConfiguration
                    || (previousDigest != nil
                        && operation.kind == .bootstrapRequested) else {
                throw NoctCordTransportError.eventRejected
            }
        }
        if previousDigest != nil && snapshotFragment == nil {
            _ = try NoctCordSecureProjectionV2.projectForOwnerRebind(
                verified: snapshot
            )
        }
        guard let coreFrontiers = snapshot.currentVerificationFrontiers(),
              coreFrontiers.count == snapshot.signedState.activeCredentials.count else {
            throw NoctCordTransportError.eventRejected
        }
        let appFrontiers = coreFrontiers.map(NoctCordCredentialFrontierV2.init)
        let configurationBytes: Data
        if kind == .snapshot {
            configurationBytes = try NoctweaveCoder.encode(
                operation.bootstrapEvents!, sortedKeys: true
            )
        } else {
            configurationBytes = try NoctweaveCoder.encode(operation, sortedKeys: true)
        }
        let projection: NoctCordSpaceProjection
        if previousDigest == nil || kind == .snapshot {
            projection = NoctCordSpaceProjection(
                spaceID: spaceID, owner: owner,
                activeMembers: Set(snapshot.signedState.activeCredentials.map(\.memberHandle))
            )
        } else {
            projection = try NoctCordSecureProjectionV2.project(
                verified: snapshot
            ).projection
        }
        let event = NoctCordEvent(
            spaceID: spaceID,
            author: owner,
            logicalClock: try projection.nextLogicalClock(),
            createdAt: date,
            operation: operation
        )
        var candidate = projection
        if snapshotFragment == nil {
            do {
                try candidate.applyVerifiedV2(
                    event, permittingHistoricalAuthor: false
                )
                let fullConfiguration = try candidate.checkpointConfiguration(
                    createdAt: date
                )
                _ = try Self.plannedSnapshotChunks(
                    fullConfiguration, snapshot: snapshot
                )
            } catch {
                throw NoctCordTransportError.eventRejected
            }
        }
        let secure = NoctCordSecureEventV2(
            event: event,
            credential: snapshot.localCredential.credentialHandle,
            checkpoint: NoctCordPolicyCheckpointV2(
                spaceID: spaceID,
                owner: owner,
                kind: kind,
                groupEpoch: snapshot.signedState.epoch,
                groupTranscriptHash: snapshot.signedState.confirmedTranscriptHash,
                previousCheckpointDigest: previousDigest,
                configurationDigest: Data(SHA256.hash(data: configurationBytes)),
                frontiers: appFrontiers,
                snapshotFragment: snapshotFragment
            )
        )
        let outer = try NoctCordCodec.wrapSecure(
            secure,
            usingLegacyCapability: Self.requiresLegacyContentCapability(snapshot)
        )
        guard try NoctweaveCoder.encode(outer, sortedKeys: true).count
                <= NoctCordCodec.maximumEventBytes else {
            throw NoctCordTransportError.invalidConfiguration
        }
        let prepared = try await client.prepareGroupApplication(outer, at: date)
        // The exact signed first fragment and its seed are durable before
        // creating any external realtime route. A retry reconstructs the
        // same capabilities and expiry from that fragment.
        try await createRotatedRoutes(
            for: spaceID, requests: beforeFanoutRoutes
        )
        if let transport = prepared.transportOperation {
            let resumed = try await client.resumeGroupTransport(
                groupID: spaceID, operationID: transport.id, at: date
            )
            guard resumed.complete else {
                return NoctCordTransportPublication(
                    event: event, operationID: transport.id, complete: false
                )
            }
        }
        let publishedRuntime = try await client.openGroupRuntime(groupID: spaceID)
        snapshot = await publishedRuntime.snapshot()
        guard snapshot.pendingApplicationPublications.allSatisfy({
            $0.event.id != outer.id
        }) else {
            throw NoctCordTransportError.transportIncomplete
        }
        try await publishedRuntime.replaceProtectedApplicationEvent(
            previousEventID: nil,
            with: outer.id,
            verificationFrontiers: coreFrontiers
        )
        return NoctCordTransportPublication(
            event: event,
            operationID: prepared.transportOperation?.id,
            complete: true
        )
    }

    package func pinReceivedCheckpoints(
        _ events: [GroupConversationEventV2],
        runtime: NoctweavePQGroupRuntimeV2,
        capacityLimit: Int = GroupRuntimeRecord.maximumProtectedApplicationEvents
    ) async throws {
        guard capacityLimit > 0,
              capacityLimit <= GroupRuntimeRecord.maximumProtectedApplicationEvents else {
            throw NoctCordTransportError.invalidConfiguration
        }
        let initial = await runtime.snapshot()
        let owner = initial.signedState.members.first(where: {
            $0.role == .owner && $0.isActive(at: initial.signedState.epoch)
        })?.id
        var fragmentsBySeries: [UUID: [NoctCordSnapshotFragmentV2]] = [:]
        for outer in events where outer.authorMemberHandle == owner {
            guard let secure = try? NoctCordCodec.unwrapSecure(outer),
                  let fragment = secure.checkpoint?.snapshotFragment else { continue }
            fragmentsBySeries[fragment.seriesID, default: []].append(fragment)
        }
        let completeSeries = Set(fragmentsBySeries.compactMap { id, fragments
            -> UUID? in
            guard let first = fragments.first,
                  fragments.count == first.count,
                  Set(fragments.map(\.index)) == Set(0..<first.count),
                  fragments.allSatisfy({
                      $0.count == first.count
                          && $0.seriesSeed == first.seriesSeed
                          && $0.fullConfigurationDigest
                              == first.fullConfigurationDigest
                  }) else { return nil }
            return id
        })
        let latestCompleteSnapshotEpoch = events.compactMap { outer -> UInt64? in
            guard outer.authorMemberHandle == owner,
                  let secure = try? NoctCordCodec.unwrapSecure(outer),
                  let checkpoint = secure.checkpoint,
                  checkpoint.kind == .snapshot,
                  checkpoint.snapshotFragment.map({ fragment in
                      fragment.index + 1 == fragment.count
                          && completeSeries.contains(fragment.seriesID)
                  }) ?? true else { return nil }
            return checkpoint.groupEpoch
        }.max()
        let localIsOwner = initial.localCredential.memberHandle == owner
        let protected = Set(initial.protectedApplicationEventIDs)
        let retired = Set(initial.retiredProtectedApplicationEventIDs)
        let pending = Set(initial.pendingApplicationPublications.map { $0.event.id })
        let eligible = events.filter { outer in
            guard outer.authorMemberHandle == owner,
                  NoctCordCodec.isSecureContent(outer.content),
                  !protected.contains(outer.id),
                  !retired.contains(outer.id),
                  !pending.contains(outer.id),
                  let secure = try? NoctCordCodec.unwrapSecure(outer),
                  let checkpoint = secure.checkpoint else { return false }
            return localIsOwner
                || checkpoint.snapshotFragment.map {
                    completeSeries.contains($0.seriesID)
                        || checkpoint.groupEpoch
                            < (latestCompleteSnapshotEpoch ?? 0)
                } ?? true
        }
        if protected.count + eligible.count > capacityLimit {
            guard !localIsOwner,
                  let last = eligible.last,
                  let lastSecure = try? NoctCordCodec.unwrapSecure(last),
                  let lastPolicy = lastSecure.checkpoint,
                  lastPolicy.kind == .snapshot,
                  (lastPolicy.snapshotFragment == nil
                    || (lastPolicy.snapshotFragment.map {
                        $0.index + 1 == $0.count
                            && completeSeries.contains($0.seriesID)
                    } ?? false)) else {
                throw NoctCordTransportError.checkpointCapacityReached
            }
            let additions = Set(eligible.map(\.id))
            let full = try NoctCordSecureProjectionV2.projectForAtomicReceiverPin(
                verified: initial, adding: additions, retiring: []
            )
            let ordinaryIDs = Set(events.compactMap { outer -> UUID? in
                guard let secure = try? NoctCordCodec.unwrapSecure(outer),
                      secure.checkpoint == nil else { return nil }
                return outer.id
            })
            let fullOrdinary = Set(full.acceptedEvents.map(\.id))
                .intersection(ordinaryIDs)
            let oldCheckpoints = events.filter { outer in
                protected.contains(outer.id)
                    && NoctCordCodec.isSecureContent(outer.content)
                    && (try? NoctCordCodec.unwrapSecure(outer).checkpoint) != nil
            }
            let requiredRetirement = protected.count + eligible.count
                - capacityLimit
            var retiredSafely = false
            if oldCheckpoints.count >= requiredRetirement {
                for length in stride(
                    from: oldCheckpoints.count, through: requiredRetirement, by: -1
                ) {
                    let oldIDs = Set(oldCheckpoints.prefix(length).map(\.id))
                    guard let candidate = try? NoctCordSecureProjectionV2
                        .projectForAtomicReceiverPin(
                            verified: initial, adding: additions,
                            retiring: oldIDs
                        ),
                        candidate.projection.hasSameRetainedState(
                            as: full.projection
                        ),
                        Set(candidate.acceptedEvents.map(\.id))
                            .intersection(ordinaryIDs) == fullOrdinary else {
                        continue
                    }
                    let bindings = try eligible.map { outer in
                        guard let secure = try? NoctCordCodec.unwrapSecure(outer),
                              let checkpoint = secure.checkpoint else {
                            throw NoctCordTransportError.eventRejected
                        }
                        return GroupProtectedApplicationVerificationBindingV2(
                            eventID: outer.id,
                            frontiers: checkpoint.frontiers.map {
                                $0.coreFrontier(groupID: initial.groupId)
                            }
                        )
                    }
                    try await runtime.replaceProtectedApplicationEventSeries(
                        retiring: Array(oldIDs), with: bindings
                    )
                    retiredSafely = true
                    break
                }
            }
            guard retiredSafely else {
                // Never pin a prefix of a complete series and then hit Core's
                // cap. The caller remains read-only until enough old content
                // ages out for an atomic replacement.
                throw NoctCordTransportError.checkpointCapacityReached
            }
        }
        for outer in events where NoctCordCodec.isSecureContent(outer.content) {
            let snapshot = await runtime.snapshot()
            if snapshot.protectedApplicationEventIDs.contains(outer.id) { continue }
            if snapshot.retiredProtectedApplicationEventIDs.contains(outer.id) {
                // Atomic Core retirement leaves a tombstone while the old
                // ciphertext remains in the retained event window. It must
                // never be rebound as a live owner policy checkpoint.
                continue
            }
            if snapshot.pendingApplicationPublications.contains(where: {
                $0.event.id == outer.id
            }) { continue }
            guard let secure = try? NoctCordCodec.unwrapSecure(outer),
                  let checkpoint = secure.checkpoint else { continue }
            guard let owner else { throw NoctCordTransportError.eventRejected }
            // A member may send a structurally valid checkpoint-shaped
            // payload, but cannot claim the Core owner credential. Treat it
            // as rejected content, not a group-wide pinning error.
            guard outer.authorMemberHandle == owner else { continue }
            if let fragment = checkpoint.snapshotFragment,
               !localIsOwner && !completeSeries.contains(fragment.seriesID)
                && checkpoint.groupEpoch
                    >= (latestCompleteSnapshotEpoch ?? 0) {
                // Withholding the tail cannot consume up to 64 protected pins
                // on every receiver. Projection remains fail-closed until
                // the whole signed series arrives and is pinned.
                continue
            }
            guard
            checkpoint.owner == owner,
            checkpoint.spaceID == snapshot.groupId,
            let receipt = snapshot.applicationVerificationReceipt(for: outer.id),
            receipt.outcome == .accepted,
            receipt.eventDigest == outer.digest,
            receipt.epoch == checkpoint.groupEpoch,
            receipt.transcriptHash == checkpoint.groupTranscriptHash else {
                throw NoctCordTransportError.eventRejected
            }
            if checkpoint.groupEpoch == snapshot.signedState.epoch {
                guard Set(checkpoint.frontiers.filter {
                    $0.epoch == checkpoint.groupEpoch
                }.map(\.credential)) == Set(
                    snapshot.signedState.activeCredentials.map(\.credentialHandle)
                ) else {
                    throw NoctCordTransportError.eventRejected
                }
            }
            try await runtime.replaceProtectedApplicationEvent(
                previousEventID: nil,
                with: outer.id,
                verificationFrontiers: checkpoint.frontiers.map {
                    $0.coreFrontier(groupID: snapshot.groupId)
                }
            )
        }
    }
    #endif

    private static func projectedSpace(
        from snapshot: GroupRuntimeRecord
    ) throws -> NoctCordSpaceProjection {
        guard let owner = snapshot.signedState.members.first(where: {
            $0.role == .owner && $0.isActive(at: snapshot.signedState.epoch)
        })?.id else {
            throw NoctCordTransportError.eventRejected
        }
        let members = Set(snapshot.signedState.members.compactMap {
            $0.isActive(at: snapshot.signedState.epoch) ? $0.id : nil
        })
        #if NOCTCORD_VERIFIED_CORE
        return try NoctCordSecureProjectionV2.project(verified: snapshot).projection
        #else
        let events = snapshot.events.compactMap { try? NoctCordCodec.unwrap($0) }
        let projection = NoctCordSpaceProjection.project(
            spaceID: snapshot.groupId,
            owner: owner,
            activeMembers: members,
            historicalMembers: Set(events.map(\.author)),
            events: events
        ).projection
        return projection
        #endif
    }

    /// Replays only durable application configuration. Message bodies,
    /// attachments, presence, calls, and other ephemeral activity are not
    /// copied into admission artifacts or bootstrap batches.
    private static func bootstrapBatches(
        from events: [NoctCordEvent],
        spaceID: UUID,
        owner: GroupScopedMemberHandleV2,
        createdAt: Date
    ) throws -> [[NoctCordEvent]] {
        let eligible = events
            .filter { $0.operation.kind.isBootstrapConfiguration }
            .sorted(by: canonicalEventOrder)
        guard !eligible.isEmpty else { return [] }

        var result: [[NoctCordEvent]] = []
        var current: [NoctCordEvent] = []
        for event in eligible {
            let candidate = current + [event]
            let probe = NoctCordEvent(
                spaceID: spaceID,
                author: owner,
                logicalClock: 1,
                createdAt: createdAt,
                operation: .applyBootstrap(candidate)
            )
            if probe.isStructurallyValid {
                current = candidate
                continue
            }
            guard !current.isEmpty else {
                throw NoctCordTransportError.eventRejected
            }
            result.append(current)
            current = [event]
            let singleProbe = NoctCordEvent(
                spaceID: spaceID,
                author: owner,
                logicalClock: 1,
                createdAt: createdAt,
                operation: .applyBootstrap(current)
            )
            guard singleProbe.isStructurallyValid else {
                throw NoctCordTransportError.eventRejected
            }
        }
        if !current.isEmpty { result.append(current) }
        return result
    }

    /// A group signature establishes membership, not application authority.
    /// Rejected configuration and forged bootstrap acknowledgements must not
    /// be republished by the owner or suppress another member's admission.
    static func acceptedBootstrapHistory(
        spaceID: UUID,
        owner: GroupScopedMemberHandleV2,
        activeMembers: Set<GroupScopedMemberHandleV2>,
        events: [NoctCordEvent]
    ) -> [NoctCordEvent] {
        NoctCordSpaceProjection.project(
            spaceID: spaceID, owner: owner, activeMembers: activeMembers,
            historicalMembers: Set(events.map(\.author)), events: events
        ).acceptedEvents
    }

    private static func authorizeRealtimeEnvelope(
        _ envelope: NoctCordRealtimeSignedSignalEnvelopeV1,
        state: SignedGroupStateV2,
        projection: NoctCordSpaceProjection
    ) -> Bool {
        guard let room = projection.voiceRooms[envelope.body.roomID], !room.isArchived,
              envelope.body.signal.keyID == room.signalingKeyID,
              projection.permissions(for: envelope.body.author).contains(.connectVoice),
              projection.voiceParticipants[room.id]?[envelope.body.author]?.isJoined == true else {
            return false
        }
        return verifyRealtimeEnvelope(envelope, state: state)
    }

    private static func verifyRealtimeEnvelope(
        _ envelope: NoctCordRealtimeSignedSignalEnvelopeV1,
        state: SignedGroupStateV2
    ) -> Bool {
        guard let credential = state.memberCredentials.first(where: {
            $0.memberHandle == envelope.body.author
                && $0.credentialHandle == envelope.body.credential
                && $0.isActive(at: state.epoch)
        }),
        let signedBytes = try? NoctCordRealtimeSignalWire.signedBytes(envelope.body) else {
            return false
        }
        return SigningKeyPair.verify(
            signature: envelope.signature,
            data: signedBytes,
            publicKeyData: credential.signingPublicKey
        )
    }

    private static func canonicalEventOrder(_ lhs: NoctCordEvent, _ rhs: NoctCordEvent) -> Bool {
        if lhs.logicalClock != rhs.logicalClock { return lhs.logicalClock < rhs.logicalClock }
        if lhs.createdAt != rhs.createdAt { return lhs.createdAt < rhs.createdAt }
        return lhs.id.uuidString < rhs.id.uuidString
    }
}

/// Keeps UI-side validation from widening the protocol's private validator.
private enum NoctCordValidationBridge {
    static func isName(_ value: String) -> Bool {
        !value.isEmpty
            && value == value.trimmingCharacters(in: .whitespacesAndNewlines)
            && value.utf8.count <= 96
            && !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    }
}
