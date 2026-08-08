import NoctCordCore
import NoctweaveCore
import XCTest

final class NoctCordCoreTests: XCTestCase {
    private let spaceID = UUID(uuidString: "10000000-0000-0000-0000-000000000001")!
    private let channelID = UUID(uuidString: "20000000-0000-0000-0000-000000000002")!
    private let timestamp = Date(timeIntervalSince1970: 1_800_000_000)

    func testEventsRoundTripThroughNoctweaveContent() throws {
        let owner = handle(1)
        let event = makeEvent(
            author: owner,
            clock: 1,
            operation: .createSpace(name: "Noct Cord")
        )

        let content = try NoctCordCodec.encode(event)
        XCTAssertEqual(content.type.canonicalName, "org.noctcord/event:1.0")
        XCTAssertEqual(try NoctCordCodec.decode(content), event)
    }

    func testGroupWrapperAcceptsNoctweaveCanonicalTimestampPrecision() throws {
        let event = NoctCordEvent(
            id: UUID(),
            spaceID: spaceID,
            author: handle(1),
            logicalClock: 1,
            createdAt: Date(timeIntervalSince1970: 1_800_000_000.123_456),
            operation: .createSpace(name: "Canonical time")
        )
        let credential = GroupScopedCredentialHandleV2(
            rawValue: Data(repeating: 0x44, count: 32).base64EncodedString()
        )

        let wrapped = try NoctCordCodec.wrap(event, credential: credential)

        XCTAssertEqual(
            wrapped.createdAt.timeIntervalSince1970,
            NoctweaveRendezvousV2.canonicalTimestamp(event.createdAt).timeIntervalSince1970,
            accuracy: 0.001
        )
        XCTAssertEqual(try NoctCordCodec.unwrap(wrapped), event)
    }

    func testCompactRealtimeRecordRoundTripIsLeanerThanCanonicalFallback() throws {
        let event = makeEvent(
            author: handle(1),
            clock: 1,
            operation: .postMessage(
                id: UUID(),
                channelID: channelID,
                text: "A compact realtime event"
            )
        )

        let canonical = try NoctCordCodec.encode(event).payload
        let compact = try NoctCordCompactCodec.encode(event)

        XCTAssertEqual(try NoctCordCompactCodec.decode(compact), event)
        XCTAssertLessThan(compact.count, canonical.count / 2)
    }

    func testCompactCodecRejectsTrailingBytes() throws {
        let event = makeEvent(
            author: handle(1),
            clock: 1,
            operation: .createSpace(name: "Noct Cord")
        )
        var bytes = try NoctCordCompactCodec.encode(event)
        bytes.append(0)

        XCTAssertThrowsError(try NoctCordCompactCodec.decode(bytes))
    }

    func testPortableIdentityCanBindAcrossCommunitiesWithoutReusingTransportIdentity() throws {
        let key = try NoctCordIdentityKeyV1.generate(scope: .portable)
        let profile = try key.publicProfile(displayName: "Luna", createdAt: timestamp)
        let first = try key.bind(
            profile: profile,
            to: spaceID,
            memberHandle: handle(1),
            issuedAt: timestamp.addingTimeInterval(1)
        )
        let second = try key.bind(
            profile: profile,
            to: UUID(),
            memberHandle: handle(2),
            issuedAt: timestamp.addingTimeInterval(2)
        )

        XCTAssertEqual(first.profile.identityID, second.profile.identityID)
        XCTAssertNotEqual(first.memberHandle, second.memberHandle)
        XCTAssertTrue(try first.verify())
        XCTAssertTrue(try second.verify())
        XCTAssertEqual(
            try NoctCordIdentityBindingCodec.decode(
                NoctCordIdentityBindingCodec.encode(first)
            ),
            first
        )
    }

    func testIsolatedCommunityIdentitiesAreUnlinkableByKey() throws {
        let first = try NoctCordIdentityKeyV1.generate(scope: .isolated)
        let second = try NoctCordIdentityKeyV1.generate(scope: .isolated)
        let firstProfile = try first.publicProfile(displayName: "Luna", createdAt: timestamp)
        let secondProfile = try second.publicProfile(displayName: "Luna", createdAt: timestamp)

        XCTAssertNotEqual(firstProfile.identityID, secondProfile.identityID)
        XCTAssertNotEqual(firstProfile.signingPublicKey, secondProfile.signingPublicKey)
    }

    func testProjectionIsDeterministicAcrossDeliveryOrder() {
        let owner = handle(1)
        let member = handle(2)
        let messageID = UUID(uuidString: "30000000-0000-0000-0000-000000000003")!
        let events = [
            makeEvent(author: owner, clock: 1, operation: .createSpace(name: "Noct Cord")),
            makeEvent(
                author: owner,
                clock: 2,
                operation: .createChannel(id: channelID, name: "general")
            ),
            makeEvent(
                author: member,
                clock: 3,
                operation: .postMessage(id: messageID, channelID: channelID, text: "hello")
            ),
            makeEvent(
                author: member,
                clock: 4,
                operation: .addReaction("🌙", to: messageID)
            ),
        ]

        let ordered = project(events, owner: owner, members: [owner, member])
        let shuffled = project([events[2], events[0], events[3], events[1]], owner: owner, members: [owner, member])

        XCTAssertEqual(ordered, shuffled)
        XCTAssertTrue(ordered.rejectedEvents.isEmpty)
        XCTAssertEqual(ordered.projection.messages[messageID]?.text, "hello")
        XCTAssertEqual(ordered.projection.messages[messageID]?.reactions["🌙"], [member])
    }

    func testUnauthorizedChannelMutationIsRejectedWithoutBlockingMessages() {
        let owner = handle(1)
        let member = handle(2)
        let secondChannel = UUID()
        let messageID = UUID()
        let events = [
            makeEvent(author: owner, clock: 1, operation: .createSpace(name: "Noct Cord")),
            makeEvent(
                author: owner,
                clock: 2,
                operation: .createChannel(id: channelID, name: "general")
            ),
            makeEvent(
                author: member,
                clock: 3,
                operation: .createChannel(id: secondChannel, name: "unauthorized")
            ),
            makeEvent(
                author: member,
                clock: 4,
                operation: .postMessage(id: messageID, channelID: channelID, text: "still works")
            ),
        ]

        let result = project(events, owner: owner, members: [owner, member])

        XCTAssertEqual(result.rejectedEvents.count, 1)
        XCTAssertNil(result.projection.channels[secondChannel])
        XCTAssertEqual(result.projection.messages[messageID]?.text, "still works")
    }

    func testInactiveMemberCannotSend() {
        let owner = handle(1)
        let departed = handle(2)
        let events = [
            makeEvent(author: owner, clock: 1, operation: .createSpace(name: "Noct Cord")),
            makeEvent(
                author: owner,
                clock: 2,
                operation: .createChannel(id: channelID, name: "general")
            ),
            makeEvent(
                author: departed,
                clock: 3,
                operation: .postMessage(id: UUID(), channelID: channelID, text: "no access")
            ),
        ]

        let result = project(events, owner: owner, members: [owner])
        XCTAssertEqual(result.rejectedEvents.count, 1)
        XCTAssertTrue(result.projection.messages.isEmpty)
    }

    func testRelayAssessmentSeparatesMVPFromDurableCommunity() {
        let mvp = RelayCapabilityManifestV2(modules: [
            RelayModuleCapabilityV2(module: "nw.core", versions: [2], status: .provisional),
            RelayModuleCapabilityV2(module: "nw.opaque-route", versions: [2], status: .provisional),
            RelayModuleCapabilityV2(module: "nw.media-blobs", versions: [1], status: .provisional),
        ])
        let realtime = RelayCapabilityManifestV2(modules: mvp.modules + [
            RelayModuleCapabilityV2(module: "nw.realtime-route", versions: [1], status: .experimental),
        ])
        let durable = RelayCapabilityManifestV2(modules: realtime.modules + [
            RelayModuleCapabilityV2(module: "nw.shared-log", versions: [1], status: .experimental),
        ])

        XCTAssertEqual(NoctCordRelaySupport.assess(mvp).tier, .encryptedGroupFallback)
        XCTAssertTrue(NoctCordRelaySupport.assess(mvp).supportsAttachments)
        XCTAssertEqual(NoctCordRelaySupport.assess(realtime).tier, .realtimeMVP)
        XCTAssertTrue(NoctCordRelaySupport.assess(realtime).usesCompactPackets)
        XCTAssertEqual(NoctCordRelaySupport.assess(durable).tier, .durableCommunity)
    }

    func testTemporallyBucketedRelayIsNotNoctCordReady() {
        let manifest = RelayCapabilityManifestV2(modules: [
            RelayModuleCapabilityV2(module: "nw.core", versions: [2], status: .provisional),
            RelayModuleCapabilityV2(module: "nw.opaque-route", versions: [2], status: .provisional),
        ])

        let assessment = NoctCordRelaySupport.assess(
            manifest,
            temporalBucketSeconds: 60
        )

        XCTAssertEqual(assessment.tier, .incompatible)
        XCTAssertEqual(assessment.deliveryProfile, .temporallyBucketed)
        XCTAssertTrue(assessment.missingModules.contains("temporalBucketing=off"))
    }

    func testAttachmentManifestIsOpaqueValidatedAndCodecCompatible() throws {
        let owner = handle(1)
        let manifest = makeAttachmentManifest(expiresAt: timestamp.addingTimeInterval(3600))
        let attachment = makeEvent(
            author: owner,
            clock: 3,
            operation: .addAttachment(
                id: UUID(uuidString: "40000000-0000-0000-0000-000000000004")!,
                channelID: channelID,
                manifest: manifest
            )
        )

        XCTAssertTrue(manifest.isStructurallyValid)
        XCTAssertFalse((String(data: try NoctCordCodec.encode(attachment).payload, encoding: .utf8)
            ?? "").contains("filename"))
        XCTAssertEqual(try NoctCordCodec.decode(NoctCordCodec.encode(attachment)), attachment)
        XCTAssertEqual(try NoctCordCompactCodec.decode(NoctCordCompactCodec.encode(attachment)), attachment)

        let unsafe = NoctCordAttachmentManifestV1(
            blobID: manifest.blobID,
            blobCapability: manifest.blobCapability,
            mediaType: "image/png;name=secret.png",
            size: manifest.size,
            digest: manifest.digest,
            expiresAt: manifest.expiresAt,
            encryption: manifest.encryption
        )
        XCTAssertFalse(unsafe.isStructurallyValid)
        XCTAssertFalse(
            NoctCordOperation.addAttachment(
                id: UUID(),
                channelID: channelID,
                manifest: unsafe
            ).isStructurallyValid
        )
    }

    func testAttachmentProjectionBindsManifestToChannelAndRejectsExpiredManifest() {
        let owner = handle(1)
        let attachmentID = UUID(uuidString: "41000000-0000-0000-0000-000000000004")!
        let validManifest = makeAttachmentManifest(expiresAt: timestamp.addingTimeInterval(3600))
        let expiredManifest = makeAttachmentManifest(expiresAt: timestamp.addingTimeInterval(3))
        let events = [
            makeEvent(author: owner, clock: 1, operation: .createSpace(name: "Noct Cord")),
            makeEvent(
                author: owner,
                clock: 2,
                operation: .createChannel(id: channelID, name: "general")
            ),
            makeEvent(
                author: owner,
                clock: 3,
                operation: .addAttachment(
                    id: attachmentID,
                    channelID: channelID,
                    manifest: validManifest
                )
            ),
            makeEvent(
                author: owner,
                clock: 4,
                operation: .addAttachment(
                    id: UUID(),
                    channelID: channelID,
                    manifest: expiredManifest
                )
            ),
        ]

        let result = project(events, owner: owner, members: [owner])
        XCTAssertEqual(result.rejectedEvents.count, 1)
        XCTAssertEqual(result.projection.attachments[attachmentID], validManifest)
        XCTAssertEqual(result.projection.channels[channelID]?.attachmentIDs, [attachmentID])
    }

    func testVoiceRoomLifecycleProjectsJoinLeaveMuteDeafenSpeakingAndArchive() {
        let owner = handle(1)
        let member = handle(2)
        let roomID = UUID(uuidString: "50000000-0000-0000-0000-000000000005")!
        let initialSpec = makeVoiceSpec(name: "general voice", maxParticipants: 4, byte: 0x31)
        let updatedSpec = makeVoiceSpec(name: "general voice", maxParticipants: 4, byte: 0x32)
        let events = [
            makeEvent(
                author: owner,
                clock: 1,
                operation: .createVoiceRoom(
                    id: roomID,
                    spec: initialSpec
                )
            ),
            makeEvent(
                author: owner,
                clock: 2,
                operation: .updateVoiceRoom(id: roomID, spec: updatedSpec)
            ),
            makeEvent(
                author: member,
                clock: 3,
                operation: .joinVoiceRoom(
                    id: roomID,
                    state: .init(member: member, isJoined: true)
                )
            ),
            makeEvent(
                author: member,
                clock: 4,
                operation: .setVoiceMute(
                    roomID: roomID,
                    state: .init(member: member, isJoined: true, isMuted: true)
                )
            ),
            makeEvent(
                author: member,
                clock: 5,
                operation: .setVoiceDeafened(
                    roomID: roomID,
                    state: .init(member: member, isJoined: true, isMuted: true, isDeafened: true)
                )
            ),
            makeEvent(
                author: member,
                clock: 6,
                operation: .setVoiceSpeaking(
                    roomID: roomID,
                    state: .init(
                        member: member,
                        isJoined: true,
                        isMuted: true,
                        isDeafened: true,
                        isSpeaking: true
                    )
                )
            ),
            makeEvent(
                author: member,
                clock: 7,
                operation: .leaveVoiceRoom(
                    id: roomID,
                    state: .init(member: member, isJoined: false)
                )
            ),
            makeEvent(author: owner, clock: 8, operation: .archiveVoiceRoom(id: roomID)),
        ]

        let ordered = project(events, owner: owner, members: [owner, member])
        let shuffled = project(
            [events[5], events[1], events[6], events[0], events[4], events[2], events[7], events[3]],
            owner: owner,
            members: [owner, member]
        )

        XCTAssertEqual(ordered, shuffled)
        XCTAssertTrue(ordered.rejectedEvents.isEmpty)
        XCTAssertTrue(ordered.projection.voiceRooms[roomID]?.isArchived == true)
        XCTAssertEqual(ordered.projection.voiceRooms[roomID]?.signalingKey, updatedSpec.signalingKey)
        XCTAssertNil(ordered.projection.voiceParticipants[roomID])
    }

    func testVoiceStateCannotBeWrittenForAnotherMember() {
        let owner = handle(1)
        let member = handle(2)
        let roomID = UUID()
        let spec = makeVoiceSpec(name: "voice")
        let events = [
            makeEvent(
                author: owner,
                clock: 1,
                operation: .createVoiceRoom(id: roomID, spec: spec)
            ),
            makeEvent(
                author: owner,
                clock: 2,
                operation: .setVoiceMute(
                    roomID: roomID,
                    state: .init(member: member, isJoined: true, isMuted: true)
                )
            ),
        ]

        let result = project(events, owner: owner, members: [owner, member])
        XCTAssertEqual(result.rejectedEvents.count, 1)
        XCTAssertTrue(result.projection.voiceParticipants.isEmpty)
    }

    func testEncryptedCallSignalAndScreenShareRemainOpaqueAndProjectState() throws {
        let owner = handle(1)
        let roomID = UUID(uuidString: "60000000-0000-0000-0000-000000000006")!
        let roomSpec = makeVoiceSpec(name: "calls", byte: 0x41)
        let signal = NoctCordEncryptedCallSignalV1(
            signalID: UUID(uuidString: "61000000-0000-0000-0000-000000000006")!,
            callID: UUID(uuidString: "62000000-0000-0000-0000-000000000006")!,
            sequence: 1,
            kind: .offer,
            keyID: roomSpec.signalingKeyID,
            nonce: Data(repeating: 0x02, count: 12),
            ciphertext: Data(repeating: 0x03, count: 96),
            authenticationTag: Data(repeating: 0x04, count: 16)
        )
        let descriptor = NoctCordScreenShareDescriptorV1(
            shareID: UUID(uuidString: "63000000-0000-0000-0000-000000000006")!,
            presenter: owner,
            source: .display,
            keyID: Data(repeating: 0x05, count: 32),
            includesAudio: true
        )
        let events = [
            makeEvent(
                author: owner,
                clock: 1,
                operation: .createVoiceRoom(id: roomID, spec: roomSpec)
            ),
            makeEvent(
                author: owner,
                clock: 2,
                operation: .joinVoiceRoom(
                    id: roomID,
                    state: .init(member: owner, isJoined: true)
                )
            ),
            makeEvent(
                author: owner,
                clock: 3,
                operation: .postCallSignal(roomID: roomID, signal: signal)
            ),
            makeEvent(
                author: owner,
                clock: 4,
                operation: .startScreenShare(roomID: roomID, descriptor: descriptor)
            ),
        ]

        let content = try NoctCordCodec.encode(events[2])
        XCTAssertTrue(signal.isStructurallyValid)
        XCTAssertEqual(try NoctCordCodec.decode(content), events[2])
        XCTAssertEqual(try NoctCordCompactCodec.decode(NoctCordCompactCodec.encode(events[2])), events[2])

        let projection = project(events, owner: owner, members: [owner]).projection
        XCTAssertEqual(projection.callSignals[signal.callID]?[signal.signalID], signal)
        XCTAssertEqual(projection.activeScreenShares[descriptor.shareID]?.descriptor, descriptor)
        XCTAssertEqual(projection.activeScreenShares[descriptor.shareID]?.roomID, roomID)

        let stop = makeEvent(
            author: owner,
            clock: 5,
            operation: .stopScreenShare(roomID: roomID, shareID: descriptor.shareID)
        )
        var withStop = events
        withStop.append(stop)
        XCTAssertTrue(project(withStop, owner: owner, members: [owner]).projection.activeScreenShares.isEmpty)
    }

    func testDuplicateCallSignalIDIsRejected() {
        let owner = handle(1)
        let roomID = UUID()
        let roomSpec = makeVoiceSpec(name: "calls", byte: 0x51)
        let signal = NoctCordEncryptedCallSignalV1(
            signalID: UUID(),
            callID: UUID(),
            sequence: 1,
            kind: .answer,
            keyID: roomSpec.signalingKeyID,
            nonce: Data(repeating: 0x12, count: 12),
            ciphertext: Data(repeating: 0x13, count: 1),
            authenticationTag: Data(repeating: 0x14, count: 16)
        )
        let events = [
            makeEvent(author: owner, clock: 1, operation: .createVoiceRoom(id: roomID, spec: roomSpec)),
            makeEvent(author: owner, clock: 2, operation: .joinVoiceRoom(id: roomID, state: .init(member: owner, isJoined: true))),
            makeEvent(author: owner, clock: 3, operation: .postCallSignal(roomID: roomID, signal: signal)),
            makeEvent(author: owner, clock: 4, operation: .postCallSignal(roomID: roomID, signal: signal)),
        ]

        let result = project(events, owner: owner, members: [owner])
        XCTAssertEqual(result.rejectedEvents.count, 1)
        XCTAssertEqual(result.projection.callSignals[signal.callID]?.count, 1)
    }

    func testVoiceRoomRejectsInvalidSignalingKeyAndUpdateReplacesIt() {
        let owner = handle(1)
        let roomID = UUID()
        let invalid = NoctCordVoiceRoomSpecV1(
            name: "invalid",
            signalingKey: Data(repeating: 0x61, count: 31),
            realtimeRoute: makeRealtimeRoute(byte: 0x71)
        )
        let valid = makeVoiceSpec(name: "valid", byte: 0x62)
        XCTAssertFalse(invalid.isStructurallyValid)

        let events = [
            makeEvent(author: owner, clock: 1, operation: .createVoiceRoom(id: roomID, spec: valid)),
            makeEvent(author: owner, clock: 2, operation: .updateVoiceRoom(id: roomID, spec: invalid)),
        ]
        let result = project(events, owner: owner, members: [owner])
        XCTAssertEqual(result.rejectedEvents.count, 1)
        XCTAssertEqual(result.projection.voiceRooms[roomID]?.signalingKey, valid.signalingKey)
    }

    private func project(
        _ events: [NoctCordEvent],
        owner: GroupScopedMemberHandleV2,
        members: Set<GroupScopedMemberHandleV2>
    ) -> NoctCordProjectionResult {
        NoctCordSpaceProjection.project(
            spaceID: spaceID,
            owner: owner,
            activeMembers: members,
            events: events
        )
    }

    private func makeEvent(
        author: GroupScopedMemberHandleV2,
        clock: UInt64,
        operation: NoctCordOperation
    ) -> NoctCordEvent {
        NoctCordEvent(
            id: UUID(),
            spaceID: spaceID,
            author: author,
            logicalClock: clock,
            createdAt: timestamp.addingTimeInterval(TimeInterval(clock)),
            operation: operation
        )
    }

    private func handle(_ byte: UInt8) -> GroupScopedMemberHandleV2 {
        GroupScopedMemberHandleV2(
            rawValue: Data(repeating: byte, count: 32).base64EncodedString()
        )
    }

    private func makeVoiceSpec(
        name: String,
        maxParticipants: UInt16 = 16,
        byte: UInt8 = 0x30
    ) -> NoctCordVoiceRoomSpecV1 {
        NoctCordVoiceRoomSpecV1(
            name: name,
            maxParticipants: maxParticipants,
            signalingKey: Data(repeating: byte, count: 32),
            realtimeRoute: makeRealtimeRoute(byte: byte &+ 1)
        )
    }

    private func makeRealtimeRoute(byte: UInt8) -> NoctCordRealtimeRouteV1 {
        NoctCordRealtimeRouteV1(
            routeCapability: Data(repeating: byte, count: 32),
            appendCapability: Data(repeating: byte &+ 1, count: 32),
            readCapability: Data(repeating: byte &+ 2, count: 32),
            expiresAt: timestamp.addingTimeInterval(3_600)
        )
    }

    private func makeAttachmentManifest(expiresAt: Date) -> NoctCordAttachmentManifestV1 {
        NoctCordAttachmentManifestV1(
            blobID: Data(repeating: 0x21, count: 32),
            blobCapability: Data(repeating: 0x20, count: 32),
            mediaType: "image/png",
            size: 1_024,
            digest: Data(repeating: 0x22, count: 32),
            expiresAt: expiresAt,
            encryption: .init(
                keyID: Data(repeating: 0x23, count: 32),
                contentKey: Data(repeating: 0x25, count: 32),
                nonce: Data(repeating: 0x24, count: 12)
            )
        )
    }
}
