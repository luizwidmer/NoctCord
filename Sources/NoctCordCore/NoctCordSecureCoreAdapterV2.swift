#if NOCTCORD_VERIFIED_CORE
import Foundation
@preconcurrency import NoctweaveCore

/// This adapter is compiled only against a Core revision that persists
/// authenticated application receipts and protected frontier bindings. The
/// normal remote dependency pin does not yet expose those APIs.
extension NoctCordSecureProjectionV2 {
    public static func project(
        verified snapshot: GroupRuntimeRecord
    ) throws -> NoctCordProjectionResult {
        try projectFromCore(snapshot, allowStaleCheckpointForOwnerRebind: false)
    }

    package static func projectForOwnerRebind(
        verified snapshot: GroupRuntimeRecord
    ) throws -> NoctCordProjectionResult {
        try projectFromCore(snapshot, allowStaleCheckpointForOwnerRebind: true)
    }

    private static func projectFromCore(
        _ snapshot: GroupRuntimeRecord,
        allowStaleCheckpointForOwnerRebind: Bool,
        excludingCheckpointIDs: Set<UUID> = [],
        consideringUnpinnedCheckpointIDs: Set<UUID> = []
    ) throws -> NoctCordProjectionResult {
        guard let owner = snapshot.signedState.members.first(where: {
            $0.role == .owner && $0.isActive(at: snapshot.signedState.epoch)
        })?.id else {
            throw NoctCordSecureProjectionErrorV2.invalidCheckpoint
        }
        let members = Set(snapshot.signedState.members.compactMap {
            $0.isActive(at: snapshot.signedState.epoch) ? $0.id : nil
        })
        let ownerCheckpointEvents = snapshot.events.filter { outer in
            guard outer.authorMemberHandle == owner,
                  NoctCordCodec.isSecureContent(outer.content),
                  snapshot.applicationVerificationReceipt(for: outer.id)?.outcome
                      == .accepted,
                  let secure = try? NoctCordCodec.unwrapSecure(outer) else {
                return false
            }
            return secure.checkpoint != nil
        }
        guard ownerCheckpointEvents.allSatisfy({ outer in
            snapshot.protectedApplicationEventIDs.contains(outer.id)
                || snapshot.retiredProtectedApplicationEventIDs.contains(outer.id)
                || excludingCheckpointIDs.contains(outer.id)
                || consideringUnpinnedCheckpointIDs.contains(outer.id)
                || (allowStaleCheckpointForOwnerRebind
                    && snapshot.pendingApplicationPublications.contains(where: {
                        $0.event.id == outer.id
                    }))
        }) else {
            // A verified but unpinned owner delta may already be in the
            // durable event store after a crash or partial sync. Returning
            // the prior policy here would re-enable revoked operations.
            throw NoctCordSecureProjectionErrorV2.missingCheckpoint
        }
        let checkpointIDs = Set(snapshot.protectedApplicationEventIDs)
            .union(consideringUnpinnedCheckpointIDs)
            .subtracting(excludingCheckpointIDs)
        let checkpoints = try checkpointIDs.compactMap { eventID
            -> NoctCordProtectedCheckpointV2? in
            guard let outer = snapshot.events.first(where: { $0.id == eventID }),
                  NoctCordCodec.isSecureContent(outer.content) else {
                return nil
            }
            let binding: [NoctCordCredentialFrontierV2]
            if consideringUnpinnedCheckpointIDs.contains(eventID),
               !snapshot.protectedApplicationEventIDs.contains(eventID) {
                guard let secure = try? NoctCordCodec.unwrapSecure(outer),
                      let checkpoint = secure.checkpoint,
                      snapshot.applicationVerificationReceipt(for: eventID)?.outcome
                        == .accepted else {
                    throw NoctCordSecureProjectionErrorV2.invalidCheckpoint
                }
                binding = checkpoint.frontiers
            } else {
                guard let coreBinding = snapshot.protectedVerificationFrontiers(
                    for: eventID
                ) else {
                    throw NoctCordSecureProjectionErrorV2.invalidCheckpoint
                }
                binding = coreBinding.map(NoctCordCredentialFrontierV2.init)
            }
            return NoctCordProtectedCheckpointV2(
                event: outer,
                verifiedFrontiers: binding
            )
        }
        let receipts = Dictionary(uniqueKeysWithValues:
            snapshot.events.compactMap { outer in
                snapshot.applicationVerificationReceipt(for: outer.id).flatMap {
                    NoctCordVerifiedTransportReceiptV2($0).map { (outer.id, $0) }
                }
            }
        )
        return try project(
            spaceID: snapshot.groupId,
            owner: owner,
            activeMembers: members,
            activeCredentials: Set(snapshot.signedState.activeCredentials.map(\.credentialHandle)),
            protectedCheckpoints: checkpoints,
            verifiedEvents: snapshot.events,
            receipts: receipts,
            currentEpoch: snapshot.signedState.epoch,
            currentTranscriptHash: snapshot.signedState.confirmedTranscriptHash,
            // A Core-bound full owner snapshot is a safe local root when
            // earlier ciphertext was never delivered (join/upgrade) or has
            // been explicitly retired after its governed content aged out.
            // Any retained pre-root ordinary event is rejected, never moved
            // under the new policy.
            allowJoinedSnapshotRoot: true,
            allowStaleCheckpointForOwnerRebind:
                allowStaleCheckpointForOwnerRebind,
            allowIncompleteOwnerSeriesForRecovery:
                allowStaleCheckpointForOwnerRebind
        )
    }

    /// A dry-run for an atomic Core retirement. The caller must compare the
    /// resulting retained content and visible policy with the full replay
    /// before passing any old IDs to Core's series replacement API.
    package static func projectAfterRetiring(
        _ eventIDs: Set<UUID>,
        verified snapshot: GroupRuntimeRecord,
        allowStaleOwnerEpoch: Bool = false
    ) throws -> NoctCordProjectionResult {
        try projectFromCore(
            snapshot,
            allowStaleCheckpointForOwnerRebind: allowStaleOwnerEpoch,
            excludingCheckpointIDs: eventIDs
        )
    }

    /// Maintenance-only simulation. The extra owner events have accepted
    /// Core receipts but are not yet protected; Core must bind their exact
    /// frontiers atomically before this result can ever be used as authority.
    package static func projectForAtomicReceiverPin(
        verified snapshot: GroupRuntimeRecord,
        adding eventIDs: Set<UUID>,
        retiring oldIDs: Set<UUID>
    ) throws -> NoctCordProjectionResult {
        try projectFromCore(
            snapshot,
            allowStaleCheckpointForOwnerRebind: false,
            excludingCheckpointIDs: oldIDs,
            consideringUnpinnedCheckpointIDs: eventIDs
        )
    }
}

public extension NoctCordCredentialFrontierV2 {
    init(_ core: GroupApplicationVerificationFrontierV2) {
        self.init(
            epoch: core.epoch,
            transcriptHash: core.transcriptHash,
            credential: core.credentialHandle,
            nextCounter: core.nextCounter,
            prefixDigest: core.prefixDigest
        )
    }

    func coreFrontier(groupID: UUID) -> GroupApplicationVerificationFrontierV2 {
        GroupApplicationVerificationFrontierV2(
            groupID: groupID,
            epoch: epoch,
            transcriptHash: transcriptHash,
            credentialHandle: credential,
            nextCounter: nextCounter,
            prefixDigest: prefixDigest
        )
    }
}

extension NoctCordVerifiedTransportReceiptV2 {
    init?(_ core: GroupApplicationVerificationReceiptV2) {
        guard core.outcome == .accepted, let eventDigest = core.eventDigest else {
            return nil
        }
        self.init(
            eventID: core.eventID,
            groupID: core.groupID,
            eventDigest: eventDigest,
            epoch: core.epoch,
            transcriptHash: core.transcriptHash,
            credential: core.credentialHandle,
            messageCounter: core.messageCounter,
            envelopeDigest: core.envelopeDigest,
            previousPrefixDigest: core.previousPrefixDigest,
            prefixDigest: core.prefixDigest,
            isAccepted: true
        )
    }
}
#endif
