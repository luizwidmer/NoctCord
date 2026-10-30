import Foundation
import CryptoKit
import NoctCordCore
import NoctCordMedia
@testable import NoctCordUI
@preconcurrency import NoctweaveCore
import XCTest

final class NoctCordTransportIntegrationTests: XCTestCase {
    #if NOCTCORD_VERIFIED_CORE
    func testEpochVoiceRotationDerivesStableDistinctCredentials() throws {
        let spaceID = UUID()
        let roomID = UUID()
        let author = GroupScopedMemberHandleV2.generate()
        let existing = NoctCordRealtimeRouteV1(
            routeCapability: Data(repeating: 0x11, count: 32),
            appendCapability: Data(repeating: 0x12, count: 32),
            readCapability: Data(repeating: 0x13, count: 32),
            expiresAt: Date().addingTimeInterval(3600)
        )
        let event = NoctCordEvent(
            spaceID: spaceID, author: author, logicalClock: 1,
            operation: .createVoiceRoom(
                id: roomID,
                spec: NoctCordVoiceRoomSpecV1(
                    name: "call", signalingKey: Data(repeating: 0x14, count: 32),
                    realtimeRoute: existing
                )
            )
        )
        let seed = Data(repeating: 0x42, count: 32)
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let first = try NoctCordTransportCoordinator.rotateVoiceRoutesForEpochRebind(
            [event], spaceID: spaceID, epoch: 2, seed: seed, at: date
        )
        let resumed = try NoctCordTransportCoordinator.rotateVoiceRoutesForEpochRebind(
            [event], spaceID: spaceID, epoch: 2, seed: seed, at: date
        )
        let nextEpoch = try NoctCordTransportCoordinator.rotateVoiceRoutesForEpochRebind(
            [event], spaceID: spaceID, epoch: 3, seed: seed, at: date
        )
        XCTAssertEqual(first.events, resumed.events)
        XCTAssertEqual(first.routes, resumed.routes)
        XCTAssertNotEqual(first.events, nextEpoch.events)
        XCTAssertEqual(first.events[0].id, event.id)
        XCTAssertNotEqual(
            first.events[0].operation.voiceRoomSpec?.signalingKey,
            event.operation.voiceRoomSpec?.signalingKey
        )
        XCTAssertNotEqual(first.routes[0].routeCapability, existing.routeCapability)
        XCTAssertTrue(first.routes[0].isStructurallyValid)
    }

    func testOwnerReviewedLegacyMigrationKeepsOldContentReadOnly() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "noctcord-verified-migration-\(UUID().uuidString)", isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let server = RelayServer(store: RelayStore(), opaqueRouteStore: OpaqueRouteRelayStoreV2())
        let endpoint = try await startOnEphemeralLoopbackPort(server)
        defer { server.stop() }
        let owner = try await makeClient(name: "migration-owner", root: root)
        let transport = try NoctCordTransportCoordinator(client: owner, relay: endpoint)
        let groupID = UUID()
        let channelID = UUID()
        let historicalMessageID = UUID()
        _ = try await owner.createGroup(
            groupID: groupID,
            relay: endpoint,
            contentTypes: NoctCordCodec.contentCapabilities
        )
        let state = await (try await owner.openGroupRuntime(groupID: groupID)).snapshot()
        let ownerHandle = state.localCredential.memberHandle
        var oldEvents = [
            NoctCordEvent(
                spaceID: groupID, author: ownerHandle, logicalClock: 1,
                operation: .createSpace(name: "old room")
            ),
            NoctCordEvent(
                spaceID: groupID, author: ownerHandle, logicalClock: 2,
                operation: .createChannel(id: channelID, name: "general")
            ),
            NoctCordEvent(
                spaceID: groupID, author: ownerHandle, logicalClock: 3,
                operation: .postMessage(
                    id: historicalMessageID, channelID: channelID,
                    text: "historical only"
                )
            ),
        ]
        let extraConfiguration = (0..<130).map { index in
            NoctCordEvent(
                spaceID: groupID, author: ownerHandle,
                logicalClock: UInt64(index + 4),
                operation: .createChannel(
                    id: UUID(), name: "legacy channel \(index)"
                )
            )
        }
        oldEvents.append(NoctCordEvent(
            spaceID: groupID, author: ownerHandle, logicalClock: 4,
            operation: .applyBootstrap(Array(extraConfiguration[..<65]))
        ))
        oldEvents.append(NoctCordEvent(
            spaceID: groupID, author: ownerHandle, logicalClock: 5,
            operation: .applyBootstrap(Array(extraConfiguration[65...]))
        ))
        for event in oldEvents {
            let outer = try NoctCordCodec.wrap(
                event, credential: state.localCredential.credentialHandle
            )
            let prepared = try await owner.prepareGroupApplication(
                outer, at: event.createdAt
            )
            if let operation = prepared.transportOperation {
                let sent = try await owner.resumeGroupTransport(
                    groupID: groupID, operationID: operation.id,
                    at: event.createdAt
                )
                XCTAssertTrue(sent.complete)
            }
        }
        let before = try await transport.storedSpaceSnapshot(spaceID: groupID)
        XCTAssertEqual(before.policyMode, .legacyReadOnly)
        let oldRuntime = try await owner.openGroupRuntime(groupID: groupID)
        let oldSnapshot = await oldRuntime.snapshot()
        XCTAssertThrowsError(try NoctCordSecureProjectionV2.project(
            verified: oldSnapshot
        ))
        let reviewed = try await transport.proposedLegacyConfigurationForReview(
            spaceID: groupID
        )
        XCTAssertEqual(reviewed.count, 132)
        let chunks = try NoctCordTransportCoordinator.plannedSnapshotChunks(
            reviewed, snapshot: oldSnapshot
        )
        XCTAssertGreaterThan(chunks.count, 1)
        let epoch = try await owner.prepareGroupEpoch(
            groupID: groupID,
            operation: .updateMetadata,
            proposedMembers: oldSnapshot.signedState.members,
            proposedCredentials: oldSnapshot.signedState.memberCredentials,
            proposedPermissions: oldSnapshot.signedState.permissions,
            proposedMetadataDigest: Data(SHA256.hash(data: Data("test-migration-epoch".utf8))),
            idempotencyKey: Data(SHA256.hash(data: Data("test-migration-idempotency".utf8))),
            createdAt: Date()
        )
        if let operation = epoch.transportOperation {
            let sent = try await owner.resumeGroupTransport(
                groupID: groupID, operationID: operation.id
            )
            XCTAssertTrue(sent.complete)
        }
        let verifiedEpoch = await (try await owner.openGroupRuntime(groupID: groupID)).snapshot()
        let oldFrontiers = try XCTUnwrap(verifiedEpoch.currentVerificationFrontiers())
        let seed = Data(repeating: 0x43, count: 32)
        let initialPart = NoctCordEvent(
            spaceID: groupID, author: ownerHandle, logicalClock: 134,
            operation: .applyBootstrap(chunks[0])
        )
        let firstPolicy = NoctCordPolicyCheckpointV2(
            spaceID: groupID, owner: ownerHandle,
            groupEpoch: verifiedEpoch.signedState.epoch,
            groupTranscriptHash: verifiedEpoch.signedState.confirmedTranscriptHash,
            previousCheckpointDigest: nil,
            configurationDigest: Data(SHA256.hash(data: try NoctweaveCoder.encode(
                chunks[0], sortedKeys: true
            ))),
            frontiers: oldFrontiers.map(NoctCordCredentialFrontierV2.init),
            snapshotFragment: NoctCordSnapshotFragmentV2(
                seriesID: UUID(), index: 0, count: chunks.count,
                fullConfigurationDigest: try NoctCordSnapshotFragmentV2.fullDigest(
                    of: reviewed
                ),
                seriesSeed: seed
            )
        )
        let firstOuter = try NoctCordCodec.wrapSecure(NoctCordSecureEventV2(
            event: initialPart,
            credential: verifiedEpoch.localCredential.credentialHandle,
            checkpoint: firstPolicy
        ))
        let firstPrepared = try await owner.prepareGroupApplication(
            firstOuter, at: initialPart.createdAt
        )
        if let operation = firstPrepared.transportOperation {
            let sent = try await owner.resumeGroupTransport(
                groupID: groupID, operationID: operation.id,
                at: initialPart.createdAt
            )
            XCTAssertTrue(sent.complete)
        }
        let firstRuntime = try await owner.openGroupRuntime(groupID: groupID)
        try await firstRuntime.replaceProtectedApplicationEvent(
            previousEventID: nil, with: firstOuter.id,
            verificationFrontiers: oldFrontiers
        )
        let incompleteSnapshot = await firstRuntime.snapshot()
        XCTAssertThrowsError(try NoctCordSecureProjectionV2.project(
            verified: incompleteSnapshot
        ))
        // Reopen from disk after the first signed fragment: the reviewed
        // configuration must reconstruct the same remaining series.
        let reopened = try await makeClient(name: "migration-owner", root: root)
        let resumedTransport = try NoctCordTransportCoordinator(
            client: reopened, relay: endpoint
        )
        let migrated = try await resumedTransport.migrateCommunityToVerifiedPolicy(
            spaceID: groupID, approvedConfiguration: reviewed
        )
        XCTAssertTrue(migrated.complete)
        let after = try await resumedTransport.storedSpaceSnapshot(spaceID: groupID)
        XCTAssertEqual(after.policyMode, .verified)
        XCTAssertEqual(after.verifiedProjection?.projection.name, "old room")
        XCTAssertTrue(after.legacyArchiveEvents.contains(where: {
            $0.id == oldEvents[2].id
        }))
        XCTAssertNil(after.verifiedProjection?.projection.messages[historicalMessageID])
        let posted = try await resumedTransport.publishOperation(
            spaceID: groupID,
            operation: .postMessage(
                id: UUID(), channelID: channelID, text: "new verified"
            )
        )
        XCTAssertTrue(posted.complete)
    }

    func testReceiverAtomicallyReplacesCompleteSnapshotAtPinBudget() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "noctcord-pin-budget-\(UUID().uuidString)", isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let server = RelayServer(store: RelayStore(), opaqueRouteStore: OpaqueRouteRelayStoreV2())
        let endpoint = try await startOnEphemeralLoopbackPort(server)
        defer { server.stop() }
        let owner = try await makeClient(name: "pin-owner", root: root)
        let member = try await makeClient(name: "pin-member", root: root)
        let ownerTransport = try NoctCordTransportCoordinator(client: owner, relay: endpoint)
        let memberTransport = try NoctCordTransportCoordinator(client: member, relay: endpoint)
        mark("pin-budget-before-create")
        let created = try await ownerTransport.createSpace(name: "pin budget")
        mark("pin-budget-after-create")
        let invitation = try await ownerTransport.makeCommunityInvitation(
            spaceID: created.spaceID, spaceName: "pin budget"
        )
        let request = try await memberTransport.prepareCommunityAdmission(
            invitation: invitation
        )
        let response = try await ownerTransport.approveCommunityAdmissionRequest(
            request.requestCode, for: created.spaceID
        )
        mark("pin-budget-after-approval")
        _ = try await memberTransport.acceptCommunityAdmissionResponse(response)
        mark("pin-budget-after-accept")
        _ = try? await ownerTransport.synchronize(spaceID: created.spaceID)
        _ = try await ownerTransport.ensureCommunityBootstrap(spaceID: created.spaceID)
        mark("pin-budget-after-owner-snapshot")
        _ = try await memberTransport.synchronize(spaceID: created.spaceID)
        let roomID = UUID()
        let route = try await ownerTransport.createRealtimeRoute(for: created.spaceID)
        _ = try await ownerTransport.publishOperation(
            spaceID: created.spaceID,
            operation: .createVoiceRoom(
                id: roomID,
                spec: NoctCordVoiceRoomSpecV1(
                    name: "call", signalingKey: Data(repeating: 0x51, count: 32),
                    realtimeRoute: route
                )
            )
        )
        _ = try await memberTransport.synchronize(spaceID: created.spaceID)
        let before = await (try await member.openGroupRuntime(
            groupID: created.spaceID
        )).snapshot()
        XCTAssertGreaterThanOrEqual(before.protectedApplicationEventIDs.count, 2)
        let rebound = try await ownerTransport.rebindVerifiedCommunityAfterUpgrade(
            spaceID: created.spaceID
        )
        XCTAssertTrue(rebound)
        _ = try await member.syncGroup(groupID: created.spaceID)
        let memberRuntime = try await member.openGroupRuntime(groupID: created.spaceID)
        let unpinned = await memberRuntime.snapshot()
        let newParts = unpinned.events.filter { outer in
            guard let secure = try? NoctCordCodec.unwrapSecure(outer),
                  let fragment = secure.checkpoint?.snapshotFragment else {
                return false
            }
            return fragment.count == 2
                && !unpinned.protectedApplicationEventIDs.contains(outer.id)
        }
        XCTAssertEqual(newParts.count, 2)
        try await memberTransport.pinReceivedCheckpoints(
            unpinned.events, runtime: memberRuntime,
            capacityLimit: before.protectedApplicationEventIDs.count
        )
        let after = await memberRuntime.snapshot()
        XCTAssertEqual(after.protectedApplicationEventIDs.count, 2)
        XCTAssertTrue(Set(before.protectedApplicationEventIDs).isSubset(
            of: Set(after.retiredProtectedApplicationEventIDs)
        ))
        XCTAssertEqual(
            try NoctCordSecureProjectionV2.project(verified: after)
                .projection.voiceRooms[roomID]?.name,
            "call"
        )

        // Keep a third member through the next epoch so they can receive an
        // old partial fragment without an application pin, restart, and then
        // authenticate its linked successor. The departing member cannot
        // serve as that receiver after self-leave.
        let observer = try await makeClient(name: "pin-observer", root: root)
        let observerTransport = try NoctCordTransportCoordinator(
            client: observer, relay: endpoint
        )
        let observerInvitation = try await ownerTransport.makeCommunityInvitation(
            spaceID: created.spaceID, spaceName: "pin budget"
        )
        let observerRequest = try await observerTransport.prepareCommunityAdmission(
            invitation: observerInvitation
        )
        let observerResponse = try await ownerTransport.approveCommunityAdmissionRequest(
            observerRequest.requestCode, for: created.spaceID
        )
        _ = try await observerTransport.acceptCommunityAdmissionResponse(
            observerResponse
        )
        _ = try? await ownerTransport.synchronize(spaceID: created.spaceID)
        _ = try await ownerTransport.ensureCommunityBootstrap(spaceID: created.spaceID)
        _ = try await memberTransport.synchronize(spaceID: created.spaceID)
        _ = try await observerTransport.synchronize(spaceID: created.spaceID)

        let ownerBeforeLeave = await (try await owner.openGroupRuntime(
            groupID: created.spaceID
        )).snapshot()
        let currentPolicy = try NoctCordSecureProjectionV2.project(
            verified: ownerBeforeLeave
        ).projection
        let fullConfiguration = try currentPolicy.checkpointConfiguration(
            createdAt: Date()
        )
        XCTAssertGreaterThan(fullConfiguration.count, 1)
        let ownerPinned = Set(ownerBeforeLeave.protectedApplicationEventIDs)
        let priorOuter = try XCTUnwrap(ownerBeforeLeave.events.last(where: {
            ownerPinned.contains($0.id)
                && (try? NoctCordCodec.unwrapSecure($0).checkpoint) != nil
        }))
        let priorDigest = try NoctCordCodec.unwrapSecure(priorOuter)
            .canonicalDigest()
        let firstPiece = [fullConfiguration[0]]
        let partialEvent = NoctCordEvent(
            spaceID: created.spaceID,
            author: ownerBeforeLeave.localCredential.memberHandle,
            logicalClock: 1,
            operation: .applyBootstrap(firstPiece)
        )
        let partialCheckpoint = NoctCordPolicyCheckpointV2(
            spaceID: created.spaceID,
            owner: ownerBeforeLeave.localCredential.memberHandle,
            groupEpoch: ownerBeforeLeave.signedState.epoch,
            groupTranscriptHash: ownerBeforeLeave.signedState.confirmedTranscriptHash,
            previousCheckpointDigest: priorDigest,
            configurationDigest: Data(SHA256.hash(data: try NoctweaveCoder.encode(
                firstPiece, sortedKeys: true
            ))),
            frontiers: try XCTUnwrap(
                ownerBeforeLeave.currentVerificationFrontiers()
            ).map(NoctCordCredentialFrontierV2.init),
            snapshotFragment: NoctCordSnapshotFragmentV2(
                seriesID: UUID(), index: 0, count: 2,
                fullConfigurationDigest: try NoctCordSnapshotFragmentV2.fullDigest(
                    of: fullConfiguration
                ),
                seriesSeed: Data(repeating: 0x66, count: 32)
            )
        )
        let partialOuter = try NoctCordCodec.wrapSecure(NoctCordSecureEventV2(
            event: partialEvent,
            credential: ownerBeforeLeave.localCredential.credentialHandle,
            checkpoint: partialCheckpoint
        ))
        let preparedPartial = try await owner.prepareGroupApplication(
            partialOuter, at: partialEvent.createdAt
        )
        if let operation = preparedPartial.transportOperation {
            let sent = try await owner.resumeGroupTransport(
                groupID: created.spaceID, operationID: operation.id,
                at: partialEvent.createdAt
            )
            XCTAssertTrue(sent.complete)
        }
        let ownerPartialRuntime = try await owner.openGroupRuntime(
            groupID: created.spaceID
        )
        try await ownerPartialRuntime.replaceProtectedApplicationEvent(
            previousEventID: nil, with: partialOuter.id,
            verificationFrontiers: try XCTUnwrap(
                ownerBeforeLeave.currentVerificationFrontiers()
            )
        )
        let messageChannel = try XCTUnwrap(currentPolicy.channels.keys.first)
        let messageID = UUID()
        let betweenEpochs = try await memberTransport.publishOperation(
            spaceID: created.spaceID,
            operation: .postMessage(
                id: messageID, channelID: messageChannel,
                text: "during interrupted snapshot"
            )
        )
        XCTAssertTrue(betweenEpochs.complete)
        _ = try await observer.syncGroup(groupID: created.spaceID)
        let observerBeforeRestart = await (try await observer.openGroupRuntime(
            groupID: created.spaceID
        )).snapshot()
        XCTAssertTrue(observerBeforeRestart.events.contains(where: {
            $0.id == partialOuter.id
        }))
        XCTAssertFalse(observerBeforeRestart.protectedApplicationEventIDs.contains(
            partialOuter.id
        ))
        _ = try await owner.syncGroup(groupID: created.spaceID)
        let left = try await memberTransport.leaveCommunity(
            spaceID: created.spaceID
        )
        XCTAssertTrue(left.complete)
        _ = try await owner.syncGroup(groupID: created.spaceID)
        let interrupted = await (try await owner.openGroupRuntime(
            groupID: created.spaceID
        )).snapshot()
        XCTAssertGreaterThan(
            interrupted.signedState.epoch,
            ownerBeforeLeave.signedState.epoch
        )
        XCTAssertThrowsError(try NoctCordSecureProjectionV2.project(
            verified: interrupted
        ))
        let recoveredPolicy = try await ownerTransport.ensureCommunityBootstrap(
            spaceID: created.spaceID
        )
        XCTAssertTrue(recoveredPolicy)
        let recoveredAfterLeave = try await ownerTransport.storedSpaceSnapshot(
            spaceID: created.spaceID
        )
        XCTAssertEqual(recoveredAfterLeave.policyMode, .verified)
        XCTAssertFalse(recoveredAfterLeave.verifiedProjection?.acceptedEvents
            .contains(where: { $0.id == partialEvent.id }) ?? true)
        XCTAssertEqual(
            recoveredAfterLeave.verifiedProjection?.projection.voiceRooms[roomID]?.name,
            "call"
        )
        XCTAssertNotNil(
            recoveredAfterLeave.verifiedProjection?.projection.messages[messageID]
        )

        let restartedObserver = try await makeClient(
            name: "pin-observer", root: root
        )
        let restartedTransport = try NoctCordTransportCoordinator(
            client: restartedObserver, relay: endpoint
        )
        _ = try await restartedObserver.syncGroup(groupID: created.spaceID)
        let restartedRuntime = try await restartedObserver.openGroupRuntime(
            groupID: created.spaceID
        )
        let observerUnpinned = await restartedRuntime.snapshot()
        XCTAssertFalse(observerUnpinned.protectedApplicationEventIDs.contains(
            partialOuter.id
        ))
        try await restartedTransport.pinReceivedCheckpoints(
            observerUnpinned.events, runtime: restartedRuntime
        )
        let observedAfterRebase = try await restartedTransport.storedSpaceSnapshot(
            spaceID: created.spaceID
        )
        XCTAssertEqual(observedAfterRebase.policyMode, .verified)
        XCTAssertTrue(observedAfterRebase.verifiedProjection?.acceptedEvents
            .contains(where: { $0.id == betweenEpochs.event.id }) == true)
        XCTAssertNotNil(observedAfterRebase.verifiedProjection?.projection.messages[messageID])
        XCTAssertFalse(observedAfterRebase.verifiedProjection?.acceptedEvents
            .contains(where: { $0.id == partialEvent.id }) ?? true)
        let observerPinned = await restartedRuntime.snapshot()
        XCTAssertTrue(observerPinned.protectedApplicationEventIDs.contains(
            partialOuter.id
        ))
    }

    func testVerifiedLateJoinReceivesOwnerSnapshotAfterPriorPolicyDelta() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "noctcord-verified-join-\(UUID().uuidString)", isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let server = RelayServer(store: RelayStore(), opaqueRouteStore: OpaqueRouteRelayStoreV2())
        let endpoint = try await startOnEphemeralLoopbackPort(server)
        defer { server.stop() }

        let owner = try await makeClient(name: "verified-owner", root: root)
        let member = try await makeClient(name: "verified-member", root: root)
        let ownerTransport = try NoctCordTransportCoordinator(client: owner, relay: endpoint)
        let memberTransport = try NoctCordTransportCoordinator(client: member, relay: endpoint)
        mark("verified-join-before-create")
        let created = try await ownerTransport.createSpace(name: "Verified room")
        mark("verified-join-after-create")
        let ownerInitial = try await ownerTransport.storedSpaceSnapshot(spaceID: created.spaceID)
        XCTAssertEqual(ownerInitial.policyMode, .verified)
        let priorChannel = UUID()
        let priorChange = try await ownerTransport.publishOperation(
            spaceID: created.spaceID,
            operation: .createChannel(id: priorChannel, name: "before join")
        )
        mark("verified-join-after-prior-delta")
        XCTAssertTrue(priorChange.complete)
        let voiceRoomID = UUID()
        let originalVoiceRoute = try await ownerTransport.createRealtimeRoute(
            for: created.spaceID
        )
        let voiceCreated = try await ownerTransport.publishOperation(
            spaceID: created.spaceID,
            operation: .createVoiceRoom(
                id: voiceRoomID,
                spec: NoctCordVoiceRoomSpecV1(
                    name: "call", maxParticipants: 8,
                    signalingKey: Data(repeating: 0x51, count: 32),
                    realtimeRoute: originalVoiceRoute
                )
            )
        )
        XCTAssertTrue(voiceCreated.complete)

        let invitation = try await ownerTransport.makeCommunityInvitation(
            spaceID: created.spaceID, spaceName: "Verified room"
        )
        let request = try await memberTransport.prepareCommunityAdmission(invitation: invitation)
        let response = try await ownerTransport.approveCommunityAdmissionRequest(
            request.requestCode, for: created.spaceID
        )
        mark("verified-join-after-approval")
        let joinedID = try await memberTransport.acceptCommunityAdmissionResponse(response)
        mark("verified-join-after-accept")
        XCTAssertEqual(joinedID, created.spaceID)
        _ = try? await ownerTransport.synchronize(spaceID: created.spaceID)
        _ = try await ownerTransport.ensureCommunityBootstrap(spaceID: created.spaceID)
        mark("verified-join-after-owner-snapshot")
        let ownerAfterJoinSnapshot = await (try await owner.openGroupRuntime(
            groupID: created.spaceID
        )).snapshot()
        XCTAssertGreaterThanOrEqual(
            ownerAfterJoinSnapshot.protectedApplicationEventIDs.count, 1
        )
        _ = try await memberTransport.synchronize(spaceID: created.spaceID)
        let memberSnapshot = try await memberTransport.storedSpaceSnapshot(
            spaceID: created.spaceID
        )
        XCTAssertEqual(memberSnapshot.policyMode, .verified)
        XCTAssertNotNil(memberSnapshot.verifiedProjection?.projection.channels[priorChannel])
        XCTAssertNotEqual(
            memberSnapshot.verifiedProjection?.projection.voiceRooms[voiceRoomID]?
                .realtimeRoute.readCapability,
            originalVoiceRoute.readCapability
        )

        let postedMessageID = UUID()
        let posted = try await memberTransport.publishOperation(
            spaceID: created.spaceID,
            operation: .postMessage(
                id: postedMessageID, channelID: priorChannel, text: "after join"
            )
        )
        XCTAssertTrue(posted.complete)
        let memberHandle = (await (try await member.openGroupRuntime(
            groupID: created.spaceID
        )).snapshot()).localCredential.memberHandle
        let moderatorRole = NoctCordRole(
            name: "message moderator", position: 1,
            permissions: [.manageMessages]
        )
        _ = try await ownerTransport.publishOperation(
            spaceID: created.spaceID,
            operation: .defineRole(moderatorRole)
        )
        _ = try await ownerTransport.publishOperation(
            spaceID: created.spaceID,
            operation: .grantRole(id: moderatorRole.id, to: memberHandle)
        )
        _ = try await memberTransport.synchronize(spaceID: created.spaceID)
        let legitimatePin = try await memberTransport.publishOperation(
            spaceID: created.spaceID,
            operation: .pinMessage(id: postedMessageID)
        )
        XCTAssertTrue(legitimatePin.complete)
        _ = try await ownerTransport.synchronize(spaceID: created.spaceID)
        mark("verified-join-after-legitimate-member-pin")
        _ = try await ownerTransport.publishOperation(
            spaceID: created.spaceID,
            operation: .revokeRole(id: moderatorRole.id, from: memberHandle)
        )
        let staleMember = await (try await member.openGroupRuntime(
            groupID: created.spaceID
        )).snapshot()
        let backdatedUnpin = NoctCordEvent(
            spaceID: created.spaceID,
            author: memberHandle,
            logicalClock: 1,
            operation: .unpinMessage(id: postedMessageID)
        )
        let adversarialOuter = try NoctCordCodec.wrapSecure(
            NoctCordSecureEventV2(
                event: backdatedUnpin,
                credential: staleMember.localCredential.credentialHandle
            )
        )
        let adversarialPrepared = try await member.prepareGroupApplication(
            adversarialOuter, at: backdatedUnpin.createdAt
        )
        if let transport = adversarialPrepared.transportOperation {
            let sent = try await member.resumeGroupTransport(
                groupID: created.spaceID, operationID: transport.id,
                at: backdatedUnpin.createdAt
            )
            XCTAssertTrue(sent.complete)
        }
        let memberRuntime = try await member.openGroupRuntime(groupID: created.spaceID)
        let memberState = await memberRuntime.snapshot()
        let legacyAfterCutoff = NoctCordEvent(
            spaceID: created.spaceID,
            author: memberState.localCredential.memberHandle,
            logicalClock: 1,
            operation: .postMessage(
                id: UUID(), channelID: priorChannel, text: "forged archive"
            )
        )
        let oldClientOuter = try NoctCordCodec.wrap(
            legacyAfterCutoff,
            credential: memberState.localCredential.credentialHandle
        )
        let oldClientPrepared = try await member.prepareGroupApplication(
            oldClientOuter, at: legacyAfterCutoff.createdAt
        )
        if let transport = oldClientPrepared.transportOperation {
            let sent = try await member.resumeGroupTransport(
                groupID: created.spaceID, operationID: transport.id,
                at: legacyAfterCutoff.createdAt
            )
            XCTAssertTrue(sent.complete)
        }
        let freshMemberState = await (try await member.openGroupRuntime(
            groupID: created.spaceID
        )).snapshot()
        let poisonNested = NoctCordEvent(
            spaceID: created.spaceID,
            author: freshMemberState.localCredential.memberHandle,
            logicalClock: 1,
            operation: .createSpace(name: "forged owner policy")
        )
        let poisonConfiguration = [poisonNested]
        let poisonEvent = NoctCordEvent(
            spaceID: created.spaceID,
            author: freshMemberState.localCredential.memberHandle,
            logicalClock: 2,
            operation: .applyBootstrap(poisonConfiguration)
        )
        let poisonPolicy = NoctCordPolicyCheckpointV2(
            spaceID: created.spaceID,
            owner: freshMemberState.localCredential.memberHandle,
            groupEpoch: freshMemberState.signedState.epoch,
            groupTranscriptHash: freshMemberState.signedState.confirmedTranscriptHash,
            previousCheckpointDigest: nil,
            configurationDigest: Data(SHA256.hash(data: try NoctweaveCoder.encode(
                poisonConfiguration, sortedKeys: true
            ))),
            frontiers: try XCTUnwrap(
                freshMemberState.currentVerificationFrontiers()
            ).map(NoctCordCredentialFrontierV2.init)
        )
        let poisonOuter = try NoctCordCodec.wrapSecure(NoctCordSecureEventV2(
            event: poisonEvent,
            credential: freshMemberState.localCredential.credentialHandle,
            checkpoint: poisonPolicy
        ))
        let poisonPrepared = try await member.prepareGroupApplication(
            poisonOuter, at: poisonEvent.createdAt
        )
        if let transport = poisonPrepared.transportOperation {
            let sent = try await member.resumeGroupTransport(
                groupID: created.spaceID, operationID: transport.id,
                at: poisonEvent.createdAt
            )
            XCTAssertTrue(sent.complete)
        }
        _ = try await ownerTransport.synchronize(spaceID: created.spaceID)
        mark("verified-join-after-owner-sync-revoked-member")
        let ownerFinal = try await ownerTransport.storedSpaceSnapshot(spaceID: created.spaceID)
        XCTAssertTrue(ownerFinal.verifiedProjection?.acceptedEvents.contains(where: {
            $0.id == posted.event.id
        }) == true)
        XCTAssertEqual(
            ownerFinal.verifiedProjection?.projection.messages[postedMessageID]?.isPinned,
            true
        )
        XCTAssertTrue(ownerFinal.verifiedProjection?.rejectedEvents.contains(where: {
            $0.eventID == backdatedUnpin.id
        }) == true)
        XCTAssertFalse(ownerFinal.legacyArchiveEvents.contains(where: {
            $0.id == legacyAfterCutoff.id
        }))
        let didRebind = try await ownerTransport.rebindVerifiedCommunityAfterUpgrade(
            spaceID: created.spaceID
        )
        mark("verified-join-after-owner-rebind")
        XCTAssertTrue(didRebind)
        let ownerAfterRebind = await (try await owner.openGroupRuntime(
            groupID: created.spaceID
        )).snapshot()
        XCTAssertGreaterThanOrEqual(
            ownerAfterRebind.protectedApplicationEventIDs.count, 2,
            "The retained member message still needs its prior policy checkpoint"
        )
        _ = try await memberTransport.synchronize(spaceID: created.spaceID)
        mark("verified-join-after-member-rebind-sync")
        let rebound = try await memberTransport.storedSpaceSnapshot(spaceID: created.spaceID)
        XCTAssertEqual(rebound.policyMode, .verified)
        XCTAssertGreaterThan(rebound.groupEpoch, memberSnapshot.groupEpoch)
        XCTAssertTrue(rebound.verifiedProjection?.acceptedEvents.contains(where: {
            $0.id == posted.event.id
        }) == true)
        let recoveryChannel = UUID()
        let unpinnedOwnerDelta = try await ownerTransport.publishOperation(
            spaceID: created.spaceID,
            operation: .createChannel(id: recoveryChannel, name: "after cursor")
        )
        XCTAssertTrue(unpinnedOwnerDelta.complete)
        _ = try await member.syncGroup(groupID: created.spaceID)
        let committedWithoutAppPin = await (try await member.openGroupRuntime(
            groupID: created.spaceID
        )).snapshot()
        XCTAssertTrue(committedWithoutAppPin.events.contains(where: {
            $0.id == unpinnedOwnerDelta.event.id
        }))
        XCTAssertFalse(committedWithoutAppPin.protectedApplicationEventIDs.contains(
            unpinnedOwnerDelta.event.id
        ))
        let recovered = try await memberTransport.storedSpaceSnapshot(
            spaceID: created.spaceID
        )
        mark("verified-join-after-crash-pin-recovery")
        XCTAssertEqual(recovered.policyMode, .verified)
        XCTAssertNotNil(recovered.verifiedProjection?.projection.channels[recoveryChannel])
        let durablePin = await (try await member.openGroupRuntime(
            groupID: created.spaceID
        )).snapshot()
        XCTAssertTrue(durablePin.protectedApplicationEventIDs.contains(
            unpinnedOwnerDelta.event.id
        ))

        // A removed raw client can retain its old signing key. Even if it
        // learns the new route/key out of band, the current Core roster must
        // reject its otherwise well-formed encrypted realtime signal.
        let removedCredential = await (try await member.openGroupRuntime(
            groupID: created.spaceID
        )).snapshot().localCredential
        let beforeRemoval = await (try await owner.openGroupRuntime(
            groupID: created.spaceID
        )).snapshot()
        let removalEpoch = beforeRemoval.signedState.epoch + 1
        let proposedMembers = beforeRemoval.signedState.members.map { entry in
            entry.id == removedCredential.memberHandle
                ? GroupMemberV2(
                    id: entry.id, role: entry.role,
                    addedEpoch: entry.addedEpoch, removedEpoch: removalEpoch
                ) : entry
        }
        let proposedCredentials = beforeRemoval.signedState.memberCredentials.map { entry in
            entry.memberHandle == removedCredential.memberHandle
                && entry.isActive(at: beforeRemoval.signedState.epoch)
                ? GroupMemberCredentialV2(
                    memberHandle: entry.memberHandle,
                    credentialHandle: entry.credentialHandle,
                    admissionDigest: entry.admissionDigest,
                    signingPublicKey: entry.signingPublicKey,
                    agreementPublicKey: entry.agreementPublicKey,
                    contentTypes: entry.contentTypes,
                    addedEpoch: entry.addedEpoch,
                    removedEpoch: removalEpoch
                ) : entry
        }
        let removal = try await owner.prepareGroupEpoch(
            groupID: created.spaceID,
            operation: .removeMember,
            proposedMembers: proposedMembers,
            proposedCredentials: proposedCredentials,
            proposedPermissions: beforeRemoval.signedState.permissions,
            proposedMetadataDigest: beforeRemoval.signedState.metadataDigest,
            idempotencyKey: Data(SHA256.hash(data: Data(UUID().uuidString.utf8)))
        )
        if let operation = removal.transportOperation {
            let sent = try await owner.resumeGroupTransport(
                groupID: created.spaceID, operationID: operation.id
            )
            XCTAssertTrue(sent.complete)
        }
        mark("verified-join-after-core-member-removal")
        _ = try await ownerTransport.ensureCommunityBootstrap(spaceID: created.spaceID)
        mark("verified-join-after-removal-owner-snapshot")
        let afterRemoval = try await ownerTransport.storedSpaceSnapshot(
            spaceID: created.spaceID
        )
        let refreshedRoom = try XCTUnwrap(
            afterRemoval.verifiedProjection?.projection.voiceRooms[voiceRoomID]
        )
        XCTAssertNotEqual(
            refreshedRoom.realtimeRoute.readCapability,
            originalVoiceRoute.readCapability
        )
        let maliciousSignal = try NoctCordMediaSignalEnvelope(
            roomID: NoctCordMediaRoomID(voiceRoomID.uuidString),
            sender: NoctCordMediaParticipantID(
                NoctCordCallSignalCrypto.participantID(
                    for: removedCredential.memberHandle
                )
            ),
            sequence: 1,
            timestampMilliseconds: Int64(Date().timeIntervalSince1970 * 1_000),
            signal: .join
        )
        let encryptedSignal = try NoctCordCallSignalCrypto.seal(
            maliciousSignal, spaceID: created.spaceID, room: refreshedRoom,
            author: removedCredential.memberHandle, recipient: nil
        )
        let body = NoctCordRealtimeSignedSignalBodyV1(
            spaceID: created.spaceID, roomID: voiceRoomID,
            author: removedCredential.memberHandle,
            credential: removedCredential.credentialHandle,
            signal: encryptedSignal, createdAt: Date()
        )
        let forgedEnvelope = NoctCordRealtimeSignedSignalEnvelopeV1(
            body: body,
            signature: try removedCredential.signingKey.sign(
                NoctCordRealtimeSignalWire.signedBytes(body)
            )
        )
        let encryptedRecord = try NoctCordRealtimeSignalWire.seal(
            forgedEnvelope, room: refreshedRoom, spaceID: created.spaceID
        )
        let forgedAppend = try await RelayClient(endpoint: endpoint).send(
            .appendRealtimeRouteV1(RealtimeRouteAppendRequestV1(
                routeCapability: refreshedRoom.realtimeRoute.routeCapability,
                appendCapability: refreshedRoom.realtimeRoute.appendCapability,
                recordID: encryptedSignal.signalID,
                payload: encryptedRecord
            ))
        )
        XCTAssertNil(forgedAppend.error)
        let acceptedSignals = try await ownerTransport.synchronizeRealtimeCallSignals(
            spaceID: created.spaceID, roomID: voiceRoomID
        )
        XCTAssertTrue(acceptedSignals.isEmpty)
    }
    #endif

    func testCommunitiesCanUseDifferentRelaysInOneClientState() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "noctcord-multi-relay-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let firstServer = RelayServer(
            store: RelayStore(),
            opaqueRouteStore: OpaqueRouteRelayStoreV2()
        )
        let secondServer = RelayServer(
            store: RelayStore(),
            opaqueRouteStore: OpaqueRouteRelayStoreV2()
        )
        let firstEndpoint = try await startOnEphemeralLoopbackPort(firstServer)
        let secondEndpoint = try await startOnEphemeralLoopbackPort(secondServer)
        defer {
            firstServer.stop()
            secondServer.stop()
        }

        let client = try await makeClient(name: "multi-relay", root: root)
        let transport = try NoctCordTransportCoordinator(
            client: client,
            relay: firstEndpoint
        )
        let secondProfile = try await transport.addRelay(
            endpoint: secondEndpoint,
            name: "Second relay",
            accessPassword: nil
        )
        let first = try await transport.createSpace(name: "First relay space")
        let second = try await transport.createSpace(
            name: "Second relay space",
            relayPreferenceID: secondProfile.id
        )
        let firstResolvedRelay = try await transport.relayEndpoint(for: first.spaceID)
        let secondResolvedRelay = try await transport.relayEndpoint(for: second.spaceID)
        let firstSnapshot = try await transport.storedSpaceSnapshot(
            spaceID: first.spaceID
        )
        let secondSnapshot = try await transport.storedSpaceSnapshot(
            spaceID: second.spaceID
        )

        XCTAssertEqual(firstResolvedRelay, firstEndpoint)
        XCTAssertEqual(secondResolvedRelay, secondEndpoint)
        XCTAssertEqual(firstSnapshot.relay, firstEndpoint)
        XCTAssertEqual(secondSnapshot.relay, secondEndpoint)

        firstServer.stop()
        let publication = try await transport.publishOperation(
            spaceID: second.spaceID,
            operation: .postMessage(
                id: UUID(),
                channelID: second.generalChannelID,
                text: "The other community relay is offline"
            )
        )
        XCTAssertTrue(publication.complete)
    }

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

    func testInvitationAdmissionSurvivesMaliciousMemberHistoryAndExchangesMessagesBothWays() async throws {
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
        let ownerHistory = try await ownerTransport.allStoredEvents(
            spaceID: created.spaceID
        )
        let originalCreation = try XCTUnwrap(ownerHistory.flatMap {
            $0.operation.bootstrapEvents ?? [$0]
        }.first {
            $0.operation.kind == .spaceCreated
        })
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

        // Bypass the compliant app's preflight, as a modified member client
        // would. These are correctly signed and group-encrypted transport
        // events; their application operations still lack authority.
        let memberRuntime = try await prospectiveMember.openGroupRuntime(groupID: created.spaceID)
        let memberRuntimeState = await memberRuntime.snapshot()
        let bootstrapRequest = try XCTUnwrap(memberRuntimeState.events.compactMap {
            try? NoctCordCodec.unwrap($0)
        }.first { $0.operation.kind == .bootstrapRequested })
        let attacks: [(UInt64, NoctCordOperation)] = [
            (3, .defineRole(NoctCordRole(id: UUID(), name: "Injected administrator",
                                        position: 10, permissions: [.manageSpace]))),
            (4, .applyBootstrap([originalCreation], satisfying: [bootstrapRequest.id])),
            (NoctCordEvent.maximumLogicalClock, .requestBootstrap()),
        ]
        var attackIDs: [UUID] = []
        for (clock, operation) in attacks {
            let event = NoctCordEvent(spaceID: created.spaceID,
                                      author: memberRuntimeState.localCredential.memberHandle,
                                      logicalClock: clock, operation: operation)
            let wrapped = try NoctCordCodec.wrap(event,
                credential: memberRuntimeState.localCredential.credentialHandle)
            let prepared = try await prospectiveMember.prepareGroupApplication(wrapped, at: event.createdAt)
            let delivery = try XCTUnwrap(prepared.transportOperation)
            let resumed = try await prospectiveMember.resumeGroupTransport(
                groupID: created.spaceID, operationID: delivery.id, at: event.createdAt)
            XCTAssertTrue(resumed.complete)
            attackIDs.append(event.id)
        }
        #if NOCTCORD_VERIFIED_CORE
        // Before the owner seals the admission epoch, the previous policy is
        // intentionally stale. Core may receive these legacy-shaped attacks,
        // but they never become verified application history.
        _ = try await owner.syncGroup(groupID: created.spaceID)
        #else
        _ = try await ownerTransport.synchronize(spaceID: created.spaceID)
        let receivedHistory = try await ownerTransport.allStoredEvents(spaceID: created.spaceID)
        XCTAssertTrue(Set(attackIDs).isSubset(of: Set(receivedHistory.map(\.id))))
        #endif
        let publishedBootstrap = try await ownerTransport.ensureCommunityBootstrap(
            spaceID: created.spaceID
        )
        XCTAssertTrue(publishedBootstrap)
        #if NOCTCORD_VERIFIED_CORE
        let verifiedHistory = try await ownerTransport.allStoredEvents(
            spaceID: created.spaceID
        )
        XCTAssertTrue(Set(attackIDs).isDisjoint(
            with: Set(verifiedHistory.map(\.id))
        ))
        #endif
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

    func testMembersLeaveAndOwnersDestroyWithRetainedTerminalRecords() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "noctcord-community-lifecycle-\(UUID().uuidString)",
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

        let owner = try await makeClient(name: "lifecycle-owner", root: root)
        let member = try await makeClient(name: "lifecycle-member", root: root)
        let ownerTransport = try NoctCordTransportCoordinator(client: owner, relay: endpoint)
        let memberTransport = try NoctCordTransportCoordinator(client: member, relay: endpoint)
        let startedAt = NoctweaveRendezvousV2.canonicalTimestamp(
            Date().addingTimeInterval(-30)
        )

        let leaveGroupID = UUID()
        _ = try await owner.createGroup(
            groupID: leaveGroupID,
            relay: endpoint,
            contentTypes: NoctCordCodec.contentCapabilities,
            createdAt: startedAt
        )
        try await admit(
            member,
            to: leaveGroupID,
            owner: owner,
            relay: endpoint,
            existingMembers: [],
            seed: 0x61,
            startedAt: startedAt.addingTimeInterval(2)
        )

        do {
            _ = try await ownerTransport.leaveCommunity(spaceID: leaveGroupID)
            XCTFail("the owner must not be able to orphan a community")
        } catch {
            XCTAssertEqual(error as? NoctCordTransportError, .ownerCannotLeave)
        }
        do {
            _ = try await memberTransport.destroyCommunity(spaceID: leaveGroupID)
            XCTFail("a non-owner must not be able to destroy a community")
        } catch {
            XCTAssertEqual(error as? NoctCordTransportError, .communityOwnerRequired)
        }

        let leaveResult = try await memberTransport.leaveCommunity(
            spaceID: leaveGroupID
        )
        XCTAssertTrue(leaveResult.complete)
        XCTAssertEqual(leaveResult.action, .leave)
        let removedMemberRuntime = await (try member.openGroupRuntime(
            groupID: leaveGroupID
        )).snapshot()
        XCTAssertNotNil(removedMemberRuntime.localRemoval)
        let memberActiveGroupsAfterLeave = await memberTransport.storedSpaceIDs()
        XCTAssertFalse(memberActiveGroupsAfterLeave.contains(leaveGroupID))

        _ = try await ownerTransport.synchronize(spaceID: leaveGroupID)
        let ownerAfterLeave = try await ownerTransport.storedSpaceSnapshot(
            spaceID: leaveGroupID
        )
        XCTAssertEqual(ownerAfterLeave.members.map(\.handle), [ownerAfterLeave.currentMember])

        let destroyGroupID = UUID()
        _ = try await owner.createGroup(
            groupID: destroyGroupID,
            relay: endpoint,
            contentTypes: NoctCordCodec.contentCapabilities,
            createdAt: startedAt.addingTimeInterval(10)
        )
        try await admit(
            member,
            to: destroyGroupID,
            owner: owner,
            relay: endpoint,
            existingMembers: [],
            seed: 0x71,
            startedAt: startedAt.addingTimeInterval(12)
        )

        let destruction = try await ownerTransport.destroyCommunity(
            spaceID: destroyGroupID
        )
        XCTAssertTrue(destruction.complete)
        XCTAssertEqual(destruction.action, .destroy)
        let ownerActiveGroupsAfterDestroy = await ownerTransport.storedSpaceIDs()
        XCTAssertFalse(ownerActiveGroupsAfterDestroy.contains(destroyGroupID))

        _ = try await memberTransport.synchronize(spaceID: destroyGroupID)
        let destroyedMemberRuntime = await (try member.openGroupRuntime(
            groupID: destroyGroupID
        )).snapshot()
        XCTAssertNotNil(destroyedMemberRuntime.deletionState)
        let memberActiveGroupsAfterDestroy = await memberTransport.storedSpaceIDs()
        XCTAssertFalse(memberActiveGroupsAfterDestroy.contains(destroyGroupID))

        let retainedOwnerGroups = await owner.snapshot().activePersona.groupRuntimes
        let retainedMemberGroups = await member.snapshot().activePersona.groupRuntimes
        XCTAssertTrue(retainedOwnerGroups.contains { $0.groupId == destroyGroupID })
        XCTAssertTrue(retainedMemberGroups.contains { $0.groupId == leaveGroupID })
    }

    func testRealtimeAdmissionAcrossMembersRefreshesDurableJoin() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "noctcord-unjoined-realtime-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let server = RelayServer(store: RelayStore(), opaqueRouteStore: OpaqueRouteRelayStoreV2())
        let endpoint = try await startOnEphemeralLoopbackPort(server)
        defer { server.stop() }

        let client = try await makeClient(name: "owner", root: root)
        let transport = try NoctCordTransportCoordinator(client: client, relay: endpoint)
        let receiver = try await makeClient(name: "receiver", root: root)
        let receiverTransport = try NoctCordTransportCoordinator(client: receiver, relay: endpoint)
        let spaceID = UUID()
        _ = try await client.createGroup(
            groupID: spaceID, relay: endpoint, contentTypes: NoctCordCodec.contentCapabilities,
            createdAt: NoctweaveRendezvousV2.canonicalTimestamp(Date().addingTimeInterval(-30))
        )
        try await admit(receiver, to: spaceID, owner: client, relay: endpoint,
                        existingMembers: [], seed: 0x51,
                        startedAt: NoctweaveRendezvousV2.canonicalTimestamp(Date()))
        #if NOCTCORD_VERIFIED_CORE
        let ownerState = await (try await client.openGroupRuntime(
            groupID: spaceID
        )).snapshot()
        let ownerCreation = NoctCordEvent(
            spaceID: spaceID,
            author: ownerState.localCredential.memberHandle,
            logicalClock: 1,
            operation: .createSpace(name: "Realtime test")
        )
        let migrated = try await transport.migrateCommunityToVerifiedPolicy(
            spaceID: spaceID, approvedConfiguration: [ownerCreation]
        )
        XCTAssertTrue(migrated.complete)
        #else
        _ = try await transport.publishOperation(spaceID: spaceID, operation: .createSpace(name: "Realtime test"))
        #endif
        let roomID = UUID()
        let roomKey = Data(repeating: 0xC4, count: 32)
        let route = try await transport.createRealtimeRoute(lifetime: 600)
        let roomCreation = try await transport.publishOperation(
            spaceID: spaceID,
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
        _ = try await receiverTransport.synchronize(spaceID: spaceID)
        let receiverSnapshot = try await receiverTransport.storedSpaceSnapshot(spaceID: spaceID)
        _ = try await receiverTransport.publishOperation(
            spaceID: spaceID, operation: .joinVoiceRoom(
                id: roomID, state: NoctCordVoiceParticipantStateV1(member: receiverSnapshot.currentMember, isJoined: true)
            )
        )
        _ = try await transport.synchronize(spaceID: spaceID)
        let roomSnapshot = try await transport.storedSpaceSnapshot(spaceID: spaceID)
        #if NOCTCORD_VERIFIED_CORE
        let roomProjectionResult = try XCTUnwrap(roomSnapshot.verifiedProjection)
        #else
        let roomProjectionResult = NoctCordSpaceProjection.project(
            spaceID: spaceID,
            owner: roomSnapshot.owner,
            activeMembers: Set(roomSnapshot.members.map(\.handle)),
            events: roomSnapshot.events
        )
        #endif
        XCTAssertNotNil(
            roomProjectionResult.projection.voiceRooms[roomID],
            "events=\(roomSnapshot.events.map { $0.operation.kind.rawValue }) rejected=\(roomProjectionResult.rejectedEvents)"
        )

        let room = try XCTUnwrap(roomProjectionResult.projection.voiceRooms[roomID])
        let runtime = try await client.openGroupRuntime(groupID: spaceID)
        let snapshot = await runtime.snapshot()
        let author = snapshot.localCredential.memberHandle
        XCTAssertNil(roomProjectionResult.projection.voiceParticipants[roomID]?[author])
        let mediaSignal = try NoctCordMediaSignalEnvelope(
            roomID: NoctCordMediaRoomID(roomID.uuidString),
            sender: NoctCordMediaParticipantID(NoctCordCallSignalCrypto.participantID(for: author)),
            sequence: 1,
            timestampMilliseconds: Int64(Date().timeIntervalSince1970 * 1_000),
            signal: .join
        )
        let signal = try NoctCordCallSignalCrypto.seal(
            mediaSignal, spaceID: spaceID, room: room,
            author: author, recipient: nil
        )
        do {
            try await transport.publishRealtimeCallSignal(
                spaceID: spaceID, roomID: roomID,
                signal: NoctCordCallSignalCrypto.seal(
                    mediaSignal, spaceID: spaceID, room: room, author: author, recipient: nil
                )
            )
            XCTFail("The sender must require accepted durable room membership")
        } catch {
            XCTAssertEqual(error as? NoctCordTransportError, .eventRejected)
        }

        // A modified, authenticated member can bypass the honest sender API.
        // Append an actually encrypted .join and a valid group signature directly.
        let body = NoctCordRealtimeSignedSignalBodyV1(
            spaceID: spaceID, roomID: roomID, author: author,
            credential: snapshot.localCredential.credentialHandle, signal: signal, createdAt: Date()
        )
        let envelope = NoctCordRealtimeSignedSignalEnvelopeV1(
            body: body,
            signature: try snapshot.localCredential.signingKey.sign(NoctCordRealtimeSignalWire.signedBytes(body))
        )
        let payload = try NoctCordRealtimeSignalWire.seal(envelope, room: room, spaceID: spaceID)
        let append = try await RelayClient(endpoint: endpoint).send(.appendRealtimeRouteV1(
            RealtimeRouteAppendRequestV1(
                routeCapability: route.routeCapability, appendCapability: route.appendCapability,
                recordID: signal.signalID, payload: payload
            )
        ))
        XCTAssertNil(append.error)
        let decoded = try NoctCordCallSignalCrypto.open(
            signal, spaceID: spaceID, room: room, author: author, localMember: receiverSnapshot.currentMember
        )
        XCTAssertEqual(decoded.signal.kind, .join, "The attack must be valid encrypted media signaling")
        let received = try await receiverTransport.synchronizeRealtimeCallSignals(spaceID: spaceID, roomID: roomID)
        XCTAssertTrue(received.isEmpty, "A valid group signature must not bypass durable room admission")

        _ = try await transport.publishOperation(
            spaceID: spaceID, operation: .joinVoiceRoom(
                id: roomID, state: NoctCordVoiceParticipantStateV1(member: author, isJoined: true)
            )
        )
        // Do not manually synchronize the receiver: the realtime path must
        // refresh a missing durable join before rejecting legitimate signaling.
        let validSignal = try NoctCordCallSignalCrypto.seal(
            mediaSignal, spaceID: spaceID, room: room, author: author, recipient: nil
        )
        try await transport.publishRealtimeCallSignal(spaceID: spaceID, roomID: roomID, signal: validSignal)
        let accepted = try await receiverTransport.synchronizeRealtimeCallSignals(spaceID: spaceID, roomID: roomID)
        XCTAssertEqual(accepted.map(\.author), [author])
        XCTAssertEqual(accepted.map(\.signal), [validSignal])
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
        #if NOCTCORD_VERIFIED_CORE
        let roomProjectionResult = try XCTUnwrap(roomSnapshot.verifiedProjection)
        #else
        let roomProjectionResult = NoctCordSpaceProjection.project(
            spaceID: bootstrap.spaceID,
            owner: roomSnapshot.owner,
            activeMembers: Set(roomSnapshot.members.map(\.handle)),
            events: roomSnapshot.events
        )
        #endif
        XCTAssertNotNil(
            roomProjectionResult.projection.voiceRooms[roomID],
            "events=\(roomSnapshot.events.map { $0.operation.kind.rawValue }) rejected=\(roomProjectionResult.rejectedEvents)"
        )

        _ = try await transport.publishOperation(
            spaceID: bootstrap.spaceID,
            operation: .joinVoiceRoom(
                id: roomID,
                state: NoctCordVoiceParticipantStateV1(member: roomSnapshot.currentMember, isJoined: true)
            )
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
            startedAt: NoctweaveRendezvousV2.canonicalTimestamp(Date())
        )
        mark("member-one-admitted")
        try await admit(
            memberTwo,
            to: groupID,
            owner: owner,
            relay: endpoint,
            existingMembers: [memberOne],
            seed: 0x41,
            // Group admission performs real PQ work. Use the current time so a
            // slow first admission cannot expire the second route's proof.
            startedAt: NoctweaveRendezvousV2.canonicalTimestamp(Date())
        )
        mark("member-two-admitted")

        let channelID = UUID()
        #if NOCTCORD_VERIFIED_CORE
        let ownerState = await (try await owner.openGroupRuntime(
            groupID: groupID
        )).snapshot()
        let creationOwner = ownerState.localCredential.memberHandle
        let creation = [
            NoctCordEvent(
                spaceID: groupID, author: creationOwner, logicalClock: 1,
                operation: .createSpace(name: "Night Shift")
            ),
            NoctCordEvent(
                spaceID: groupID, author: creationOwner, logicalClock: 2,
                operation: .createChannel(id: channelID, name: "general")
            ),
        ]
        let migrated = try await ownerTransport.migrateCommunityToVerifiedPolicy(
            spaceID: groupID, approvedConfiguration: creation
        )
        XCTAssertTrue(migrated.complete)
        #else
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
        #endif
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
        #if NOCTCORD_VERIFIED_CORE
        let secondProjection = try XCTUnwrap(secondSnapshot.verifiedProjection)
            .projection
        #else
        let secondProjection = NoctCordSpaceProjection.project(
            spaceID: groupID,
            owner: secondSnapshot.owner,
            activeMembers: Set(secondSnapshot.members.map(\.handle)),
            events: secondSnapshot.events
        ).projection
        #endif
        XCTAssertEqual(secondProjection.messages[ownerMessage]?.text, "owner to everyone")
        XCTAssertEqual(secondProjection.messages[memberMessage]?.text, "member to everyone")

        let cleartext = Data("sanitized channel attachment".utf8)
        let attachmentTransfer = try await firstTransport.attachmentTransfer(
            for: groupID
        )
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
        let secondAttachmentTransfer = try await secondTransport.attachmentTransfer(
            for: groupID
        )
        let downloaded = try await secondAttachmentTransfer.download(
            manifest: uploaded.manifest,
            spaceID: groupID,
            channelID: channelID
        )
        XCTAssertEqual(downloaded.bytes, cleartext)
        mark("attachment-roundtrip-complete")

        // Debug cryptographic integration can take longer than ten minutes
        // between route creation and signaling; keep the test route valid.
        let route = try await ownerTransport.createRealtimeRoute(lifetime: 3 * 60 * 60)
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

    func testLiveBuiltAppExchangeHarness() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["NOCTCORD_RUN_LIVE_APP_SCENARIO"] == "1" else {
            throw XCTSkip("The built-app exchange harness is opt-in.")
        }
        let rootPath = try XCTUnwrap(environment["NOCTCORD_LIVE_APP_ROOT"])
        let port = try XCTUnwrap(UInt16(environment["NOCTCORD_LIVE_APP_PORT"] ?? ""))
        let root = URL(fileURLWithPath: rootPath, isDirectory: true).standardizedFileURL
        let ownerStateURL = root.appendingPathComponent("sender.json")
        let memberStateURL = root.appendingPathComponent("receiver.json")
        XCTAssertFalse(FileManager.default.fileExists(atPath: ownerStateURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: memberStateURL.path))
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: root.path
        )

        let server = RelayServer(
            store: RelayStore(),
            opaqueRouteStore: OpaqueRouteRelayStoreV2()
        )
        try server.start(host: "127.0.0.1", port: port)
        defer { server.stop() }
        try await Task.sleep(nanoseconds: 250_000_000)
        let endpoint = RelayEndpoint(host: "127.0.0.1", port: port)

        let owner = try await makeClient(name: "sender", root: root)
        let member = try await makeClient(name: "receiver", root: root)
        let ownerTransport = try NoctCordTransportCoordinator(client: owner, relay: endpoint)
        let memberTransport = try NoctCordTransportCoordinator(client: member, relay: endpoint)
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
        try await admit(
            member,
            to: groupID,
            owner: owner,
            relay: endpoint,
            existingMembers: [],
            seed: 0x71,
            startedAt: startedAt.addingTimeInterval(2)
        )

        let channelID = UUID()
        #if NOCTCORD_VERIFIED_CORE
        let ownerState = await (try await owner.openGroupRuntime(
            groupID: groupID
        )).snapshot()
        let creationOwner = ownerState.localCredential.memberHandle
        let creation = [
            NoctCordEvent(
                spaceID: groupID, author: creationOwner, logicalClock: 1,
                operation: .createSpace(name: "Live Exchange")
            ),
            NoctCordEvent(
                spaceID: groupID, author: creationOwner, logicalClock: 2,
                operation: .createChannel(id: channelID, name: "verification")
            ),
        ]
        let migrated = try await ownerTransport.migrateCommunityToVerifiedPolicy(
            spaceID: groupID, approvedConfiguration: creation
        )
        XCTAssertTrue(migrated.complete)
        #else
        let spaceCreation = try await ownerTransport.publishOperation(
            spaceID: groupID,
            operation: .createSpace(name: "Live Exchange")
        )
        XCTAssertTrue(spaceCreation.complete)
        let channelCreation = try await ownerTransport.publishOperation(
            spaceID: groupID,
            operation: .createChannel(id: channelID, name: "verification")
        )
        XCTAssertTrue(channelCreation.complete)
        #endif
        _ = try await memberTransport.synchronize(spaceID: groupID)

        let readyURL = root.appendingPathComponent("ready.json")
        let metadata: [String: Any] = [
            "relayPort": Int(port),
            "spaceID": groupID.uuidString,
            "channelID": channelID.uuidString,
            "senderState": ownerStateURL.path,
            "receiverState": memberStateURL.path,
        ]
        let readyData = try JSONSerialization.data(
            withJSONObject: metadata,
            options: [.prettyPrinted, .sortedKeys]
        )
        try readyData.write(to: readyURL, options: .atomic)
        mark("live-app-harness-ready \(readyURL.path)")

        let stopURL = root.appendingPathComponent("stop")
        let deadline = Date().addingTimeInterval(15 * 60)
        while Date() < deadline,
              !FileManager.default.fileExists(atPath: stopURL.path) {
            try await Task.sleep(nanoseconds: 250_000_000)
        }
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: stopURL.path),
            "The built-app exchange harness timed out before its stop marker arrived."
        )
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
        let fileURL = root.appendingPathComponent("\(name).json")
        #if DEBUG
        let store = ClientStateStore(fileURL: fileURL, protection: .insecurePlaintextForTesting)
        #else
        // Release correctly rejects plaintext test stores. A per-client key
        // and process-local anchor keep these temporary fixtures off Keychain;
        // this does not exercise persistent rollback-anchor protection.
        let store = ClientStateStore(
            fileURL: fileURL,
            encryptionKey: SymmetricKey(size: .bits256),
            rollbackAnchorStore: VolatileClientStateRollbackAnchorStore()
        )
        #endif
        return try await HeadlessMessagingClient.open(stateStore: store, displayName: name)
    }

    private func mark(_ value: String) {
        // Timestamp at the source: SwiftPM can buffer XCTest's output before
        // a profiling harness receives these otherwise unchanged markers.
        let uptime = DispatchTime.now().uptimeNanoseconds
        FileHandle.standardError.write(Data("[NoctCordIntegration] \(value) [uptime_ns=\(uptime)]\n".utf8))
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
