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

    func testContentDecoderRejectsNonCanonicalAndAmbiguousWrappers() throws {
        let event = makeEvent(
            author: handle(1),
            clock: 1,
            operation: .createSpace(name: "Noct Cord")
        )
        let content = try NoctCordCodec.encode(event)

        var nonCanonicalPayload = content.payload
        nonCanonicalPayload.append(0x20)
        XCTAssertThrowsError(
            try NoctCordCodec.decode(
                EncodedContent(
                    type: content.type,
                    parameters: content.parameters,
                    payload: nonCanonicalPayload,
                    fallbackText: content.fallbackText,
                    disposition: content.disposition
                )
            )
        )

        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: content.payload) as? [String: Any]
        )
        object["unexpected"] = true
        let payloadWithUnknownField = try JSONSerialization.data(
            withJSONObject: object,
            options: [.sortedKeys, .withoutEscapingSlashes]
        )
        XCTAssertTrue(NoctweaveCanonicalJSON.isCanonical(payloadWithUnknownField))
        XCTAssertThrowsError(
            try NoctCordCodec.decode(
                EncodedContent(
                    type: content.type,
                    parameters: content.parameters,
                    payload: payloadWithUnknownField,
                    fallbackText: content.fallbackText,
                    disposition: content.disposition
                )
            )
        )

        XCTAssertThrowsError(
            try NoctCordCodec.decode(
                EncodedContent(
                    type: content.type,
                    parameters: content.parameters.merging(["shadow": "1"]) { current, _ in current },
                    payload: content.payload,
                    fallbackText: content.fallbackText,
                    disposition: content.disposition
                )
            )
        )
        XCTAssertThrowsError(
            try NoctCordCodec.decode(
                EncodedContent(
                    type: content.type,
                    parameters: content.parameters,
                    payload: content.payload,
                    fallbackText: "alternate interpretation",
                    disposition: content.disposition
                )
            )
        )
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

    func testCommunityInvitationRoundTripsAndRejectsExpiryOrTampering() throws {
        let issuedAt = Date()
        let invitation = try NoctCordCommunityInvitationV1.create(
            spaceID: spaceID,
            spaceName: "Night Shift",
            relay: RelayEndpoint(host: "relay.example", port: 443, useTLS: true),
            baseEpoch: 7,
            baseStateDigest: Data(repeating: 0x41, count: 32),
            lifetime: 600,
            issuedAt: issuedAt
        )
        let encoded = try invitation.encoded()

        XCTAssertEqual(
            try NoctCordCommunityInvitationV1.decode(
                encoded,
                at: issuedAt.addingTimeInterval(1)
            ),
            invitation
        )
        XCTAssertThrowsError(
            try NoctCordCommunityInvitationV1.decode(
                encoded,
                at: issuedAt.addingTimeInterval(601)
            )
        ) { error in
            XCTAssertEqual(
                error as? NoctCordCommunityInvitationError,
                .expiredInvitation
            )
        }

        var tampered = encoded
        let mutationIndex = tampered.index(before: tampered.endIndex)
        tampered.replaceSubrange(
            mutationIndex...mutationIndex,
            with: tampered[mutationIndex] == "A" ? "B" : "A"
        )
        XCTAssertThrowsError(
            try NoctCordCommunityInvitationV1.decode(
                tampered,
                at: issuedAt.addingTimeInterval(1)
            )
        )
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

    func testIdentityBindingIsVerifiedProjectedAndCompactEncoded() throws {
        let owner = handle(1)
        let key = try NoctCordIdentityKeyV1.generate(scope: .portable)
        let profile = try key.publicProfile(displayName: "Luna", createdAt: timestamp)
        let binding = try key.bind(
            profile: profile,
            to: spaceID,
            memberHandle: owner,
            issuedAt: timestamp.addingTimeInterval(1)
        )
        let event = makeEvent(
            author: owner,
            clock: 1,
            operation: .bindIdentity(binding)
        )

        let result = project([event], owner: owner, members: [owner])

        XCTAssertTrue(result.rejectedEvents.isEmpty)
        XCTAssertEqual(result.projection.identityBindings[owner], binding)
        XCTAssertEqual(
            try NoctCordCompactCodec.decode(NoctCordCompactCodec.encode(event)),
            event
        )
    }

    func testOwnerBootstrapRestoresConfigurationAfterJoinRequest() throws {
        let owner = handle(1)
        let member = handle(2)
        let spaceCreation = makeEvent(
            author: owner,
            clock: 1,
            operation: .createSpace(name: "Night Shift")
        )
        let channelCreation = makeEvent(
            author: owner,
            clock: 2,
            operation: .createChannel(id: channelID, name: "general")
        )
        let request = makeEvent(
            author: member,
            clock: 3,
            operation: .requestBootstrap()
        )
        let bootstrap = makeEvent(
            author: owner,
            clock: 4,
            operation: .applyBootstrap(
                [spaceCreation, channelCreation],
                satisfying: [request.id]
            )
        )

        let result = project(
            [request, bootstrap],
            owner: owner,
            members: [owner, member]
        )

        XCTAssertTrue(result.rejectedEvents.isEmpty)
        XCTAssertEqual(result.projection.name, "Night Shift")
        XCTAssertEqual(result.projection.channels[channelID]?.name, "general")
        XCTAssertEqual(
            try NoctCordCompactCodec.decode(NoctCordCompactCodec.encode(bootstrap)),
            bootstrap
        )
    }

    func testNonOwnerCannotApplyBootstrap() {
        let owner = handle(1)
        let member = handle(2)
        let nested = makeEvent(
            author: owner,
            clock: 1,
            operation: .createSpace(name: "Forged")
        )
        let forged = makeEvent(
            author: member,
            clock: 2,
            operation: .applyBootstrap([nested])
        )

        let result = project([forged], owner: owner, members: [owner, member])

        XCTAssertNil(result.projection.name)
        XCTAssertEqual(result.rejectedEvents.count, 1)
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

    func testEveryoneChannelDenyBlocksMembersButNeverTheOwner() {
        let owner = handle(1)
        let member = handle(2)
        let memberMessage = UUID()
        let ownerMessage = UUID()
        let events = [
            makeEvent(author: owner, clock: 1, operation: .createSpace(name: "Noct Cord")),
            makeEvent(
                author: owner,
                clock: 2,
                operation: .createChannel(id: channelID, name: "announcements")
            ),
            makeEvent(
                author: owner,
                clock: 3,
                operation: .setChannelPermissions(
                    channelID: channelID,
                    roleID: nil,
                    allow: [],
                    deny: [.sendMessages]
                )
            ),
            makeEvent(
                author: member,
                clock: 4,
                operation: .postMessage(
                    id: memberMessage,
                    channelID: channelID,
                    text: "not authorized"
                )
            ),
            makeEvent(
                author: owner,
                clock: 5,
                operation: .postMessage(
                    id: ownerMessage,
                    channelID: channelID,
                    text: "owner announcement"
                )
            ),
        ]

        let result = project(events, owner: owner, members: [owner, member])

        XCTAssertEqual(result.rejectedEvents.count, 1)
        XCTAssertNil(result.projection.messages[memberMessage])
        XCTAssertEqual(result.projection.messages[ownerMessage]?.text, "owner announcement")
        XCTAssertFalse(
            result.projection.permissions(for: member, in: channelID).contains(.sendMessages)
        )
        XCTAssertTrue(
            result.projection.permissions(for: owner, in: channelID).contains(.sendMessages)
        )
    }

    func testRoleChannelAllowOverridesEveryoneDenyDeterministically() throws {
        let owner = handle(1)
        let member = handle(2)
        let writer = NoctCordRole(
            id: UUID(),
            name: "Writer",
            position: 10,
            permissions: []
        )
        let messageID = UUID()
        let events = [
            makeEvent(author: owner, clock: 1, operation: .createSpace(name: "Noct Cord")),
            makeEvent(
                author: owner,
                clock: 2,
                operation: .createChannel(id: channelID, name: "writers")
            ),
            makeEvent(author: owner, clock: 3, operation: .defineRole(writer)),
            makeEvent(
                author: owner,
                clock: 4,
                operation: .grantRole(id: writer.id, to: member)
            ),
            makeEvent(
                author: owner,
                clock: 5,
                operation: .setChannelPermissions(
                    channelID: channelID,
                    roleID: nil,
                    allow: [],
                    deny: [.sendMessages]
                )
            ),
            makeEvent(
                author: owner,
                clock: 6,
                operation: .setChannelPermissions(
                    channelID: channelID,
                    roleID: writer.id,
                    allow: [.sendMessages],
                    deny: []
                )
            ),
            makeEvent(
                author: member,
                clock: 7,
                operation: .postMessage(id: messageID, channelID: channelID, text: "draft")
            ),
        ]

        let ordered = project(events, owner: owner, members: [owner, member])
        let shuffled = project(
            [events[6], events[2], events[0], events[4], events[1], events[5], events[3]],
            owner: owner,
            members: [owner, member]
        )

        XCTAssertEqual(ordered, shuffled)
        XCTAssertTrue(ordered.rejectedEvents.isEmpty)
        XCTAssertEqual(ordered.projection.messages[messageID]?.text, "draft")
        XCTAssertEqual(
            try NoctCordCompactCodec.decode(
                NoctCordCompactCodec.encode(events[5])
            ),
            events[5]
        )
    }

    func testRoleHierarchyPreventsPrivilegeAndSelfEscalation() {
        let owner = handle(1)
        let manager = handle(2)
        let moderator = NoctCordRole(
            id: UUID(),
            name: "Moderator",
            position: 20,
            permissions: [.manageRoles]
        )
        let forbidden = NoctCordRole(
            id: UUID(),
            name: "Administrator",
            position: 21,
            permissions: [.manageSpace]
        )
        let helper = NoctCordRole(
            id: UUID(),
            name: "Helper",
            position: 10,
            permissions: [.readMessages]
        )
        let events = [
            makeEvent(author: owner, clock: 1, operation: .createSpace(name: "Noct Cord")),
            makeEvent(author: owner, clock: 2, operation: .defineRole(moderator)),
            makeEvent(
                author: owner,
                clock: 3,
                operation: .grantRole(id: moderator.id, to: manager)
            ),
            makeEvent(author: manager, clock: 4, operation: .defineRole(forbidden)),
            makeEvent(author: manager, clock: 5, operation: .defineRole(helper)),
            makeEvent(
                author: manager,
                clock: 6,
                operation: .grantRole(id: helper.id, to: manager)
            ),
        ]

        let result = project(events, owner: owner, members: [owner, manager])

        XCTAssertEqual(result.rejectedEvents.count, 2)
        XCTAssertNil(result.projection.roles[forbidden.id])
        XCTAssertEqual(result.projection.roles[helper.id], helper)
        XCTAssertFalse(
            result.projection.roleAssignments[manager, default: []].contains(helper.id)
        )
    }

    func testChannelAttachmentAndReactionPermissionsAreEnforced() {
        let owner = handle(1)
        let member = handle(2)
        let messageID = UUID()
        let attachmentID = UUID()
        let events = [
            makeEvent(author: owner, clock: 1, operation: .createSpace(name: "Noct Cord")),
            makeEvent(
                author: owner,
                clock: 2,
                operation: .createChannel(id: channelID, name: "limited")
            ),
            makeEvent(
                author: owner,
                clock: 3,
                operation: .setChannelPermissions(
                    channelID: channelID,
                    roleID: nil,
                    allow: [],
                    deny: [.attachFiles, .addReactions]
                )
            ),
            makeEvent(
                author: owner,
                clock: 4,
                operation: .postMessage(id: messageID, channelID: channelID, text: "policy")
            ),
            makeEvent(
                author: member,
                clock: 5,
                operation: .addReaction("✓", to: messageID)
            ),
            makeEvent(
                author: member,
                clock: 6,
                operation: .addAttachment(
                    id: attachmentID,
                    channelID: channelID,
                    manifest: makeAttachmentManifest(
                        expiresAt: timestamp.addingTimeInterval(3_600)
                    )
                )
            ),
        ]

        let result = project(events, owner: owner, members: [owner, member])

        XCTAssertEqual(result.rejectedEvents.count, 2)
        XCTAssertTrue(result.projection.messages[messageID]?.reactions.isEmpty == true)
        XCTAssertNil(result.projection.attachments[attachmentID])
    }

    func testBotInstallInvocationAndRuntimeResponseUseGroupScopedPrincipals() async throws {
        let owner = handle(1)
        let member = handle(2)
        let botMember = handle(3)
        let bot = NoctCordBotApplication(
            id: UUID(),
            memberHandle: botMember,
            name: "Build Bot",
            commands: [
                NoctCordBotCommand(name: "status", summary: "Show build status"),
            ]
        )
        let invocation = NoctCordBotCommandInvocation(
            id: UUID(),
            botID: bot.id,
            channelID: channelID,
            commandName: "status",
            arguments: "main"
        )
        let invocationEvent = makeEvent(
            author: member,
            clock: 4,
            operation: .invokeBot(invocation)
        )
        let events = [
            makeEvent(author: owner, clock: 1, operation: .createSpace(name: "Noct Cord")),
            makeEvent(
                author: owner,
                clock: 2,
                operation: .createChannel(id: channelID, name: "builds")
            ),
            makeEvent(author: owner, clock: 3, operation: .installBot(bot)),
            invocationEvent,
        ]

        let result = project(
            events,
            owner: owner,
            members: [owner, member, botMember]
        )

        XCTAssertTrue(result.rejectedEvents.isEmpty)
        XCTAssertEqual(result.projection.botApplications[bot.id], bot)
        XCTAssertEqual(result.projection.botInvocations[invocation.id], invocation)
        XCTAssertEqual(result.projection.messages[invocation.id]?.text, "/status main")
        XCTAssertEqual(
            try NoctCordCompactCodec.decode(
                NoctCordCompactCodec.encode(invocationEvent)
            ),
            invocationEvent
        )

        let invocationCounter = BotInvocationCounter()
        let runtime = NoctCordBotRuntime(
            botID: bot.id,
            memberHandleRawValue: botMember.rawValue,
            ledger: NoctCordInMemoryBotInvocationLedger()
        ) { context in
            await invocationCounter.increment()
            return "Build \(context.invocation.arguments) is green."
        }
        let response = try await runtime.prepareResponse(
            for: invocationEvent,
            projection: result.projection
        )
        XCTAssertEqual(response?.requiredAuthorMemberHandle, botMember.rawValue)
        XCTAssertEqual(response?.operation.kind, .messagePosted)
        XCTAssertEqual(response?.operation.replyTo, invocation.id)
        XCTAssertEqual(response?.operation.text, "Build main is green.")
        let duplicateResponse = try await runtime.prepareResponse(
            for: invocationEvent,
            projection: result.projection
        )
        XCTAssertNil(duplicateResponse)
        await runtime.release(invocation.id)
        let retryResponse = try await runtime.prepareResponse(
            for: invocationEvent,
            projection: result.projection
        )
        XCTAssertEqual(retryResponse, response)
        let handlerInvocationCount = await invocationCounter.value
        XCTAssertEqual(handlerInvocationCount, 1)
        try await runtime.markPublished(invocation.id)
        let completedResponse = try await runtime.prepareResponse(
            for: invocationEvent,
            projection: result.projection
        )
        XCTAssertNil(completedResponse)
    }

    func testOrdinaryMemberCannotInstallBotAndChannelCanDenyCommands() {
        let owner = handle(1)
        let member = handle(2)
        let botMember = handle(3)
        let bot = NoctCordBotApplication(
            memberHandle: botMember,
            name: "Utility",
            commands: [
                NoctCordBotCommand(name: "ping", summary: "Check availability"),
            ]
        )
        let invocation = NoctCordBotCommandInvocation(
            botID: bot.id,
            channelID: channelID,
            commandName: "ping"
        )
        let events = [
            makeEvent(author: owner, clock: 1, operation: .createSpace(name: "Noct Cord")),
            makeEvent(
                author: owner,
                clock: 2,
                operation: .createChannel(id: channelID, name: "general")
            ),
            makeEvent(author: member, clock: 3, operation: .installBot(bot)),
            makeEvent(author: owner, clock: 4, operation: .installBot(bot)),
            makeEvent(
                author: owner,
                clock: 5,
                operation: .setChannelPermissions(
                    channelID: channelID,
                    roleID: nil,
                    allow: [],
                    deny: [.useApplicationCommands]
                )
            ),
            makeEvent(author: member, clock: 6, operation: .invokeBot(invocation)),
        ]

        let result = project(
            events,
            owner: owner,
            members: [owner, member, botMember]
        )

        XCTAssertEqual(result.rejectedEvents.count, 2)
        XCTAssertEqual(result.projection.botApplications[bot.id], bot)
        XCTAssertNil(result.projection.botInvocations[invocation.id])
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

    func testVerifiedHistoricalMemberMessageSurvivesDeparture() {
        let owner = handle(1)
        let departed = handle(2)
        let messageID = UUID()
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
                operation: .postMessage(id: messageID, channelID: channelID, text: "preserved")
            ),
        ]

        let result = NoctCordSpaceProjection.project(
            spaceID: spaceID,
            owner: owner,
            activeMembers: [owner],
            historicalMembers: [departed],
            events: events
        )

        XCTAssertTrue(result.rejectedEvents.isEmpty)
        XCTAssertEqual(result.projection.messages[messageID]?.text, "preserved")
        var projection = result.projection
        XCTAssertThrowsError(
            try projection.apply(
                makeEvent(
                    author: departed,
                    clock: 4,
                    operation: .postMessage(id: UUID(), channelID: channelID, text: "blocked")
                )
            )
        )
    }

    func testDeletingRoleRemovesAssignmentsAndChannelOverrides() {
        let owner = handle(1)
        let member = handle(2)
        let role = NoctCordRole(name: "Writer", position: 10, permissions: [])
        let events = [
            makeEvent(author: owner, clock: 1, operation: .createSpace(name: "Noct Cord")),
            makeEvent(
                author: owner,
                clock: 2,
                operation: .createChannel(id: channelID, name: "general")
            ),
            makeEvent(author: owner, clock: 3, operation: .defineRole(role)),
            makeEvent(author: owner, clock: 4, operation: .grantRole(id: role.id, to: member)),
            makeEvent(
                author: owner,
                clock: 5,
                operation: .setChannelPermissions(
                    channelID: channelID,
                    roleID: role.id,
                    allow: [.sendMessages],
                    deny: []
                )
            ),
            makeEvent(author: owner, clock: 6, operation: .deleteRole(id: role.id)),
        ]

        let result = project(events, owner: owner, members: [owner, member])

        XCTAssertTrue(result.rejectedEvents.isEmpty)
        XCTAssertNil(result.projection.roles[role.id])
        XCTAssertFalse(result.projection.roleAssignments[member, default: []].contains(role.id))
        XCTAssertNil(
            result.projection.channels[channelID]?
                .permissionOverrides[.role(role.id)]
        )
    }

    func testBotCommandNamesAreUniqueWithinACommunity() {
        let owner = handle(1)
        let firstBot = NoctCordBotApplication(
            memberHandle: handle(2),
            name: "Build Bot",
            commands: [NoctCordBotCommand(name: "status", summary: "Build status")]
        )
        let secondBot = NoctCordBotApplication(
            memberHandle: handle(3),
            name: "Relay Bot",
            commands: [NoctCordBotCommand(name: "status", summary: "Relay status")]
        )
        let events = [
            makeEvent(author: owner, clock: 1, operation: .createSpace(name: "Noct Cord")),
            makeEvent(author: owner, clock: 2, operation: .installBot(firstBot)),
            makeEvent(author: owner, clock: 3, operation: .installBot(secondBot)),
        ]

        let result = project(events, owner: owner, members: [owner, handle(2), handle(3)])

        XCTAssertEqual(result.rejectedEvents.count, 1)
        XCTAssertEqual(result.projection.botApplications[firstBot.id], firstBot)
        XCTAssertNil(result.projection.botApplications[secondBot.id])
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

private actor BotInvocationCounter {
    private(set) var value = 0

    func increment() {
        value += 1
    }
}
