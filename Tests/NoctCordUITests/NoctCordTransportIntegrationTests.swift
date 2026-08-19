import Foundation
import CryptoKit
import NoctCordCore
import NoctCordMedia
@testable import NoctCordUI
@preconcurrency import NoctweaveCore
import XCTest

final class NoctCordTransportIntegrationTests: XCTestCase {
    func testRelayAdvertisedCoturnIsDiscoveredWithTemporaryCredentials() async throws {
        let relayPassword = "correct horse battery staple"
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "noctcord-ice-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let descriptor = RelayICEServiceDescriptorV1(
            urls: [
                "stun:turn.example.test:3478",
                "turn:turn.example.test:3478?transport=udp"
            ],
            credentialMode: .turnREST,
            credentialLifetimeSeconds: 600,
            realm: "turn.example.test",
            relayOnlySupported: true
        )
        let server = RelayServer(
            store: RelayStore(),
            configuration: RelayConfiguration(
                iceService: descriptor,
                accessPassword: relayPassword
            ),
            coturnCredentialIssuer: try XCTUnwrap(CoturnCredentialIssuerV1(
                sharedSecret: "0123456789abcdef0123456789abcdef"
            ))
        )
        let endpoint = try await startOnEphemeralLoopbackPort(server)
        defer { server.stop() }

        let client = try await makeClient(name: "ice-client", root: root)
        let coordinator = try NoctCordTransportCoordinator(
            client: client,
            relay: endpoint,
            relayAccessPassword: relayPassword
        )
        let configuration = try await coordinator.discoverCallConnectivity()

        XCTAssertTrue(configuration.relayAdvertised)
        XCTAssertTrue(configuration.relayOnlySupported)
        XCTAssertEqual(configuration.servers.count, 2)
        XCTAssertEqual(configuration.servers[0].urls, ["stun:turn.example.test:3478"])
        XCTAssertEqual(configuration.servers[1].urls, ["turn:turn.example.test:3478?transport=udp"])
        XCTAssertNotNil(configuration.servers[1].username)
        XCTAssertNotNil(configuration.servers[1].credential)
        XCTAssertGreaterThan(try XCTUnwrap(configuration.credentialExpiresAt), Date())
    }

    func testRelayWithoutICEAdvertisementStaysDirectOnly() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "noctcord-direct-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let server = RelayServer(store: RelayStore())
        let endpoint = try await startOnEphemeralLoopbackPort(server)
        defer { server.stop() }

        let client = try await makeClient(name: "direct-client", root: root)
        let configuration = try await NoctCordTransportCoordinator(
            client: client,
            relay: endpoint
        ).discoverCallConnectivity()
        XCTAssertFalse(configuration.relayAdvertised)
        XCTAssertTrue(configuration.servers.isEmpty)
        XCTAssertNil(configuration.credentialExpiresAt)
    }

    func testInvitationAdmissionJoinsAndExchangesMessagesBothWays() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "noctcord-admission-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let server = RelayServer(store: RelayStore(), opaqueRouteStore: OpaqueRouteRelayStoreV2())
        let endpoint = try await startOnEphemeralLoopbackPort(server)
        defer { server.stop() }

        let owner = try await makeClient(name: "owner", root: root)
        let prospectiveMember = try await makeClient(name: "member", root: root)
        let ownerTransport = try NoctCordTransportCoordinator(client: owner, relay: endpoint)
        let memberTransport = try NoctCordTransportCoordinator(
            client: prospectiveMember,
            relay: endpoint
        )
        let created = try await ownerTransport.createSpace(name: "Night Shift")
        mark("admission-space-created")
        let invitation = try await ownerTransport.makeCommunityInvitation(
            spaceID: created.spaceID,
            spaceName: "Night Shift"
        )
        let decodedInvitation = try NoctCordCommunityInvitationV1.decode(
            invitation.encoded()
        )
        let admission = try await memberTransport.prepareCommunityAdmission(
            invitation: decodedInvitation
        )
        mark("admission-request-prepared")
        let response = try await ownerTransport.approveCommunityAdmissionRequest(
            admission.requestCode,
            for: created.spaceID
        )
        mark("admission-request-approved")

        let joinedSpaceID = try await memberTransport.acceptCommunityAdmissionResponse(response)
        mark("admission-response-accepted")
        XCTAssertEqual(joinedSpaceID, created.spaceID)
        _ = try await ownerTransport.synchronize(spaceID: created.spaceID)
        let publishedBootstrap = try await ownerTransport.ensureCommunityBootstrap(
            spaceID: created.spaceID
        )
        XCTAssertTrue(publishedBootstrap)
        _ = try await memberTransport.synchronize(spaceID: created.spaceID)
        mark("admission-bootstrap-synchronized")

        let ownerMessageID = UUID()
        let ownerPublication = try await ownerTransport.publishOperation(
            spaceID: created.spaceID,
            operation: .postMessage(
                id: ownerMessageID,
                channelID: created.generalChannelID,
                text: "Welcome aboard"
            )
        )
        mark("admission-owner-message-published")
        XCTAssertTrue(ownerPublication.complete)
        _ = try await memberTransport.synchronize(spaceID: created.spaceID)
        mark("admission-member-synchronized")
        let memberAfterOwnerMessage = try await memberTransport.storedSpaceSnapshot(
            spaceID: created.spaceID
        )
        XCTAssertTrue(memberAfterOwnerMessage.events.contains {
            $0.operation.messageID == ownerMessageID
        })

        let memberMessageID = UUID()
        let memberPublication = try await memberTransport.publishOperation(
            spaceID: created.spaceID,
            operation: .postMessage(
                id: memberMessageID,
                channelID: created.generalChannelID,
                text: "Glad to be here"
            )
        )
        mark("admission-member-message-published")
        XCTAssertTrue(memberPublication.complete)
        _ = try await ownerTransport.synchronize(spaceID: created.spaceID)
        mark("admission-owner-synchronized")
        let ownerAfterReply = try await ownerTransport.storedSpaceSnapshot(
            spaceID: created.spaceID
        )
        XCTAssertTrue(ownerAfterReply.events.contains {
            $0.operation.messageID == memberMessageID
        })
    }

    func testSingleMemberRoomCanPublishAndReadRealtimeSignal() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "noctcord-single-member-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let server = RelayServer(store: RelayStore(), opaqueRouteStore: OpaqueRouteRelayStoreV2())
        let endpoint = try await startOnEphemeralLoopbackPort(server)
        defer { server.stop() }

        let client = try await makeClient(name: "owner", root: root)
        let transport = try NoctCordTransportCoordinator(client: client, relay: endpoint)
        let bootstrap = try await transport.createSpace(name: "Realtime test")
        let roomID = UUID()
        let roomKey = Data(repeating: 0xC4, count: 32)
        let route = try await transport.createRealtimeRoute(lifetime: 600)
        let roomCreation = try await transport.publishOperation(
            spaceID: bootstrap.spaceID,
            operation: .createVoiceRoom(
                id: roomID,
                spec: NoctCordVoiceRoomSpecV1(
                    name: "Call",
                    maxParticipants: 2,
                    signalingKey: roomKey,
                    realtimeRoute: route
                )
            )
        )
        XCTAssertTrue(roomCreation.complete)
        let roomSnapshot = try await transport.storedSpaceSnapshot(spaceID: bootstrap.spaceID)
        let roomProjectionResult = NoctCordSpaceProjection.project(
            spaceID: bootstrap.spaceID,
            owner: roomSnapshot.owner,
            activeMembers: Set(roomSnapshot.members.map(\.handle)),
            events: roomSnapshot.events
        )
        XCTAssertNotNil(
            roomProjectionResult.projection.voiceRooms[roomID],
            "events=\(roomSnapshot.events.map { $0.operation.kind.rawValue }) rejected=\(roomProjectionResult.rejectedEvents)"
        )

        let signal = NoctCordEncryptedCallSignalV1(
            signalID: UUID(),
            callID: roomID,
            sequence: 1,
            kind: .offer,
            keyID: Data(SHA256.hash(
                data: Data("NoctCord/voice-signaling-key/v1".utf8) + roomKey
            )),
            nonce: Data(repeating: 0x11, count: 12),
            ciphertext: Data(repeating: 0x22, count: 96),
            authenticationTag: Data(repeating: 0x33, count: 16)
        )
        try await transport.publishRealtimeCallSignal(
            spaceID: bootstrap.spaceID,
            roomID: roomID,
            signal: signal
        )
        let relayClient = RelayClient(endpoint: endpoint)
        let subscriptionResponse = try await relayClient.send(.subscribeRealtimeRouteV1(
            RealtimeRouteSubscribeRequestV1(
                routeCapability: route.routeCapability,
                readCapability: route.readCapability,
                afterSequence: 0
            )
        ))
        guard case .realtimeRouteSubscription(let subscription)? = subscriptionResponse.successBody else {
            XCTFail("relay did not create the diagnostic realtime subscription")
            return
        }
        let rawResponse = try await relayClient.send(.syncRealtimeRouteV1(
            RealtimeRouteSyncRequestV1(
                routeCapability: route.routeCapability,
                subscriptionCapability: subscription.subscriptionCapability,
                afterSequence: 0,
                maxRecords: 8
            )
        ))
        guard case .realtimeRouteSync(let rawBatch)? = rawResponse.successBody else {
            XCTFail("relay did not return the diagnostic realtime batch")
            return
        }
        XCTAssertEqual(rawBatch.records.count, 1)
        let projectedRoom = try XCTUnwrap(roomProjectionResult.projection.voiceRooms[roomID])
        let opened = try NoctCordRealtimeSignalWire.open(
            try XCTUnwrap(rawBatch.records.first).payload,
            room: projectedRoom,
            spaceID: bootstrap.spaceID
        )
        XCTAssertEqual(opened.body.signal, signal)
        let runtimeSnapshot = await (try client.openGroupRuntime(
            groupID: bootstrap.spaceID
        )).snapshot()
        let signingCredential = try XCTUnwrap(
            runtimeSnapshot.signedState.memberCredentials.first(where: {
                $0.memberHandle == opened.body.author
                    && $0.credentialHandle == opened.body.credential
            })
        )
        XCTAssertTrue(signingCredential.isActive(at: runtimeSnapshot.signedState.epoch))
        XCTAssertTrue(SigningKeyPair.verify(
            signature: opened.signature,
            data: try NoctCordRealtimeSignalWire.signedBytes(opened.body),
            publicKeyData: signingCredential.signingPublicKey
        ))
        let received = try await transport.synchronizeRealtimeCallSignals(
            spaceID: bootstrap.spaceID,
            roomID: roomID
        )
        XCTAssertEqual(received.map(\.signal), [signal])
    }

    func testThreeMembersExchangeChannelStateAttachmentAndRealtimeSignal() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "noctcord-three-member-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let server = RelayServer(
            store: RelayStore(),
            opaqueRouteStore: OpaqueRouteRelayStoreV2()
        )
        let endpoint = try await startOnEphemeralLoopbackPort(server)
        defer { server.stop() }

        let owner = try await makeClient(name: "owner", root: root)
        let memberOne = try await makeClient(name: "member-one", root: root)
        let memberTwo = try await makeClient(name: "member-two", root: root)
        let ownerTransport = try NoctCordTransportCoordinator(client: owner, relay: endpoint)
        let firstTransport = try NoctCordTransportCoordinator(client: memberOne, relay: endpoint)
        let secondTransport = try NoctCordTransportCoordinator(client: memberTwo, relay: endpoint)

        let groupID = UUID()
        let startedAt = NoctweaveRendezvousV2.canonicalTimestamp(
            Date().addingTimeInterval(-30)
        )
        _ = try await owner.createGroup(
            groupID: groupID,
            relay: endpoint,
            contentTypes: NoctCordCodec.contentCapabilities,
            createdAt: startedAt
        )
        mark("group-created")
        try await admit(
            memberOne,
            to: groupID,
            owner: owner,
            relay: endpoint,
            existingMembers: [],
            seed: 0x31,
            startedAt: startedAt.addingTimeInterval(2)
        )
        mark("member-one-admitted")
        try await admit(
            memberTwo,
            to: groupID,
            owner: owner,
            relay: endpoint,
            existingMembers: [memberOne],
            seed: 0x41,
            startedAt: startedAt.addingTimeInterval(7)
        )
        mark("member-two-admitted")

        let channelID = UUID()
        let spaceCreation = try await ownerTransport.publishOperation(
            spaceID: groupID,
            operation: .createSpace(name: "Night Shift")
        )
        XCTAssertTrue(spaceCreation.complete)
        let channelCreation = try await ownerTransport.publishOperation(
            spaceID: groupID,
            operation: .createChannel(id: channelID, name: "general")
        )
        XCTAssertTrue(channelCreation.complete)
        _ = try await firstTransport.synchronize(spaceID: groupID)
        _ = try await secondTransport.synchronize(spaceID: groupID)
        mark("space-state-synchronized")

        let ownerMessage = UUID()
        let firstMessagePublication = try await ownerTransport.publishOperation(
            spaceID: groupID,
            operation: .postMessage(
                id: ownerMessage,
                channelID: channelID,
                text: "owner to everyone"
            )
        )
        XCTAssertTrue(firstMessagePublication.complete)
        _ = try await firstTransport.synchronize(spaceID: groupID)
        _ = try await secondTransport.synchronize(spaceID: groupID)
        mark("messages-synchronized")

        let memberMessage = UUID()
        let secondMessagePublication = try await firstTransport.publishOperation(
            spaceID: groupID,
            operation: .postMessage(
                id: memberMessage,
                channelID: channelID,
                text: "member to everyone"
            )
        )
        XCTAssertTrue(secondMessagePublication.complete)
        _ = try await ownerTransport.synchronize(spaceID: groupID)
        _ = try await secondTransport.synchronize(spaceID: groupID)

        let secondSnapshot = try await secondTransport.storedSpaceSnapshot(spaceID: groupID)
        let secondProjection = NoctCordSpaceProjection.project(
            spaceID: groupID,
            owner: secondSnapshot.owner,
            activeMembers: Set(secondSnapshot.members.map(\.handle)),
            events: secondSnapshot.events
        ).projection
        XCTAssertEqual(secondProjection.messages[ownerMessage]?.text, "owner to everyone")
        XCTAssertEqual(secondProjection.messages[memberMessage]?.text, "member to everyone")

        let cleartext = Data("sanitized channel attachment".utf8)
        let attachmentTransfer = await firstTransport.attachmentTransfer()
        let uploaded = try await attachmentTransfer.upload(
            NoctCordSanitizedAttachment(
                bytes: cleartext,
                mimeType: "text/plain",
                kind: .document
            ),
            spaceID: groupID,
            channelID: channelID,
            ttlSeconds: 600
        )
        let attachmentPublication = try await firstTransport.publishOperation(
            spaceID: groupID,
            operation: .addAttachment(
                id: uploaded.id,
                channelID: channelID,
                manifest: uploaded.manifest
            )
        )
        XCTAssertTrue(attachmentPublication.complete)
        _ = try await secondTransport.synchronize(spaceID: groupID)
        let downloaded = try await (await secondTransport.attachmentTransfer()).download(
            manifest: uploaded.manifest,
            spaceID: groupID,
            channelID: channelID
        )
        XCTAssertEqual(downloaded.bytes, cleartext)
        mark("attachment-roundtrip-complete")

        let route = try await ownerTransport.createRealtimeRoute(lifetime: 600)
        let roomID = UUID()
        let roomKey = Data(repeating: 0xB7, count: 32)
        let roomPublication = try await ownerTransport.publishOperation(
            spaceID: groupID,
            operation: .createVoiceRoom(
                id: roomID,
                spec: NoctCordVoiceRoomSpecV1(
                    name: "Standup",
                    maxParticipants: 8,
                    signalingKey: roomKey,
                    realtimeRoute: route
                )
            )
        )
        XCTAssertTrue(roomPublication.complete)
        _ = try await firstTransport.synchronize(spaceID: groupID)
        _ = try await secondTransport.synchronize(spaceID: groupID)
        mark("voice-room-created")

        let ownerSnapshot = try await ownerTransport.storedSpaceSnapshot(spaceID: groupID)
        let firstSnapshot = try await firstTransport.storedSpaceSnapshot(spaceID: groupID)
        let ownerHandle = ownerSnapshot.currentMember
        let firstHandle = firstSnapshot.currentMember
        for (transport, handle) in [
            (ownerTransport, ownerHandle),
            (firstTransport, firstHandle),
            (secondTransport, secondSnapshot.currentMember),
        ] {
            let joinPublication = try await transport.publishOperation(
                spaceID: groupID,
                operation: .joinVoiceRoom(
                    id: roomID,
                    state: NoctCordVoiceParticipantStateV1(
                        member: handle,
                        isJoined: true
                    )
                )
            )
            XCTAssertTrue(joinPublication.complete)
        }
        _ = try await ownerTransport.synchronize(spaceID: groupID)
        _ = try await firstTransport.synchronize(spaceID: groupID)
        _ = try await secondTransport.synchronize(spaceID: groupID)
        mark("all-members-joined-voice")

        let signal = NoctCordEncryptedCallSignalV1(
            signalID: UUID(),
            callID: roomID,
            sequence: 1,
            kind: .offer,
            recipient: firstHandle,
            keyID: Data(SHA256.hash(
                data: Data("NoctCord/voice-signaling-key/v1".utf8) + roomKey
            )),
            nonce: Data(repeating: 0x01, count: 12),
            ciphertext: Data(repeating: 0x02, count: 96),
            authenticationTag: Data(repeating: 0x03, count: 16)
        )
        try await ownerTransport.publishRealtimeCallSignal(
            spaceID: groupID,
            roomID: roomID,
            signal: signal
        )
        let received = try await firstTransport.synchronizeRealtimeCallSignals(
            spaceID: groupID,
            roomID: roomID
        )
        XCTAssertEqual(received.map(\.author), [ownerHandle])
        XCTAssertEqual(received.map(\.signal), [signal])
        mark("realtime-signal-received")
    }

    private func startOnEphemeralLoopbackPort(
        _ server: RelayServer
    ) async throws -> RelayEndpoint {
        let started = expectation(description: "relay started")
        var boundPort: UInt16?
        server.onEvent = { event in
            if case .started(let port) = event {
                boundPort = port
                started.fulfill()
            }
        }
        try server.start(host: "127.0.0.1", port: 0)
        await fulfillment(of: [started], timeout: 5)
        return RelayEndpoint(
            host: "127.0.0.1",
            port: try XCTUnwrap(boundPort)
        )
    }

    private func makeClient(name: String, root: URL) async throws -> HeadlessMessagingClient {
        try await HeadlessMessagingClient.open(
            stateStore: ClientStateStore(
                fileURL: root.appendingPathComponent("\(name).json"),
                protection: .insecurePlaintextForTesting
            ),
            displayName: name
        )
    }

    private func mark(_ value: String) {
        FileHandle.standardError.write(Data("[NoctCordIntegration] \(value)\n".utf8))
    }

    private func admit(
        _ member: HeadlessMessagingClient,
        to groupID: UUID,
        owner: HeadlessMessagingClient,
        relay: RelayEndpoint,
        existingMembers: [HeadlessMessagingClient],
        seed: UInt8,
        startedAt: Date
    ) async throws {
        let binding = Data(repeating: seed, count: 32)
        let admission = try await member.prepareGroupAdmission(
            groupID: groupID,
            invitationBindingDigest: binding,
            relay: relay,
            contentTypes: NoctCordCodec.contentCapabilities,
            expiresAt: startedAt.addingTimeInterval(3_600),
            createdAt: startedAt
        )
        mark("admit-\(seed)-prepared")
        let route = try await member.resumeGroupAdmissionRoute(
            admissionID: admission.admissionID,
            at: startedAt.addingTimeInterval(0.2)
        )
        mark("admit-\(seed)-route")
        let addition = try await owner.prepareGroupMemberAddition(
            groupID: groupID,
            admission: admission.admission,
            initialRouteSet: route.routeSet,
            idempotencyKey: Data(repeating: seed &+ 1, count: 32),
            createdAt: startedAt.addingTimeInterval(0.4)
        )
        mark("admit-\(seed)-addition")
        _ = try await member.pinGroupJoinAnchor(
            admissionID: admission.admissionID,
            anchor: addition.anchor,
            invitationBindingDigest: binding,
            observedAt: startedAt.addingTimeInterval(0.5)
        )
        mark("admit-\(seed)-anchor")
        for announcement in addition.existingMemberRouteAnnouncements {
            _ = try await member.acceptGroupAdmissionRouteAnnouncement(
                admissionID: admission.admissionID,
                announcement: announcement,
                observedAt: startedAt.addingTimeInterval(0.6)
            )
        }
        mark("admit-\(seed)-announcements")
        _ = try await member.acceptGroupAdmissionTransition(
            admissionID: admission.admissionID,
            transition: addition.transition,
            observedAt: startedAt.addingTimeInterval(0.7)
        )
        mark("admit-\(seed)-transition")
        let completed = try await member.acceptGroupAdmissionWelcome(
            admissionID: admission.admissionID,
            welcome: addition.welcome,
            observedAt: startedAt.addingTimeInterval(0.8)
        )
        mark("admit-\(seed)-welcome")
        XCTAssertTrue(completed.completed)
        if let operation = addition.transportOperation {
            let transport = try await owner.resumeGroupTransport(
                groupID: groupID,
                operationID: operation.id
            )
            XCTAssertTrue(transport.complete)
        }
        mark("admit-\(seed)-transport")
        for existing in existingMembers {
            _ = try await existing.syncGroup(groupID: groupID)
            _ = try await existing.maintainGroup(groupID: groupID)
        }
        mark("admit-\(seed)-existing-maintained")
        _ = try await member.maintainGroup(groupID: groupID)
        mark("admit-\(seed)-member-maintained")
        _ = try await owner.syncGroup(groupID: groupID)
        mark("admit-\(seed)-owner-synced")
    }
}
