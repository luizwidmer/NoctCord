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
            RelayModuleCapabilityV2(module: "nw.blobs", versions: [1], status: .provisional),
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
}
