import CryptoKit
import Foundation
@preconcurrency import NoctweaveCore

public enum NoctCordSecureProjectionErrorV2: Error, Equatable, Sendable {
    case missingCheckpoint
    case invalidCheckpoint
    case staleCheckpoint
}

/// A view of Core's authenticated receipt. Production callers must populate
/// this only from `GroupRuntimeRecord.applicationVerificationReceipt(for:)`.
/// Application payload fields are never accepted as a transport position.
struct NoctCordVerifiedTransportReceiptV2: Equatable, Sendable {
    let eventID: UUID
    let groupID: UUID
    let eventDigest: Data
    let epoch: UInt64
    let transcriptHash: Data
    let credential: GroupScopedCredentialHandleV2
    let messageCounter: UInt64
    let envelopeDigest: Data
    let previousPrefixDigest: Data
    let prefixDigest: Data
    let isAccepted: Bool

    init(
        eventID: UUID,
        groupID: UUID,
        eventDigest: Data,
        epoch: UInt64,
        transcriptHash: Data,
        credential: GroupScopedCredentialHandleV2,
        messageCounter: UInt64,
        envelopeDigest: Data,
        previousPrefixDigest: Data,
        prefixDigest: Data,
        isAccepted: Bool
    ) {
        self.eventID = eventID
        self.groupID = groupID
        self.eventDigest = eventDigest
        self.epoch = epoch
        self.transcriptHash = transcriptHash
        self.credential = credential
        self.messageCounter = messageCounter
        self.envelopeDigest = envelopeDigest
        self.previousPrefixDigest = previousPrefixDigest
        self.prefixDigest = prefixDigest
        self.isAccepted = isAccepted
    }

    var isStructurallyValid: Bool {
        epoch > 0 && transcriptHash.count == SHA256.byteCount
            && credential.isStructurallyValid
            && eventDigest.count == SHA256.byteCount
            && envelopeDigest.count == SHA256.byteCount
            && previousPrefixDigest.count == SHA256.byteCount
            && prefixDigest.count == SHA256.byteCount
    }
}

/// A Core-pinned owner checkpoint and the exact frontier vector Core verified
/// when it pinned the event. NoctCord compares this binding with the signed
/// payload; a merely present event is not an authority anchor.
struct NoctCordProtectedCheckpointV2: Equatable {
    let event: GroupConversationEventV2
    let verifiedFrontiers: [NoctCordCredentialFrontierV2]

    init(
        event: GroupConversationEventV2,
        verifiedFrontiers: [NoctCordCredentialFrontierV2]
    ) {
        self.event = event
        self.verifiedFrontiers = verifiedFrontiers
    }
}

/// Deterministically replays all retained v2 content across owner policy
/// deltas. Core receipts choose an interval; sender clocks only arrange events
/// inside that interval. The caller must supply the complete Core-pinned
/// checkpoint chain governing the retained event window.
public enum NoctCordSecureProjectionV2 {
    static func project(
        spaceID: UUID,
        owner: GroupScopedMemberHandleV2,
        activeMembers: Set<GroupScopedMemberHandleV2>,
        activeCredentials: Set<GroupScopedCredentialHandleV2>,
        protectedCheckpoints: [NoctCordProtectedCheckpointV2],
        verifiedEvents: [GroupConversationEventV2],
        receipts: [UUID: NoctCordVerifiedTransportReceiptV2],
        currentEpoch: UInt64,
        currentTranscriptHash: Data,
        allowJoinedSnapshotRoot: Bool = false,
        allowStaleCheckpointForOwnerRebind: Bool = false,
        allowIncompleteOwnerSeriesForRecovery: Bool = false
    ) throws -> NoctCordProjectionResult {
        guard !protectedCheckpoints.isEmpty else {
            throw NoctCordSecureProjectionErrorV2.missingCheckpoint
        }
        let receiptPositions = receipts.values.map {
            "\($0.epoch):\($0.credential.rawValue):\($0.messageCounter)"
        }
        guard Set(receiptPositions).count == receiptPositions.count else {
            throw NoctCordSecureProjectionErrorV2.invalidCheckpoint
        }
        let ordered = try orderedCheckpoints(
            protectedCheckpoints,
            receipts: receipts,
            spaceID: spaceID,
            owner: owner,
            allowJoinedSnapshotRoot: allowJoinedSnapshotRoot
        )
        let checkpoints = try policyBoundaries(
            ordered, spaceID: spaceID, owner: owner,
            allowIncompleteTail: allowIncompleteOwnerSeriesForRecovery
        )
        guard let latest = checkpoints.last,
              let latestPolicy = latest.payload.checkpoint,
              latestPolicy.groupEpoch <= currentEpoch,
              (allowStaleCheckpointForOwnerRebind
                  || latestPolicy.groupEpoch == currentEpoch),
              (latestPolicy.groupEpoch != currentEpoch
                  || latestPolicy.groupTranscriptHash == currentTranscriptHash) else {
            throw NoctCordSecureProjectionErrorV2.staleCheckpoint
        }
        if latestPolicy.groupEpoch == currentEpoch {
            guard Set(latestPolicy.frontiers.filter {
                $0.epoch == currentEpoch
            }.map(\.credential)) == activeCredentials else {
                throw NoctCordSecureProjectionErrorV2.invalidCheckpoint
            }
        }

        let checkpointIDs = Set(checkpoints.flatMap { $0.parts.map(\.outer.id) })
        let enrolled = Set(ordered.flatMap { entry in
            entry.payload.checkpoint!.frontiers.map {
                frontierKey(epoch: $0.epoch, credential: $0.credential)
            }
        })
        var uniqueEvents: [UUID: GroupConversationEventV2] = [:]
        for outer in verifiedEvents {
            if let previous = uniqueEvents[outer.id], previous != outer {
                throw NoctCordSecureProjectionErrorV2.invalidCheckpoint
            }
            uniqueEvents[outer.id] = outer
        }
        var buckets = Array(repeating: [NoctCordEvent](), count: checkpoints.count + 1)
        var rejected: [NoctCordRejectedEvent] = []
        let checkpointByID = Dictionary(uniqueKeysWithValues: checkpoints.flatMap {
            $0.parts.map { ($0.outer.id, $0.outer) }
        })
        for outer in uniqueEvents.values.sorted(by: { $0.id.uuidString < $1.id.uuidString }) {
            if checkpointIDs.contains(outer.id) {
                guard checkpointByID[outer.id] == outer else {
                    throw NoctCordSecureProjectionErrorV2.invalidCheckpoint
                }
                continue
            }
            guard NoctCordCodec.isSecureContent(outer.content) else {
                if outer.content.type == NoctCordCodec.contentType {
                    rejected.append(NoctCordRejectedEvent(
                        eventID: outer.id,
                        reason: "legacy event has no v2 authorization receipt"
                    ))
                }
                continue
            }
            guard let receipt = receipts[outer.id],
                  receiptMatches(receipt, outer: outer),
                  let secure = try? NoctCordCodec.unwrapSecure(outer),
                  secure.event.spaceID == spaceID,
                  secure.checkpoint == nil,
                  !secure.event.operation.kind.isBootstrapConfiguration,
                  secure.event.operation.kind != .bootstrapApplied,
                  enrolled.contains(frontierKey(
                      epoch: receipt.epoch, credential: receipt.credential
                  )),
                  receipt.epoch <= currentEpoch else {
                rejected.append(NoctCordRejectedEvent(
                    eventID: outer.id,
                    reason: "missing verified receipt, enrollment, or policy checkpoint"
                ))
                continue
            }
            let interval = policyInterval(for: receipt, checkpoints: checkpoints)
            guard interval > 0 else {
                rejected.append(NoctCordRejectedEvent(
                    eventID: outer.id,
                    reason: "event predates v2 policy genesis"
                ))
                continue
            }
            buckets[interval].append(secure.event)
        }

        let historicalAuthors = Set(buckets.flatMap { $0.map(\.author) })
        let historicalPolicyRecipients = Set(checkpoints.flatMap { entry in
            let operations = [entry.payload.event.operation]
                + (entry.configuration?.map(\.operation) ?? [])
            return operations.flatMap { operation -> [GroupScopedMemberHandleV2] in
                [operation.memberHandle, operation.botApplication?.memberHandle].compactMap {
                    $0
                }
            }
        })
        var projection = NoctCordSpaceProjection(
            spaceID: spaceID,
            owner: owner,
            activeMembers: activeMembers.union(historicalAuthors)
                .union(historicalPolicyRecipients)
        )
        var accepted: [NoctCordEvent] = []
        for (index, checkpoint) in checkpoints.enumerated() {
            do {
                if checkpoint.payload.checkpoint?.kind == .snapshot {
                    guard let configuration = checkpoint.configuration else {
                        throw NoctCordSecureProjectionErrorV2.invalidCheckpoint
                    }
                    if index == 0 {
                        try projection.applyVerifiedConfigurationSnapshot(configuration)
                        accepted.append(contentsOf: checkpoint.parts.map(\.payload.event))
                        for event in buckets[index + 1].sorted(by: canonicalOrder) {
                            do {
                                try projection.applyVerifiedV2(
                                    event, permittingHistoricalAuthor: true
                                )
                                accepted.append(event)
                            } catch {
                                rejected.append(NoctCordRejectedEvent(
                                    eventID: event.id, reason: String(describing: error)
                                ))
                            }
                        }
                        continue
                    }
                    var comparison = NoctCordSpaceProjection(
                        spaceID: spaceID, owner: owner,
                        activeMembers: activeMembers.union(historicalAuthors)
                            .union(historicalPolicyRecipients)
                    )
                    try comparison.applyVerifiedConfigurationSnapshot(configuration)
                    var currentConfiguration = projection
                    currentConfiguration.reconcileMembership(activeMembers)
                    comparison.reconcileMembership(activeMembers)
                    let epochAdvanced = checkpoint.payload.checkpoint!.groupEpoch
                        > checkpoints[index - 1].payload.checkpoint!.groupEpoch
                    guard currentConfiguration.hasSameDurableConfiguration(
                        as: comparison,
                        allowingEpochVoiceCredentialRotation: epochAdvanced
                    ) else {
                        throw NoctCordSecureProjectionErrorV2.invalidCheckpoint
                    }
                    if epochAdvanced {
                        projection.adoptVerifiedEpochVoiceCredentials(from: comparison)
                    }
                    projection.noteVerifiedV2Boundary()
                } else {
                    try projection.applyVerifiedV2(
                        checkpoint.payload.event,
                        permittingHistoricalAuthor: true
                    )
                }
                accepted.append(contentsOf: checkpoint.parts.map(\.payload.event))
            } catch {
                throw NoctCordSecureProjectionErrorV2.invalidCheckpoint
            }
            for event in buckets[index + 1].sorted(by: canonicalOrder) {
                do {
                    try projection.applyVerifiedV2(
                        event,
                        permittingHistoricalAuthor: true
                    )
                    accepted.append(event)
                } catch {
                    rejected.append(NoctCordRejectedEvent(
                        eventID: event.id, reason: String(describing: error)
                    ))
                }
            }
        }
        projection.reconcileMembership(activeMembers)
        return NoctCordProjectionResult(
            projection: projection,
            acceptedEvents: accepted,
            rejectedEvents: rejected.sorted { $0.eventID.uuidString < $1.eventID.uuidString }
        )
    }

    private struct VerifiedCheckpoint {
        let outer: GroupConversationEventV2
        let payload: NoctCordSecureEventV2
        let receipt: NoctCordVerifiedTransportReceiptV2
        let digest: Data
    }

    private struct PolicyBoundary {
        let parts: [VerifiedCheckpoint]
        let configuration: [NoctCordEvent]?

        var outer: GroupConversationEventV2 { parts[parts.count - 1].outer }
        var payload: NoctCordSecureEventV2 { parts[parts.count - 1].payload }
        var receipt: NoctCordVerifiedTransportReceiptV2 { parts[parts.count - 1].receipt }
    }

    private static func policyBoundaries(
        _ checkpoints: [VerifiedCheckpoint],
        spaceID: UUID,
        owner: GroupScopedMemberHandleV2,
        allowIncompleteTail: Bool
    ) throws -> [PolicyBoundary] {
        var boundaries: [PolicyBoundary] = []
        var index = 0
        while index < checkpoints.count {
            let first = checkpoints[index]
            let firstPolicy = first.payload.checkpoint!
            if let fragment = firstPolicy.snapshotFragment {
                guard fragment.index == 0 else {
                    throw NoctCordSecureProjectionErrorV2.invalidCheckpoint
                }
                var observed = 0
                while observed < fragment.count,
                      index + observed < checkpoints.count {
                    let part = checkpoints[index + observed]
                    let policy = part.payload.checkpoint!
                    guard let piece = policy.snapshotFragment,
                          piece.seriesID == fragment.seriesID else { break }
                    guard policy.kind == .snapshot,
                          piece.count == fragment.count,
                          piece.index == observed,
                          piece.seriesSeed == fragment.seriesSeed,
                          piece.fullConfigurationDigest
                              == fragment.fullConfigurationDigest,
                          policy.groupEpoch == firstPolicy.groupEpoch,
                          policy.groupTranscriptHash
                              == firstPolicy.groupTranscriptHash else {
                        throw NoctCordSecureProjectionErrorV2.invalidCheckpoint
                    }
                    observed += 1
                }
                if observed < fragment.count {
                    if index + observed == checkpoints.count {
                        if allowIncompleteTail { break }
                        throw NoctCordSecureProjectionErrorV2.missingCheckpoint
                    }
                    let successor = checkpoints[index + observed]
                    let successorPolicy = successor.payload.checkpoint!
                    // A signed Core epoch transition can interrupt a
                    // policy-preserving owner snapshot. No fragment in that
                    // old epoch becomes live policy. A strictly newer epoch
                    // must carry a linked full owner snapshot before normal
                    // projection resumes.
                    guard observed > 0,
                          successorPolicy.groupEpoch > firstPolicy.groupEpoch,
                          successorPolicy.kind == .snapshot,
                          (successorPolicy.snapshotFragment == nil
                            || successorPolicy.snapshotFragment?.index == 0) else {
                        throw NoctCordSecureProjectionErrorV2.invalidCheckpoint
                    }
                    index += observed
                    continue
                }
                let parts = Array(checkpoints[index..<(index + fragment.count)])
                let configuration = parts.flatMap {
                    $0.payload.event.operation.bootstrapEvents ?? []
                }
                guard configurationIsValid(
                    configuration, spaceID: spaceID, owner: owner
                ),
                try NoctCordSnapshotFragmentV2.fullDigest(of: configuration)
                    == fragment.fullConfigurationDigest else {
                    throw NoctCordSecureProjectionErrorV2.invalidCheckpoint
                }
                boundaries.append(PolicyBoundary(
                    parts: parts, configuration: configuration
                ))
                index += fragment.count
            } else {
                let configuration = firstPolicy.kind == .snapshot
                    ? first.payload.event.operation.bootstrapEvents : nil
                if let configuration {
                    guard configurationIsValid(
                        configuration, spaceID: spaceID, owner: owner
                    ) else {
                        throw NoctCordSecureProjectionErrorV2.invalidCheckpoint
                    }
                }
                boundaries.append(PolicyBoundary(
                    parts: [first], configuration: configuration
                ))
                index += 1
            }
        }
        return boundaries
    }

    private static func configurationIsValid(
        _ events: [NoctCordEvent],
        spaceID: UUID,
        owner: GroupScopedMemberHandleV2
    ) -> Bool {
        !events.isEmpty && events.count <= 64 * 128
            && Set(events.map(\.id)).count == events.count
            && events.allSatisfy {
                $0.spaceID == spaceID && $0.author == owner
                    && $0.operation.kind.isBootstrapConfiguration
                    && $0.isStructurallyValid
            }
    }

    private static func orderedCheckpoints(
        _ protected: [NoctCordProtectedCheckpointV2],
        receipts: [UUID: NoctCordVerifiedTransportReceiptV2],
        spaceID: UUID,
        owner: GroupScopedMemberHandleV2,
        allowJoinedSnapshotRoot: Bool
    ) throws -> [VerifiedCheckpoint] {
        var all: [VerifiedCheckpoint] = []
        for item in protected {
            guard item.event.groupID == spaceID,
                  item.event.authorMemberHandle == owner,
                  let receipt = receipts[item.event.id],
                  receiptMatches(receipt, outer: item.event),
                  let payload = try? NoctCordCodec.unwrapSecure(item.event),
                  let checkpoint = payload.checkpoint,
                  checkpoint.owner == owner,
                  checkpoint.spaceID == spaceID,
                  checkpoint.groupEpoch == receipt.epoch,
                  checkpoint.groupTranscriptHash == receipt.transcriptHash,
                  checkpoint.frontiers == item.verifiedFrontiers,
                  checkpoint.frontiers.allSatisfy({ $0.epoch <= checkpoint.groupEpoch }),
                  checkpoint.frontiers.allSatisfy({ frontier in
                      guard frontier.nextCounter > 0 else { return true }
                      let preceding = receipts.values.first(where: {
                          $0.epoch == frontier.epoch
                              && $0.credential == frontier.credential
                              && $0.messageCounter == frontier.nextCounter - 1
                      })
                      return preceding.map({
                          $0.prefixDigest == frontier.prefixDigest
                      }) ?? true
                  }),
                  let ownerHead = checkpoint.frontiers.first(where: {
                      $0.epoch == receipt.epoch && $0.credential == receipt.credential
                  }),
                  ownerHead.nextCounter == receipt.messageCounter,
                  ownerHead.prefixDigest == receipt.previousPrefixDigest,
                  let digest = try? payload.canonicalDigest() else {
                throw NoctCordSecureProjectionErrorV2.invalidCheckpoint
            }
            all.append(VerifiedCheckpoint(
                outer: item.event,
                payload: payload,
                receipt: receipt,
                digest: digest
            ))
        }
        guard Set(all.map(\.outer.id)).count == all.count,
              Set(all.map(\.digest)).count == all.count else {
            throw NoctCordSecureProjectionErrorV2.invalidCheckpoint
        }
        let explicitRoots = all.filter {
            $0.payload.checkpoint?.previousCheckpointDigest == nil
        }
        let genesis: VerifiedCheckpoint?
        if let explicit = explicitRoots.onlyElement {
            genesis = explicit
        } else if allowJoinedSnapshotRoot && explicitRoots.isEmpty {
            let digests = Set(all.map(\.digest))
            genesis = all.filter { entry in
                entry.payload.checkpoint?.kind == .snapshot
                    && entry.payload.checkpoint?.previousCheckpointDigest.map {
                        !digests.contains($0)
                    } == true
            }.onlyElement
        } else {
            genesis = nil
        }
        guard let genesis,
              genesis.payload.checkpoint?.kind == .snapshot,
              genesis.payload.checkpoint?.frontiers.allSatisfy({
                  $0.epoch == genesis.receipt.epoch
                      && $0.transcriptHash == genesis.receipt.transcriptHash
              }) == true else {
            throw NoctCordSecureProjectionErrorV2.invalidCheckpoint
        }
        var ordered = [genesis]
        var seen = Set([genesis.outer.id])
        while ordered.count < all.count {
            let previous = ordered[ordered.count - 1]
            guard let next = all.filter({
                $0.payload.checkpoint?.previousCheckpointDigest == previous.digest
            }).onlyElement,
            let oldPolicy = previous.payload.checkpoint,
            let newPolicy = next.payload.checkpoint,
            (newPolicy.kind == .delta || newPolicy.kind == .snapshot),
            newPolicy.groupEpoch >= oldPolicy.groupEpoch,
            (next.payload.event.operation.kind != .bootstrapRequested
                || newPolicy.groupEpoch > oldPolicy.groupEpoch),
            (newPolicy.groupEpoch != oldPolicy.groupEpoch
                || newPolicy.groupTranscriptHash == oldPolicy.groupTranscriptHash),
            !seen.contains(next.outer.id),
            frontiersAdvance(from: oldPolicy.frontiers, to: newPolicy.frontiers,
                             at: newPolicy.groupEpoch,
                             after: oldPolicy.groupEpoch) else {
                throw NoctCordSecureProjectionErrorV2.invalidCheckpoint
            }
            ordered.append(next)
            seen.insert(next.outer.id)
        }
        return ordered
    }

    private static func frontiersAdvance(
        from old: [NoctCordCredentialFrontierV2],
        to new: [NoctCordCredentialFrontierV2],
        at epoch: UInt64,
        after previousEpoch: UInt64
    ) -> Bool {
        let oldByKey = Dictionary(uniqueKeysWithValues: old.map {
            (frontierKey(epoch: $0.epoch, credential: $0.credential), $0)
        })
        let newByKey = Dictionary(uniqueKeysWithValues: new.map {
            (frontierKey(epoch: $0.epoch, credential: $0.credential), $0)
        })
        for (key, previous) in oldByKey {
            // A signed group epoch transition orders every old-epoch event
            // before this checkpoint. Its new frontier need not carry old
            // credential heads forever; the older pinned checkpoint remains
            // the proof for retained historical events.
            if previous.epoch < epoch && newByKey[key] == nil { continue }
            guard let current = newByKey[key],
                  current.transcriptHash == previous.transcriptHash,
                  current.nextCounter >= previous.nextCounter,
                  (current.nextCounter != previous.nextCounter
                      || current.prefixDigest == previous.prefixDigest) else {
                return false
            }
        }
        for (key, current) in newByKey where oldByKey[key] == nil {
            guard current.epoch == epoch,
                  (epoch > previousEpoch || current.nextCounter == 0) else {
                return false
            }
        }
        return true
    }

    private static func policyInterval(
        for receipt: NoctCordVerifiedTransportReceiptV2,
        checkpoints: [PolicyBoundary]
    ) -> Int {
        var interval = 0
        for entry in checkpoints {
            let checkpoint = entry.payload.checkpoint!
            if receipt.epoch < checkpoint.groupEpoch { break }
            if receipt.epoch > checkpoint.groupEpoch {
                interval += 1
                continue
            }
            if let frontier = checkpoint.frontiers.first(where: {
                $0.epoch == receipt.epoch && $0.credential == receipt.credential
            }) {
                if receipt.messageCounter < frontier.nextCounter { break }
            }
            interval += 1
        }
        return interval
    }

    private static func receiptMatches(
        _ receipt: NoctCordVerifiedTransportReceiptV2,
        outer: GroupConversationEventV2
    ) -> Bool {
        receipt.isStructurallyValid
            && receipt.isAccepted
            && receipt.eventID == outer.id
            && receipt.groupID == outer.groupID
            && receipt.eventDigest == outer.digest
            && outer.kind == .application
            && receipt.credential == outer.authorCredentialHandle
    }

    private static func frontierKey(
        epoch: UInt64,
        credential: GroupScopedCredentialHandleV2
    ) -> String {
        "\(epoch):\(credential.rawValue)"
    }

    private static func canonicalOrder(_ lhs: NoctCordEvent, _ rhs: NoctCordEvent) -> Bool {
        if lhs.logicalClock != rhs.logicalClock { return lhs.logicalClock < rhs.logicalClock }
        if lhs.createdAt != rhs.createdAt { return lhs.createdAt < rhs.createdAt }
        return lhs.id.uuidString < rhs.id.uuidString
    }
}

private extension Array {
    var onlyElement: Element? { count == 1 ? first : nil }
}
