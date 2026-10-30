import CryptoKit
@testable import NoctCordCore
import NoctweaveCore
import XCTest

final class NoctCordSecureProjectionV2Tests: XCTestCase {
    private let spaceID = UUID(uuidString: "A0000000-0000-0000-0000-000000000001")!
    private let channelID = UUID(uuidString: "A0000000-0000-0000-0000-000000000002")!
    private let owner = GroupScopedMemberHandleV2(
        rawValue: Data(repeating: 0x11, count: 32).base64EncodedString()
    )
    private let member = GroupScopedMemberHandleV2(
        rawValue: Data(repeating: 0x22, count: 32).base64EncodedString()
    )
    private let ownerCredential = GroupScopedCredentialHandleV2(
        rawValue: Data(repeating: 0x31, count: 32).base64EncodedString()
    )
    private let memberCredential = GroupScopedCredentialHandleV2(
        rawValue: Data(repeating: 0x32, count: 32).base64EncodedString()
    )
    private let epochOneTranscript = Data(repeating: 0x41, count: 32)
    private let epochTwoTranscript = Data(repeating: 0x42, count: 32)
    private let ownerInitialPrefix = Data(repeating: 0x51, count: 32)
    private let memberInitialPrefix = Data(repeating: 0x52, count: 32)
    private let date = Date(timeIntervalSince1970: 1_800_000_000)

    func testMessageHistorySurvivesPolicyDeltaAndBackdatedPostDenyMessageFails() throws {
        let genesis = try genesisCheckpoint()
        let messageID = UUID()
        let before = try ordinary(
            author: member, credential: memberCredential, counter: 0,
            previous: memberInitialPrefix, clock: 100,
            operation: .postMessage(id: messageID, channelID: channelID, text: "before")
        )
        let delta = try policyDelta(
            after: genesis,
            memberNextCounter: 1,
            memberPrefix: before.receipt.prefixDigest,
            operation: .setChannelPermissions(
                channelID: channelID, roleID: nil,
                allow: [], deny: [.sendMessages]
            )
        )
        let after = try ordinary(
            author: member, credential: memberCredential, counter: 1,
            previous: before.receipt.prefixDigest, clock: 1,
            operation: .postMessage(id: UUID(), channelID: channelID,
                                    text: "backdated after deny")
        )
        let edit = try ordinary(
            author: owner, credential: ownerCredential, counter: 2,
            previous: delta.receipt.prefixDigest, clock: 2,
            operation: .editMessage(id: messageID, text: "edited")
        )
        let reaction = try ordinary(
            author: member, credential: memberCredential, counter: 2,
            previous: after.receipt.prefixDigest, clock: 3,
            operation: .addReaction("👍", to: messageID)
        )
        let events = [after, delta, edit, before, genesis, reaction]
        let a = try project(events: events, checkpoints: [genesis, delta])
        let b = try project(events: events.reversed(), checkpoints: [delta, genesis])
        XCTAssertEqual(a, b)
        XCTAssertEqual(a.projection.messages[messageID]?.text, "edited")
        XCTAssertEqual(a.projection.messages[messageID]?.reactions["👍"], [member])
        XCTAssertNil(a.projection.messages[after.outer.id])
        XCTAssertTrue(a.rejectedEvents.contains { $0.eventID == after.outer.id })
        XCTAssertEqual(a.acceptedEvents.map(\.id), [
            genesis.outer.id, before.outer.id, delta.outer.id,
            edit.outer.id, reaction.outer.id,
        ])
    }

    func testCompactedPredecessorsDoNotMoveRetainedEventAcrossPolicyCutoff() throws {
        let genesis = try genesisCheckpoint()
        let retained = try ordinary(
            author: member, credential: memberCredential, counter: 99,
            previous: Data(repeating: 0x71, count: 32), clock: 100,
            operation: .postMessage(id: UUID(), channelID: channelID, text: "retained")
        )
        let delta = try policyDelta(
            after: genesis, memberNextCounter: 100,
            memberPrefix: retained.receipt.prefixDigest,
            operation: .setChannelPermissions(
                channelID: channelID, roleID: nil,
                allow: [], deny: [.sendMessages]
            )
        )
        let backdated = try ordinary(
            author: member, credential: memberCredential, counter: 100,
            previous: retained.receipt.prefixDigest, clock: 1,
            operation: .postMessage(id: UUID(), channelID: channelID, text: "too late")
        )
        let result = try project(
            events: [backdated, delta, retained, genesis],
            checkpoints: [genesis, delta]
        )
        XCTAssertEqual(result.projection.messages.count, 1)
        XCTAssertTrue(result.projection.messages.values.contains { $0.text == "retained" })
        XCTAssertEqual(result.rejectedEvents.map(\.eventID), [backdated.outer.id])
    }

    func testDelayedOldIntervalEventIsRejectedAfterCheckpointPrefixRetirement() throws {
        let genesis = try genesisCheckpoint()
        let delayed = try ordinary(
            author: member, credential: memberCredential, counter: 0,
            previous: memberInitialPrefix, clock: 3,
            operation: .postMessage(
                id: UUID(), channelID: channelID, text: "old interval"
            )
        )
        let successor = try checkpoint(
            kind: .snapshot,
            operation: .applyBootstrap(basicConfiguration()),
            previousCheckpointDigest: genesis.secure.canonicalDigest(),
            frontiers: sortedFrontiers([
                frontier(credential: ownerCredential, epoch: 1,
                         next: 1, prefix: genesis.receipt.prefixDigest),
                frontier(credential: memberCredential, epoch: 1,
                         next: 1, prefix: delayed.receipt.prefixDigest),
            ]),
            epoch: 1, transcript: epochOneTranscript,
            counter: 1, previousPrefix: genesis.receipt.prefixDigest,
            clock: 20
        )
        let afterRetirement = try project(
            events: [delayed, successor], checkpoints: [successor],
            allowJoinedSnapshotRoot: true
        )
        XCTAssertEqual(afterRetirement.projection.messages.count, 0)
        XCTAssertEqual(afterRetirement.rejectedEvents.map(\.eventID), [delayed.outer.id])
    }

    func testForkedReceiptOrMissingCoreBindingFailsClosed() throws {
        let genesis = try genesisCheckpoint()
        let before = try ordinary(
            author: member, credential: memberCredential, counter: 0,
            previous: memberInitialPrefix, clock: 12,
            operation: .postMessage(id: UUID(), channelID: channelID, text: "one")
        )
        let delta = try policyDelta(
            after: genesis, memberNextCounter: 1,
            memberPrefix: before.receipt.prefixDigest,
            operation: .setChannelPermissions(
                channelID: channelID, roleID: nil,
                allow: [], deny: [.sendMessages]
            )
        )
        let forged = try ordinary(
            author: member, credential: memberCredential, counter: 0,
            previous: memberInitialPrefix, clock: 13,
            operation: .postMessage(id: UUID(), channelID: channelID, text: "fork")
        )
        XCTAssertThrowsError(try project(
            events: [genesis, before, delta, forged], checkpoints: [genesis, delta]
        )) {
            XCTAssertEqual($0 as? NoctCordSecureProjectionErrorV2, .invalidCheckpoint)
        }
        XCTAssertThrowsError(try project(
            events: [genesis, before, delta], checkpoints: [genesis, delta],
            overrideBinding: [delta.outer.id: []]
        )) {
            XCTAssertEqual($0 as? NoctCordSecureProjectionErrorV2, .invalidCheckpoint)
        }
    }

    func testEpochAdvanceRequiresOwnerRebindingThenPreservesOldContent() throws {
        let genesis = try genesisCheckpoint()
        let before = try ordinary(
            author: member, credential: memberCredential, counter: 0,
            previous: memberInitialPrefix, clock: 12,
            operation: .postMessage(id: UUID(), channelID: channelID, text: "epoch one")
        )
        XCTAssertThrowsError(try project(
            events: [genesis, before], checkpoints: [genesis],
            currentEpoch: 2, currentTranscript: epochTwoTranscript
        )) {
            XCTAssertEqual($0 as? NoctCordSecureProjectionErrorV2, .staleCheckpoint)
        }
        let ownerTwoPrefix = Data(repeating: 0x61, count: 32)
        let memberTwoPrefix = Data(repeating: 0x62, count: 32)
        let beforeRebind = try ordinary(
            author: member, credential: memberCredential, counter: 0,
            previous: memberTwoPrefix, clock: 19,
            operation: .postMessage(id: UUID(), channelID: channelID,
                                    text: "before rebind"),
            epoch: 2, transcript: epochTwoTranscript
        )
        let frontiers = sortedFrontiers([
            frontier(credential: ownerCredential, epoch: 2,
                     next: 0, prefix: ownerTwoPrefix),
            frontier(credential: memberCredential, epoch: 2,
                     next: 1, prefix: beforeRebind.receipt.prefixDigest),
        ])
        let rebind = try checkpoint(
            kind: .delta, operation: .requestBootstrap(),
            previousCheckpointDigest: genesis.secure.canonicalDigest(),
            frontiers: frontiers, epoch: 2, transcript: epochTwoTranscript,
            counter: 0, previousPrefix: ownerTwoPrefix, clock: 20
        )
        let after = try ordinary(
            author: member, credential: memberCredential, counter: 1,
            previous: beforeRebind.receipt.prefixDigest, clock: 21,
            operation: .postMessage(id: UUID(), channelID: channelID, text: "epoch two"),
            epoch: 2, transcript: epochTwoTranscript
        )
        let result = try project(
            events: [after, genesis, before, rebind, beforeRebind],
            checkpoints: [genesis, rebind],
            currentEpoch: 2, currentTranscript: epochTwoTranscript
        )
        XCTAssertEqual(Set(result.projection.messages.values.map(\.text)), [
            "epoch one", "before rebind", "epoch two",
        ])
        XCTAssertTrue(result.rejectedEvents.isEmpty)
    }

    func testOwnerEpochSnapshotRotatesVoiceRouteWithoutDiscardingMessages() throws {
        let roomID = UUID()
        func room(_ byte: UInt8) -> NoctCordVoiceRoomSpecV1 {
            NoctCordVoiceRoomSpecV1(
                name: "voice", maxParticipants: 8,
                signalingKey: Data(repeating: byte, count: 32),
                realtimeRoute: NoctCordRealtimeRouteV1(
                    routeCapability: Data(repeating: byte &+ 1, count: 32),
                    appendCapability: Data(repeating: byte &+ 2, count: 32),
                    readCapability: Data(repeating: byte &+ 3, count: 32),
                    expiresAt: date.addingTimeInterval(3_600)
                )
            )
        }
        var first = basicConfiguration()
        first.append(NoctCordEvent(
            spaceID: spaceID, author: owner, logicalClock: 3,
            createdAt: date.addingTimeInterval(2),
            operation: .createVoiceRoom(id: roomID, spec: room(0x11))
        ))
        let genesis = try genesisCheckpoint(configuration: first)
        let oldMessage = try ordinary(
            author: member, credential: memberCredential, counter: 0,
            previous: memberInitialPrefix, clock: 12,
            operation: .postMessage(id: UUID(), channelID: channelID, text: "old")
        )
        var rotated = basicConfiguration()
        rotated.append(NoctCordEvent(
            spaceID: spaceID, author: owner, logicalClock: 3,
            createdAt: date.addingTimeInterval(2),
            operation: .createVoiceRoom(id: roomID, spec: room(0x21))
        ))
        let ownerTwoPrefix = Data(repeating: 0x61, count: 32)
        let rebind = try checkpoint(
            kind: .snapshot, operation: .applyBootstrap(rotated),
            previousCheckpointDigest: genesis.secure.canonicalDigest(),
            frontiers: sortedFrontiers([
                frontier(credential: ownerCredential, epoch: 2,
                         next: 0, prefix: ownerTwoPrefix),
                frontier(credential: memberCredential, epoch: 2,
                         next: 0, prefix: Data(repeating: 0x62, count: 32)),
            ]), epoch: 2, transcript: epochTwoTranscript,
            counter: 0, previousPrefix: ownerTwoPrefix, clock: 20
        )
        let result = try project(
            events: [genesis, oldMessage, rebind],
            checkpoints: [genesis, rebind],
            currentEpoch: 2, currentTranscript: epochTwoTranscript
        )
        XCTAssertEqual(result.projection.messages.values.map(\.text), ["old"])
        XCTAssertEqual(result.projection.voiceRooms[roomID]?.signalingKey,
                       Data(repeating: 0x21, count: 32))
        XCTAssertEqual(result.projection.voiceRooms[roomID]?.realtimeRoute.readCapability,
                       Data(repeating: 0x24, count: 32))
    }

    func testFragmentedOwnerSnapshotIsAtomicAndRejectsMissingOrInterleavedParts() throws {
        var configuration = basicConfiguration()
        for index in 0..<130 {
            configuration.append(NoctCordEvent(
                spaceID: spaceID, author: owner,
                logicalClock: UInt64(index + 3),
                createdAt: date.addingTimeInterval(TimeInterval(index + 2)),
                operation: .createChannel(id: UUID(), name: "room \(index)")
            ))
        }
        let pieces = [Array(configuration[..<100]), Array(configuration[100...])]
        let fullDigest = try NoctCordSnapshotFragmentV2.fullDigest(of: configuration)
        let seriesID = UUID()
        let seriesSeed = Data(repeating: 0x47, count: 32)
        func fragment(_ index: Int) -> NoctCordSnapshotFragmentV2 {
            NoctCordSnapshotFragmentV2(
                seriesID: seriesID, index: index, count: 2,
                fullConfigurationDigest: fullDigest,
                seriesSeed: seriesSeed
            )
        }
        let first = try checkpoint(
            kind: .snapshot, operation: .applyBootstrap(pieces[0]),
            previousCheckpointDigest: nil,
            frontiers: sortedFrontiers([
                frontier(credential: ownerCredential, epoch: 1,
                         next: 0, prefix: ownerInitialPrefix),
                frontier(credential: memberCredential, epoch: 1,
                         next: 0, prefix: memberInitialPrefix),
            ]), epoch: 1, transcript: epochOneTranscript,
            counter: 0, previousPrefix: ownerInitialPrefix, clock: 10,
            snapshotFragment: fragment(0)
        )
        let second = try checkpoint(
            kind: .snapshot, operation: .applyBootstrap(pieces[1]),
            previousCheckpointDigest: first.secure.canonicalDigest(),
            frontiers: sortedFrontiers([
                frontier(credential: ownerCredential, epoch: 1,
                         next: 1, prefix: first.receipt.prefixDigest),
                frontier(credential: memberCredential, epoch: 1,
                         next: 0, prefix: memberInitialPrefix),
            ]), epoch: 1, transcript: epochOneTranscript,
            counter: 1, previousPrefix: first.receipt.prefixDigest, clock: 11,
            snapshotFragment: fragment(1)
        )
        let accepted = try project(
            events: [second, first], checkpoints: [second, first]
        )
        XCTAssertEqual(accepted.projection.channels.count, 131)
        XCTAssertEqual(accepted.acceptedEvents.count, 2)
        XCTAssertThrowsError(try project(
            events: [first], checkpoints: [first]
        )) {
            XCTAssertEqual($0 as? NoctCordSecureProjectionErrorV2, .missingCheckpoint)
        }
        let middle = try checkpoint(
            kind: .delta, operation: .createChannel(id: UUID(), name: "interleaved"),
            previousCheckpointDigest: first.secure.canonicalDigest(),
            frontiers: sortedFrontiers([
                frontier(credential: ownerCredential, epoch: 1,
                         next: 1, prefix: first.receipt.prefixDigest),
                frontier(credential: memberCredential, epoch: 1,
                         next: 0, prefix: memberInitialPrefix),
            ]), epoch: 1, transcript: epochOneTranscript,
            counter: 1, previousPrefix: first.receipt.prefixDigest, clock: 12
        )
        let lastAfterInterleave = try checkpoint(
            kind: .snapshot, operation: .applyBootstrap(pieces[1]),
            previousCheckpointDigest: middle.secure.canonicalDigest(),
            frontiers: sortedFrontiers([
                frontier(credential: ownerCredential, epoch: 1,
                         next: 2, prefix: middle.receipt.prefixDigest),
                frontier(credential: memberCredential, epoch: 1,
                         next: 0, prefix: memberInitialPrefix),
            ]), epoch: 1, transcript: epochOneTranscript,
            counter: 2, previousPrefix: middle.receipt.prefixDigest, clock: 13,
            snapshotFragment: fragment(1)
        )
        XCTAssertThrowsError(try project(
            events: [first, middle, lastAfterInterleave],
            checkpoints: [first, middle, lastAfterInterleave]
        )) {
            XCTAssertEqual($0 as? NoctCordSecureProjectionErrorV2, .invalidCheckpoint)
        }
    }

    func testRepeatedEpochRebaseSkipsOnlyLinkedIncompleteOldSeries() throws {
        let genesis = try genesisCheckpoint()
        let configuration = basicConfiguration()
        let fullDigest = try NoctCordSnapshotFragmentV2.fullDigest(
            of: configuration
        )
        func piece(_ series: UUID, _ seed: UInt8) -> NoctCordSnapshotFragmentV2 {
            NoctCordSnapshotFragmentV2(
                seriesID: series, index: 0, count: 2,
                fullConfigurationDigest: fullDigest,
                seriesSeed: Data(repeating: seed, count: 32)
            )
        }
        let partialOne = try checkpoint(
            kind: .snapshot,
            operation: .applyBootstrap([configuration[0]]),
            previousCheckpointDigest: genesis.secure.canonicalDigest(),
            frontiers: sortedFrontiers([
                frontier(credential: ownerCredential, epoch: 1,
                         next: 1, prefix: genesis.receipt.prefixDigest),
                frontier(credential: memberCredential, epoch: 1,
                         next: 0, prefix: memberInitialPrefix),
            ]),
            epoch: 1, transcript: epochOneTranscript,
            counter: 1, previousPrefix: genesis.receipt.prefixDigest,
            clock: 11, snapshotFragment: piece(UUID(), 0x71)
        )
        let ownerTwoPrefix = Data(repeating: 0x61, count: 32)
        let rebasedOne = try checkpoint(
            kind: .snapshot, operation: .applyBootstrap(configuration),
            previousCheckpointDigest: partialOne.secure.canonicalDigest(),
            frontiers: sortedFrontiers([
                frontier(credential: ownerCredential, epoch: 2,
                         next: 0, prefix: ownerTwoPrefix),
                frontier(credential: memberCredential, epoch: 2,
                         next: 0, prefix: Data(repeating: 0x62, count: 32)),
            ]),
            epoch: 2, transcript: epochTwoTranscript,
            counter: 0, previousPrefix: ownerTwoPrefix, clock: 20
        )
        let partialTwo = try checkpoint(
            kind: .snapshot,
            operation: .applyBootstrap([configuration[0]]),
            previousCheckpointDigest: rebasedOne.secure.canonicalDigest(),
            frontiers: sortedFrontiers([
                frontier(credential: ownerCredential, epoch: 2,
                         next: 1, prefix: rebasedOne.receipt.prefixDigest),
                frontier(credential: memberCredential, epoch: 2,
                         next: 0, prefix: Data(repeating: 0x62, count: 32)),
            ]),
            epoch: 2, transcript: epochTwoTranscript,
            counter: 1, previousPrefix: rebasedOne.receipt.prefixDigest,
            clock: 21, snapshotFragment: piece(UUID(), 0x72)
        )
        let ownerThreePrefix = Data(repeating: 0x73, count: 32)
        let rebasedTwo = try checkpoint(
            kind: .snapshot, operation: .applyBootstrap(configuration),
            previousCheckpointDigest: partialTwo.secure.canonicalDigest(),
            frontiers: sortedFrontiers([
                frontier(credential: ownerCredential, epoch: 3,
                         next: 0, prefix: ownerThreePrefix),
                frontier(credential: memberCredential, epoch: 3,
                         next: 0, prefix: Data(repeating: 0x74, count: 32)),
            ]),
            epoch: 3, transcript: epochTwoTranscript,
            counter: 0, previousPrefix: ownerThreePrefix, clock: 30
        )
        XCTAssertThrowsError(try project(
            events: [genesis, partialOne, rebasedOne, partialTwo],
            checkpoints: [genesis, partialOne, rebasedOne, partialTwo],
            currentEpoch: 3, currentTranscript: epochTwoTranscript
        )) {
            XCTAssertEqual($0 as? NoctCordSecureProjectionErrorV2,
                           .missingCheckpoint)
        }
        let recovered = try project(
            events: [rebasedTwo, partialTwo, genesis, partialOne, rebasedOne],
            checkpoints: [partialTwo, rebasedOne, genesis, rebasedTwo, partialOne],
            currentEpoch: 3, currentTranscript: epochTwoTranscript
        )
        XCTAssertEqual(recovered.projection.name, "secure")
        XCTAssertEqual(recovered.projection.channels.count, 1)
        XCTAssertEqual(recovered.acceptedEvents.map(\.id), [
            genesis.outer.id, rebasedOne.outer.id, rebasedTwo.outer.id,
        ])
    }

    func testOldPartialEpochEnrollsMemberContentWithoutApplyingPartialPolicy() throws {
        let genesis = try genesisCheckpoint()
        let ownerTwoPrefix = Data(repeating: 0x81, count: 32)
        let memberTwoPrefix = Data(repeating: 0x82, count: 32)
        let partialConfiguration = basicConfiguration()
        let partial = try checkpoint(
            kind: .snapshot,
            operation: .applyBootstrap([partialConfiguration[0]]),
            previousCheckpointDigest: genesis.secure.canonicalDigest(),
            frontiers: sortedFrontiers([
                frontier(credential: ownerCredential, epoch: 2,
                         next: 0, prefix: ownerTwoPrefix),
                frontier(credential: memberCredential, epoch: 2,
                         next: 0, prefix: memberTwoPrefix),
            ]),
            epoch: 2, transcript: epochTwoTranscript,
            counter: 0, previousPrefix: ownerTwoPrefix, clock: 20,
            snapshotFragment: NoctCordSnapshotFragmentV2(
                seriesID: UUID(), index: 0, count: 2,
                fullConfigurationDigest: try NoctCordSnapshotFragmentV2.fullDigest(
                    of: partialConfiguration
                ),
                seriesSeed: Data(repeating: 0x83, count: 32)
            )
        )
        let messageID = UUID()
        let betweenEpochs = try ordinary(
            author: member, credential: memberCredential, counter: 0,
            previous: memberTwoPrefix, clock: 21,
            operation: .postMessage(
                id: messageID, channelID: channelID, text: "between epochs"
            ),
            epoch: 2, transcript: epochTwoTranscript
        )
        let ownerThreePrefix = Data(repeating: 0x84, count: 32)
        let successor = try checkpoint(
            kind: .snapshot,
            operation: .applyBootstrap(partialConfiguration),
            previousCheckpointDigest: partial.secure.canonicalDigest(),
            frontiers: sortedFrontiers([
                frontier(credential: ownerCredential, epoch: 3,
                         next: 0, prefix: ownerThreePrefix),
            ]),
            epoch: 3, transcript: epochTwoTranscript,
            counter: 0, previousPrefix: ownerThreePrefix, clock: 30
        )
        let result = try project(
            events: [successor, betweenEpochs, partial, genesis],
            checkpoints: [genesis, partial, successor],
            currentEpoch: 3, currentTranscript: epochTwoTranscript,
            activeMemberSet: [owner],
            activeCredentialSet: [ownerCredential]
        )
        XCTAssertEqual(result.projection.messages[messageID]?.text,
                       "between epochs")
        XCTAssertFalse(result.acceptedEvents.contains { $0.id == partial.outer.id })
        XCTAssertEqual(result.projection.channels.count, 1)
    }

    func testMissingReceiptUnknownCredentialAndLegacyEventDoNotGainAuthority() throws {
        let genesis = try genesisCheckpoint()
        let memberMessage = try ordinary(
            author: member, credential: memberCredential, counter: 0,
            previous: memberInitialPrefix, clock: 2,
            operation: .postMessage(id: UUID(), channelID: channelID, text: "no receipt")
        )
        let unknownCredential = GroupScopedCredentialHandleV2(
            rawValue: Data(repeating: 0x33, count: 32).base64EncodedString()
        )
        let unknown = try ordinary(
            author: member, credential: unknownCredential, counter: 0,
            previous: Data(repeating: 0x63, count: 32), clock: 3,
            operation: .postMessage(id: UUID(), channelID: channelID, text: "unknown")
        )
        let legacy = NoctCordEvent(
            spaceID: spaceID, author: member, logicalClock: 1,
            createdAt: date, operation: .postMessage(
                id: UUID(), channelID: channelID, text: "legacy backdated"
            )
        )
        let legacyOuter = try NoctCordCodec.wrap(legacy, credential: memberCredential)
        let result = try NoctCordSecureProjectionV2.project(
            spaceID: spaceID, owner: owner, activeMembers: [owner, member],
            activeCredentials: [ownerCredential, memberCredential],
            protectedCheckpoints: [genesis.protected],
            verifiedEvents: [genesis.outer, memberMessage.outer, unknown.outer, legacyOuter],
            receipts: [
                genesis.outer.id: genesis.receipt,
                unknown.outer.id: unknown.receipt,
            ],
            currentEpoch: 1, currentTranscriptHash: epochOneTranscript
        )
        XCTAssertTrue(result.projection.messages.isEmpty)
        XCTAssertEqual(Set(result.rejectedEvents.map(\.eventID)), [
            memberMessage.outer.id, unknown.outer.id, legacyOuter.id,
        ])
    }

    func testPeerMaximumClockCannotBlockLocalV2Publication() throws {
        let genesis = try genesisCheckpoint()
        let hostileClock = try ordinary(
            author: member, credential: memberCredential, counter: 0,
            previous: memberInitialPrefix,
            clock: NoctCordEvent.maximumLogicalClock,
            operation: .postMessage(
                id: UUID(), channelID: channelID, text: "high clock"
            )
        )
        let result = try project(
            events: [hostileClock, genesis], checkpoints: [genesis]
        )
        XCTAssertEqual(result.projection.messages.count, 1)
        XCTAssertEqual(try result.projection.nextLogicalClock(), 3)
    }

    func testSilentFormerRoleRecipientDoesNotBreakPinnedHistoryReplay() throws {
        let silent = GroupScopedMemberHandleV2(
            rawValue: Data(repeating: 0x24, count: 32).base64EncodedString()
        )
        let role = NoctCordRole(
            name: "former member", permissions: [.manageChannels]
        )
        var configuration = basicConfiguration()
        configuration.append(NoctCordEvent(
            spaceID: spaceID, author: owner, logicalClock: 3,
            createdAt: date.addingTimeInterval(2),
            operation: .defineRole(role)
        ))
        let genesis = try genesisCheckpoint(configuration: configuration)
        let grant = try policyDelta(
            after: genesis,
            memberNextCounter: 0,
            memberPrefix: memberInitialPrefix,
            operation: .grantRole(id: role.id, to: silent)
        )
        let ownerTwoPrefix = Data(repeating: 0x61, count: 32)
        let memberTwoPrefix = Data(repeating: 0x62, count: 32)
        let rebind = try checkpoint(
            kind: .delta, operation: .requestBootstrap(),
            previousCheckpointDigest: grant.secure.canonicalDigest(),
            frontiers: sortedFrontiers([
                frontier(credential: ownerCredential, epoch: 2,
                         next: 0, prefix: ownerTwoPrefix),
                frontier(credential: memberCredential, epoch: 2,
                         next: 0, prefix: memberTwoPrefix),
            ]),
            epoch: 2, transcript: epochTwoTranscript,
            counter: 0, previousPrefix: ownerTwoPrefix, clock: 30
        )
        let result = try project(
            events: [grant, rebind, genesis],
            checkpoints: [genesis, grant, rebind],
            currentEpoch: 2, currentTranscript: epochTwoTranscript
        )
        XCTAssertTrue(result.rejectedEvents.isEmpty)
        XCTAssertNil(result.projection.roleAssignments[silent])
        XCTAssertNotNil(result.projection.roles[role.id])
    }

    func testNewCredentialCannotMoveEventBeforeEnrollmentCheckpoint() throws {
        let genesis = try checkpoint(
            kind: .snapshot,
            operation: .applyBootstrap(basicConfiguration()),
            previousCheckpointDigest: nil,
            frontiers: [frontier(
                credential: ownerCredential, epoch: 1,
                next: 0, prefix: ownerInitialPrefix
            )],
            epoch: 1, transcript: epochOneTranscript,
            counter: 0, previousPrefix: ownerInitialPrefix, clock: 10
        )
        let enrollment = try checkpoint(
            kind: .delta,
            operation: .setChannelPermissions(
                channelID: channelID, roleID: nil,
                allow: [], deny: [.sendMessages]
            ),
            previousCheckpointDigest: genesis.secure.canonicalDigest(),
            frontiers: sortedFrontiers([
                frontier(credential: ownerCredential, epoch: 1,
                         next: 1, prefix: genesis.receipt.prefixDigest),
                frontier(credential: memberCredential, epoch: 1,
                         next: 0, prefix: memberInitialPrefix),
            ]),
            epoch: 1, transcript: epochOneTranscript,
            counter: 1, previousPrefix: genesis.receipt.prefixDigest, clock: 20
        )
        let backdated = try ordinary(
            author: member, credential: memberCredential, counter: 0,
            previous: memberInitialPrefix, clock: 1,
            operation: .postMessage(
                id: UUID(), channelID: channelID, text: "cannot predate enrollment"
            )
        )
        let result = try project(
            events: [backdated, genesis, enrollment],
            checkpoints: [genesis, enrollment]
        )
        XCTAssertTrue(result.projection.messages.isEmpty)
        XCTAssertEqual(result.rejectedEvents.map(\.eventID), [backdated.outer.id])
    }

    func testJoinedMemberAnchorsCurrentEpochOwnerSnapshotWithoutOldHistory() throws {
        let genesis = try genesisCheckpoint()
        let oldMessage = try ordinary(
            author: member, credential: memberCredential, counter: 0,
            previous: memberInitialPrefix, clock: 12,
            operation: .postMessage(id: UUID(), channelID: channelID,
                                    text: "before join")
        )
        let ownerTwoPrefix = Data(repeating: 0x61, count: 32)
        let memberTwoPrefix = Data(repeating: 0x62, count: 32)
        let onboarding = try checkpoint(
            kind: .snapshot,
            operation: .applyBootstrap(basicConfiguration()),
            previousCheckpointDigest: genesis.secure.canonicalDigest(),
            frontiers: sortedFrontiers([
                frontier(credential: ownerCredential, epoch: 2,
                         next: 0, prefix: ownerTwoPrefix),
                frontier(credential: memberCredential, epoch: 2,
                         next: 0, prefix: memberTwoPrefix),
            ]),
            epoch: 2, transcript: epochTwoTranscript,
            counter: 0, previousPrefix: ownerTwoPrefix, clock: 20
        )
        let newMessage = try ordinary(
            author: member, credential: memberCredential, counter: 0,
            previous: memberTwoPrefix, clock: 21,
            operation: .postMessage(id: UUID(), channelID: channelID,
                                    text: "after join"),
            epoch: 2, transcript: epochTwoTranscript
        )
        let existing = try project(
            events: [genesis, oldMessage, onboarding, newMessage],
            checkpoints: [genesis, onboarding],
            currentEpoch: 2, currentTranscript: epochTwoTranscript
        )
        XCTAssertEqual(Set(existing.projection.messages.values.map(\.text)), [
            "before join", "after join",
        ])
        XCTAssertThrowsError(try project(
            events: [onboarding, newMessage],
            checkpoints: [onboarding],
            currentEpoch: 2, currentTranscript: epochTwoTranscript
        ))
        let joined = try project(
            events: [newMessage, onboarding],
            checkpoints: [onboarding],
            currentEpoch: 2, currentTranscript: epochTwoTranscript,
            allowJoinedSnapshotRoot: true
        )
        XCTAssertEqual(Set(joined.projection.messages.values.map(\.text)), [
            "after join",
        ])
        XCTAssertTrue(joined.rejectedEvents.isEmpty)
    }

    private typealias Record = (
        outer: GroupConversationEventV2,
        receipt: NoctCordVerifiedTransportReceiptV2,
        secure: NoctCordSecureEventV2,
        protected: NoctCordProtectedCheckpointV2
    )

    private func genesisCheckpoint(
        configuration: [NoctCordEvent]? = nil
    ) throws -> Record {
        try checkpoint(
            kind: .snapshot,
            operation: .applyBootstrap(configuration ?? basicConfiguration()),
            previousCheckpointDigest: nil,
            frontiers: sortedFrontiers([
                frontier(credential: ownerCredential, epoch: 1,
                         next: 0, prefix: ownerInitialPrefix),
                frontier(credential: memberCredential, epoch: 1,
                         next: 0, prefix: memberInitialPrefix),
            ]),
            epoch: 1, transcript: epochOneTranscript,
            counter: 0, previousPrefix: ownerInitialPrefix, clock: 10
        )
    }

    private func policyDelta(
        after prior: Record,
        memberNextCounter: UInt64,
        memberPrefix: Data,
        operation: NoctCordOperation
    ) throws -> Record {
        try checkpoint(
            kind: .delta, operation: operation,
            previousCheckpointDigest: prior.secure.canonicalDigest(),
            frontiers: sortedFrontiers([
                frontier(credential: ownerCredential, epoch: 1,
                         next: prior.receipt.messageCounter + 1,
                         prefix: prior.receipt.prefixDigest),
                frontier(credential: memberCredential, epoch: 1,
                         next: memberNextCounter, prefix: memberPrefix),
            ]),
            epoch: 1, transcript: epochOneTranscript,
            counter: prior.receipt.messageCounter + 1,
            previousPrefix: prior.receipt.prefixDigest, clock: 20
        )
    }

    private func checkpoint(
        kind: NoctCordPolicyCheckpointKindV2,
        operation: NoctCordOperation,
        previousCheckpointDigest: Data?,
        frontiers: [NoctCordCredentialFrontierV2],
        epoch: UInt64,
        transcript: Data,
        counter: UInt64,
        previousPrefix: Data,
        clock: UInt64,
        snapshotFragment: NoctCordSnapshotFragmentV2? = nil
    ) throws -> Record {
        let event = NoctCordEvent(
            spaceID: spaceID, author: owner, logicalClock: clock,
            createdAt: date.addingTimeInterval(TimeInterval(min(clock, 1_000))),
            operation: operation
        )
        let configurationBytes: Data
        switch kind {
        case .snapshot:
            configurationBytes = try NoctweaveCoder.encode(
                operation.bootstrapEvents!, sortedKeys: true
            )
        case .delta:
            configurationBytes = try NoctweaveCoder.encode(operation, sortedKeys: true)
        }
        let policy = NoctCordPolicyCheckpointV2(
            spaceID: spaceID, owner: owner, kind: kind,
            groupEpoch: epoch, groupTranscriptHash: transcript,
            previousCheckpointDigest: previousCheckpointDigest,
            configurationDigest: Data(SHA256.hash(data: configurationBytes)),
            frontiers: frontiers,
            snapshotFragment: snapshotFragment
        )
        let secure = NoctCordSecureEventV2(
            event: event, credential: ownerCredential, checkpoint: policy
        )
        let outer = try NoctCordCodec.wrapSecure(secure)
        let receipt = transportReceipt(
            outer: outer, credential: ownerCredential,
            counter: counter, previous: previousPrefix,
            epoch: epoch, transcript: transcript
        )
        return (outer, receipt, secure,
                NoctCordProtectedCheckpointV2(
                    event: outer, verifiedFrontiers: frontiers
                ))
    }

    private func ordinary(
        author: GroupScopedMemberHandleV2,
        credential: GroupScopedCredentialHandleV2,
        counter: UInt64,
        previous: Data,
        clock: UInt64,
        operation: NoctCordOperation,
        epoch: UInt64 = 1,
        transcript: Data? = nil
    ) throws -> Record {
        let event = NoctCordEvent(
            spaceID: spaceID, author: author, logicalClock: clock,
            createdAt: date.addingTimeInterval(TimeInterval(min(clock, 1_000))),
            operation: operation
        )
        let secure = NoctCordSecureEventV2(event: event, credential: credential)
        let outer = try NoctCordCodec.wrapSecure(secure)
        let receipt = transportReceipt(
            outer: outer, credential: credential, counter: counter,
            previous: previous, epoch: epoch,
            transcript: transcript ?? epochOneTranscript
        )
        return (outer, receipt, secure,
                NoctCordProtectedCheckpointV2(event: outer, verifiedFrontiers: []))
    }

    private func transportReceipt(
        outer: GroupConversationEventV2,
        credential: GroupScopedCredentialHandleV2,
        counter: UInt64,
        previous: Data,
        epoch: UInt64,
        transcript: Data
    ) -> NoctCordVerifiedTransportReceiptV2 {
        let eventDigest = outer.digest!
        let prefixDigest = Data(SHA256.hash(data: previous + eventDigest))
        return NoctCordVerifiedTransportReceiptV2(
            eventID: outer.id, groupID: spaceID, eventDigest: eventDigest,
            epoch: epoch, transcriptHash: transcript, credential: credential,
            messageCounter: counter,
            envelopeDigest: Data(SHA256.hash(data: eventDigest)),
            previousPrefixDigest: previous, prefixDigest: prefixDigest,
            isAccepted: true
        )
    }

    private func basicConfiguration() -> [NoctCordEvent] {
        [
            NoctCordEvent(spaceID: spaceID, author: owner, logicalClock: 1,
                          createdAt: date, operation: .createSpace(name: "secure")),
            NoctCordEvent(spaceID: spaceID, author: owner, logicalClock: 2,
                          createdAt: date.addingTimeInterval(1),
                          operation: .createChannel(id: channelID, name: "general")),
        ]
    }

    private func frontier(
        credential: GroupScopedCredentialHandleV2,
        epoch: UInt64,
        next: UInt64,
        prefix: Data
    ) -> NoctCordCredentialFrontierV2 {
        NoctCordCredentialFrontierV2(
            epoch: epoch,
            transcriptHash: epoch == 1 ? epochOneTranscript : epochTwoTranscript,
            credential: credential,
            nextCounter: next,
            prefixDigest: prefix
        )
    }

    private func sortedFrontiers(
        _ values: [NoctCordCredentialFrontierV2]
    ) -> [NoctCordCredentialFrontierV2] {
        values.sorted(by: NoctCordPolicyCheckpointV2.frontierOrder)
    }

    private func project(
        events: [Record],
        checkpoints: [Record],
        overrideBinding: [UUID: [NoctCordCredentialFrontierV2]] = [:],
        currentEpoch: UInt64 = 1,
        currentTranscript: Data? = nil,
        allowJoinedSnapshotRoot: Bool = false,
        activeMemberSet: Set<GroupScopedMemberHandleV2>? = nil,
        activeCredentialSet: Set<GroupScopedCredentialHandleV2>? = nil
    ) throws -> NoctCordProjectionResult {
        try NoctCordSecureProjectionV2.project(
            spaceID: spaceID, owner: owner,
            activeMembers: activeMemberSet ?? [owner, member],
            activeCredentials: activeCredentialSet ?? [ownerCredential, memberCredential],
            protectedCheckpoints: checkpoints.map {
                NoctCordProtectedCheckpointV2(
                    event: $0.outer,
                    verifiedFrontiers: overrideBinding[$0.outer.id]
                        ?? $0.protected.verifiedFrontiers
                )
            },
            verifiedEvents: events.map(\.outer),
            receipts: Dictionary(uniqueKeysWithValues: events.map {
                ($0.outer.id, $0.receipt)
            }),
            currentEpoch: currentEpoch,
            currentTranscriptHash: currentTranscript ?? epochOneTranscript,
            allowJoinedSnapshotRoot: allowJoinedSnapshotRoot
        )
    }
}
