#if NOCTCORD_VERIFIED_CORE
import CryptoKit
import Foundation
import NoctCordCore
@preconcurrency import NoctweaveCore
import XCTest

final class NoctCordVerifiedCoreIntegrationTests: XCTestCase {
    func testRealCoreReceiptsPinGenesisAndPreserveMessageAcrossPolicyDeltaAndRestart() async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let groupID = UUID()
        let channelID = UUID()
        let messageID = UUID()
        let memberHandle = GroupScopedMemberHandleV2.generate()
        let signingKey = try SigningKeyPair.generate()
        let agreementKey = try AgreementKeyPair.generate()
        let admission = try GroupCredentialAdmissionV2.create(
            groupId: groupID,
            memberHandle: memberHandle,
            groupSigningKey: signingKey,
            groupAgreementKey: agreementKey,
            contentTypes: NoctCordCodec.contentCapabilities,
            issuedAt: now,
            expiresAt: now.addingTimeInterval(3_600)
        )
        let leaf = try GroupMemberCredentialV2.fromVerifiedProjection(
            admission, addedEpoch: 1
        )
        let credential = LocalGroupCredentialV2(
            groupId: groupID,
            memberHandle: memberHandle,
            credentialHandle: leaf.credentialHandle,
            admissionDigest: leaf.admissionDigest,
            signingKey: signingKey,
            agreementKey: agreementKey
        )
        let creator = GroupMemberV2(id: memberHandle, role: .owner, addedEpoch: 1)
        let provider = NoctweavePQGroupExperimentalProviderV2()
        let membership = try provider.membership(
            groupId: groupID, epoch: 1, members: [creator], leaves: [leaf]
        )
        let prepared = try provider.prepareGenesis(
            membership: membership, localCredential: credential
        )
        let providerDigest = try XCTUnwrap(prepared.providerCommitDigest)
        let signedState = try SignedGroupStateV2.initial(
            groupId: groupID,
            creator: creator,
            creatorAdmission: admission,
            providerGenesisDigest: providerDigest,
            signingKey: signingKey,
            signedAt: now
        )
        let acceptance = GroupCryptoAcceptedEpochV2(
            proposal: prepared.proposal,
            providerCommitDigest: providerDigest,
            signedCommitDigest: signedState.commitDigest,
            acceptedTranscriptHash: signedState.confirmedTranscriptHash
        )
        let cryptoState = try provider.finalizePreparedEpoch(
            prepared, acceptance: acceptance
        )
        let record = GroupRuntimeRecord(
            groupId: groupID,
            localCredential: credential,
            signedState: signedState,
            cryptoState: cryptoState
        )
        XCTAssertTrue(record.isStructurallyValid)
        let store = InMemoryVerifiedCoreStore(record: record)
        let runtime = try NoctweavePQGroupRuntimeV2(
            record: record, persistence: store
        )

        let configuration = [
            NoctCordEvent(
                spaceID: groupID, author: memberHandle, logicalClock: 1,
                createdAt: now, operation: .createSpace(name: "secure")
            ),
            NoctCordEvent(
                spaceID: groupID, author: memberHandle, logicalClock: 2,
                createdAt: now.addingTimeInterval(1),
                operation: .createChannel(id: channelID, name: "general")
            ),
        ]
        let genesisHeads = try XCTUnwrap(record.currentVerificationFrontiers())
        let genesis = try makeCheckpoint(
            groupID: groupID, owner: memberHandle,
            credential: credential.credentialHandle,
            operation: .applyBootstrap(configuration),
            kind: .snapshot, previousCheckpointDigest: nil,
            frontiers: genesisHeads,
            epoch: signedState.epoch,
            transcriptHash: signedState.confirmedTranscriptHash,
            clock: 3, date: now.addingTimeInterval(2)
        )
        _ = try await runtime.prepareApplicationEvent(
            genesis.outer, at: now.addingTimeInterval(2)
        )
        try await runtime.markApplicationPublished(eventID: genesis.outer.id)
        try await runtime.replaceProtectedApplicationEvent(
            previousEventID: nil, with: genesis.outer.id,
            verificationFrontiers: genesisHeads
        )
        let genesisSnapshot = await runtime.snapshot()
        XCTAssertEqual(
            genesisSnapshot.protectedVerificationFrontiers(for: genesis.outer.id),
            genesisHeads
        )
        XCTAssertEqual(
            try NoctCordSecureProjectionV2.project(verified: genesisSnapshot)
                .projection.name,
            "secure"
        )

        let message = NoctCordEvent(
            spaceID: groupID, author: memberHandle, logicalClock: 4,
            createdAt: now.addingTimeInterval(3),
            operation: .postMessage(
                id: messageID, channelID: channelID, text: "before policy"
            )
        )
        let messageOuter = try NoctCordCodec.wrapSecure(
            NoctCordSecureEventV2(
                event: message, credential: credential.credentialHandle
            )
        )
        _ = try await runtime.prepareApplicationEvent(
            messageOuter, at: now.addingTimeInterval(3)
        )
        try await runtime.markApplicationPublished(eventID: messageOuter.id)

        let beforeDelta = await runtime.snapshot()
        let deltaHeads = try XCTUnwrap(beforeDelta.currentVerificationFrontiers())
        let delta = try makeCheckpoint(
            groupID: groupID, owner: memberHandle,
            credential: credential.credentialHandle,
            operation: .setChannelPermissions(
                channelID: channelID, roleID: nil,
                allow: [], deny: [.sendMessages]
            ),
            kind: .delta,
            previousCheckpointDigest: try genesis.secure.canonicalDigest(),
            frontiers: deltaHeads,
            epoch: signedState.epoch,
            transcriptHash: signedState.confirmedTranscriptHash,
            clock: 5, date: now.addingTimeInterval(4)
        )
        _ = try await runtime.prepareApplicationEvent(
            delta.outer, at: now.addingTimeInterval(4)
        )
        try await runtime.markApplicationPublished(eventID: delta.outer.id)
        try await runtime.replaceProtectedApplicationEvent(
            previousEventID: nil, with: delta.outer.id,
            verificationFrontiers: deltaHeads
        )

        let after = await runtime.snapshot()
        let projected = try NoctCordSecureProjectionV2.project(verified: after)
        XCTAssertEqual(projected.projection.messages[messageID]?.text, "before policy")
        XCTAssertEqual(projected.projection.channels[channelID]?
            .permissionOverrides[.everyone]?.deny, [.sendMessages])
        XCTAssertTrue(projected.rejectedEvents.isEmpty)

        let loaded = try await store.load()
        let saved = try XCTUnwrap(loaded)
        let reopened = try NoctweavePQGroupRuntimeV2(
            record: saved, persistence: store
        )
        let restored = try NoctCordSecureProjectionV2.project(
            verified: await reopened.snapshot()
        )
        XCTAssertEqual(restored, projected)
    }

    private func makeCheckpoint(
        groupID: UUID,
        owner: GroupScopedMemberHandleV2,
        credential: GroupScopedCredentialHandleV2,
        operation: NoctCordOperation,
        kind: NoctCordPolicyCheckpointKindV2,
        previousCheckpointDigest: Data?,
        frontiers: [GroupApplicationVerificationFrontierV2],
        epoch: UInt64,
        transcriptHash: Data,
        clock: UInt64,
        date: Date
    ) throws -> (
        outer: GroupConversationEventV2,
        secure: NoctCordSecureEventV2
    ) {
        let event = NoctCordEvent(
            spaceID: groupID, author: owner,
            logicalClock: clock, createdAt: date, operation: operation
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
            spaceID: groupID,
            owner: owner,
            kind: kind,
            groupEpoch: epoch,
            groupTranscriptHash: transcriptHash,
            previousCheckpointDigest: previousCheckpointDigest,
            configurationDigest: Data(SHA256.hash(data: configurationBytes)),
            frontiers: frontiers.map(NoctCordCredentialFrontierV2.init)
        )
        let secure = NoctCordSecureEventV2(
            event: event, credential: credential, checkpoint: policy
        )
        return (try NoctCordCodec.wrapSecure(secure), secure)
    }
}

private final class InMemoryVerifiedCoreStore: GroupRuntimeRecordPersistence, @unchecked Sendable {
    private let lock = NSLock()
    private var record: GroupRuntimeRecord?

    init(record: GroupRuntimeRecord?) { self.record = record }

    func load() async throws -> GroupRuntimeRecord? {
        lock.withLock { record }
    }

    func save(_ record: GroupRuntimeRecord) async throws {
        lock.withLock { self.record = record }
    }
}
#endif
