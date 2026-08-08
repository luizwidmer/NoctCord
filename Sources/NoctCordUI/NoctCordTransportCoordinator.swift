import Foundation
import NoctCordCore
@preconcurrency import NoctweaveCore

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

    public init(
        stateURL: URL,
        storageScopeIdentifier: String = "org.noctcord.client-state.v1",
        displayName: String,
        relay: RelayEndpoint,
        relayName: String,
        relayAccessPassword: String? = nil
    ) {
        self.stateURL = stateURL
        self.storageScopeIdentifier = storageScopeIdentifier
        self.displayName = displayName
        self.relay = relay
        self.relayName = relayName
        self.relayAccessPassword = relayAccessPassword
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

public struct NoctCordTransportPublication: Sendable {
    public let event: NoctCordEvent
    public let operationID: UUID?
    public let complete: Bool
}

public struct NoctCordTransportMember: Sendable {
    public let handle: GroupScopedMemberHandleV2
    public let roleName: String
    public let isCurrentMember: Bool
}

public struct NoctCordStoredSpaceSnapshot: Sendable {
    public let spaceID: UUID
    public let owner: GroupScopedMemberHandleV2
    public let currentMember: GroupScopedMemberHandleV2
    public let members: [NoctCordTransportMember]
    public let events: [NoctCordEvent]
    public let relayAssessment: NoctCordRelayAssessment
}

public struct NoctCordReceivedRealtimeSignal: Sendable {
    public let author: GroupScopedMemberHandleV2
    public let signal: NoctCordEncryptedCallSignalV1
}

private struct NoctCordRealtimeSubscriptionState: Sendable {
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
    private let relay: RelayEndpoint
    private let relayAccessPassword: String?
    private var realtimeSubscriptions: [UUID: NoctCordRealtimeSubscriptionState] = [:]

    public static func open(
        configuration: NoctCordTransportConfiguration
    ) async throws -> NoctCordTransportCoordinator {
        guard configuration.isStructurallyValid else {
            throw NoctCordTransportError.invalidConfiguration
        }
        let store = ClientStateStore(
            fileURL: configuration.stateURL,
            protection: .encrypted,
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

    public func storedSpaceIDs() async -> [UUID] {
        await client.snapshot().activePersona.groupRuntimes.map(\.groupId).sorted {
            $0.uuidString < $1.uuidString
        }
    }

    public func createSpace(
        name: String,
        createdAt: Date = Date()
    ) async throws -> NoctCordSpaceBootstrap {
        guard NoctCordValidationBridge.isName(name),
              createdAt.timeIntervalSince1970.isFinite else {
            throw NoctCordTransportError.invalidConfiguration
        }
        let groupID = UUID()
        let generalChannelID = UUID()
        _ = try await client.createGroup(
            groupID: groupID,
            relay: relay,
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
        for event in events {
            let publication = try await publish(event)
            guard publication.complete else {
                throw NoctCordTransportError.transportIncomplete
            }
        }
        let infoResponse = try? await RelayClient(endpoint: relay).send(.info())
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
        let groupEvent = try NoctCordCodec.wrap(
            event,
            credential: snapshot.localCredential.credentialHandle
        )
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
        return pages
            .flatMap(\.receivedEvents)
            .compactMap { try? NoctCordCodec.unwrap($0) }
            .sorted(by: NoctCordTransportCoordinator.canonicalEventOrder)
    }

    public func allStoredEvents(spaceID: UUID) async throws -> [NoctCordEvent] {
        let runtime = try await client.openGroupRuntime(groupID: spaceID)
        let snapshot = await runtime.snapshot()
        return snapshot.events
            .compactMap { try? NoctCordCodec.unwrap($0) }
            .sorted(by: NoctCordTransportCoordinator.canonicalEventOrder)
    }

    @discardableResult
    public func publishOperation(
        spaceID: UUID,
        operation: NoctCordOperation,
        at date: Date = Date()
    ) async throws -> NoctCordTransportPublication {
        let runtime = try await client.openGroupRuntime(groupID: spaceID)
        let snapshot = await runtime.snapshot()
        let existing = snapshot.events.compactMap { try? NoctCordCodec.unwrap($0) }
        let event = NoctCordEvent(
            spaceID: spaceID,
            author: snapshot.localCredential.memberHandle,
            logicalClock: (existing.map(\.logicalClock).max() ?? 0) + 1,
            createdAt: date,
            operation: operation
        )
        return try await publish(event, at: date)
    }

    public func storedSpaceSnapshot(
        spaceID: UUID
    ) async throws -> NoctCordStoredSpaceSnapshot {
        let runtime = try await client.openGroupRuntime(groupID: spaceID)
        let snapshot = await runtime.snapshot()
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
        return NoctCordStoredSpaceSnapshot(
            spaceID: spaceID,
            owner: owner,
            currentMember: local,
            members: members,
            events: snapshot.events
                .compactMap { try? NoctCordCodec.unwrap($0) }
                .sorted(by: NoctCordTransportCoordinator.canonicalEventOrder),
            relayAssessment: await relayAssessment()
        )
    }

    public func maintain(spaceID: UUID) async throws {
        _ = try await client.maintainGroup(groupID: spaceID)
    }

    public func relayEndpoint() -> RelayEndpoint { relay }

    public func testRelay(timeout: TimeInterval = 5) async throws {
        let response = try await RelayClient(
            endpoint: relay,
            authToken: relayAccessPassword
        ).send(.health(), timeout: timeout)
        guard response.status == .success, response.error == nil else {
            throw NoctCordTransportError.transportIncomplete
        }
    }

    public func attachmentTransfer() -> NoctCordAttachmentTransfer {
        NoctCordAttachmentTransfer(
            relay: relay,
            accessPassword: relayAccessPassword
        )
    }

    public func createRealtimeRoute(
        lifetime: TimeInterval = 23 * 60 * 60,
        now: Date = Date()
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
        guard request.isStructurallyValid else {
            throw NoctCordTransportError.invalidConfiguration
        }
        let response = try await RelayClient(
            endpoint: relay,
            authToken: relayAccessPassword
        ).send(.createRealtimeRouteV1(request))
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

    public func publishRealtimeCallSignal(
        spaceID: UUID,
        roomID: UUID,
        signal: NoctCordEncryptedCallSignalV1,
        at date: Date = Date()
    ) async throws {
        let runtime = try await client.openGroupRuntime(groupID: spaceID)
        let snapshot = await runtime.snapshot()
        let room = try Self.projectedRoom(roomID, from: snapshot)
        guard signal.callID == roomID,
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
        let response = try await relayClient().send(.appendRealtimeRouteV1(append))
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
        let snapshot = await runtime.snapshot()
        let room = try Self.projectedRoom(roomID, from: snapshot)
        guard room.realtimeRoute.expiresAt > now else {
            throw NoctCordTransportError.transportIncomplete
        }
        var subscription = try await realtimeSubscription(
            room: room,
            now: now
        )
        var received: [NoctCordReceivedRealtimeSignal] = []
        for _ in 0..<4 {
            let response = try await relayClient().send(.syncRealtimeRouteV1(
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
                ),
                Self.verifyRealtimeEnvelope(opened, state: snapshot.signedState) else {
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
        guard let subscription = realtimeSubscriptions.removeValue(forKey: roomID) else {
            return
        }
        _ = try? await relayClient().send(.unsubscribeRealtimeRouteV1(
            RealtimeRouteUnsubscribeRequestV1(
                routeCapability: subscription.routeCapability,
                subscriptionCapability: subscription.subscriptionCapability
            )
        ))
    }

    public func relayAssessment() async -> NoctCordRelayAssessment {
        guard let response = try? await RelayClient(endpoint: relay).send(.info()),
              case .relayInfo(let info)? = response.successBody else {
            return NoctCordRelaySupport.assess(
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
        return NoctCordRelaySupport.assess(info)
    }

    public func underlyingClient() -> HeadlessMessagingClient { client }

    private func relayClient() -> RelayClient {
        RelayClient(endpoint: relay, authToken: relayAccessPassword)
    }

    private func realtimeSubscription(
        room: NoctCordCore.NoctCordVoiceRoom,
        now: Date
    ) async throws -> NoctCordRealtimeSubscriptionState {
        if let existing = realtimeSubscriptions[room.id],
           existing.routeCapability == room.realtimeRoute.routeCapability,
           existing.expiresAt > now {
            return existing
        }
        if let obsolete = realtimeSubscriptions.removeValue(forKey: room.id) {
            _ = try? await relayClient().send(.unsubscribeRealtimeRouteV1(
                RealtimeRouteUnsubscribeRequestV1(
                    routeCapability: obsolete.routeCapability,
                    subscriptionCapability: obsolete.subscriptionCapability
                )
            ))
        }
        let response = try await relayClient().send(.subscribeRealtimeRouteV1(
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
            routeCapability: created.routeCapability,
            subscriptionCapability: created.subscriptionCapability,
            cursor: created.nextSequence,
            expiresAt: created.expiresAt
        )
        realtimeSubscriptions[room.id] = state
        return state
    }

    private static func projectedRoom(
        _ roomID: UUID,
        from snapshot: GroupRuntimeRecord
    ) throws -> NoctCordCore.NoctCordVoiceRoom {
        guard let owner = snapshot.signedState.members.first(where: {
            $0.role == .owner && $0.isActive(at: snapshot.signedState.epoch)
        })?.id else {
            throw NoctCordTransportError.eventRejected
        }
        let members = Set(snapshot.signedState.members.compactMap {
            $0.isActive(at: snapshot.signedState.epoch) ? $0.id : nil
        })
        let events = snapshot.events.compactMap { try? NoctCordCodec.unwrap($0) }
        let projection = NoctCordSpaceProjection.project(
            spaceID: snapshot.groupId,
            owner: owner,
            activeMembers: members,
            events: events
        ).projection
        guard let room = projection.voiceRooms[roomID], !room.isArchived else {
            throw NoctCordTransportError.spaceNotFound
        }
        return room
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
