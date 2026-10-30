import CryptoKit
import Foundation
@preconcurrency import NoctweaveCore

/// The Core-authenticated transport position observed by the owner before a
/// policy transition. `nextCounter == 0` names the empty sender prefix.
/// A checkpoint never derives this value from an application clock or relay
/// arrival order.
public struct NoctCordCredentialFrontierV2: Codable, Equatable, Sendable {
    public let epoch: UInt64
    public let transcriptHash: Data
    public let credential: GroupScopedCredentialHandleV2
    public let nextCounter: UInt64
    public let prefixDigest: Data

    public init(
        epoch: UInt64,
        transcriptHash: Data,
        credential: GroupScopedCredentialHandleV2,
        nextCounter: UInt64,
        prefixDigest: Data
    ) {
        self.epoch = epoch
        self.transcriptHash = transcriptHash
        self.credential = credential
        self.nextCounter = nextCounter
        self.prefixDigest = prefixDigest
    }

    public var isStructurallyValid: Bool {
        epoch > 0 && transcriptHash.count == SHA256.byteCount
            && credential.isStructurallyValid
            && prefixDigest.count == SHA256.byteCount
    }
}

public enum NoctCordPolicyCheckpointKindV2: String, Codable, Equatable, Sendable {
    case snapshot
    case delta
}

/// One part of an owner-signed atomic configuration snapshot. Every part is
/// independently Core-bound; no policy change takes effect until the complete
/// consecutive series and its aggregate digest have been verified.
public struct NoctCordSnapshotFragmentV2: Codable, Equatable, Sendable {
    public static let maximumParts = 64

    public let seriesID: UUID
    public let index: Int
    public let count: Int
    public let fullConfigurationDigest: Data
    public let seriesSeed: Data

    public init(
        seriesID: UUID,
        index: Int,
        count: Int,
        fullConfigurationDigest: Data,
        seriesSeed: Data
    ) {
        self.seriesID = seriesID
        self.index = index
        self.count = count
        self.fullConfigurationDigest = fullConfigurationDigest
        self.seriesSeed = seriesSeed
    }

    public var isStructurallyValid: Bool {
        count >= 2 && count <= Self.maximumParts
            && index >= 0 && index < count
            && fullConfigurationDigest.count == SHA256.byteCount
            && seriesSeed.count == SHA256.byteCount
    }

    public static func fullDigest(of configuration: [NoctCordEvent]) throws -> Data {
        let encoded = try NoctweaveCoder.encode(configuration, sortedKeys: true)
        return Data(SHA256.hash(
            data: Data("NoctCord/snapshot-series/v2\0".utf8) + encoded
        ))
    }
}

/// An owner-signed authorization boundary. Core's durable protected-event
/// binding must attest this exact frontier set before the checkpoint can be
/// used by a projector. A snapshot starts v2 policy; each delta mutates it
/// without dropping independently authenticated message state.
public struct NoctCordPolicyCheckpointV2: Codable, Equatable, Sendable {
    public static let maximumFrontiers = 128

    public let spaceID: UUID
    public let owner: GroupScopedMemberHandleV2
    public let kind: NoctCordPolicyCheckpointKindV2
    public let groupEpoch: UInt64
    public let groupTranscriptHash: Data
    public let previousCheckpointDigest: Data?
    public let configurationDigest: Data
    public let frontiers: [NoctCordCredentialFrontierV2]
    public let snapshotFragment: NoctCordSnapshotFragmentV2?

    public init(
        spaceID: UUID,
        owner: GroupScopedMemberHandleV2,
        kind: NoctCordPolicyCheckpointKindV2 = .snapshot,
        groupEpoch: UInt64,
        groupTranscriptHash: Data,
        previousCheckpointDigest: Data?,
        configurationDigest: Data,
        frontiers: [NoctCordCredentialFrontierV2],
        snapshotFragment: NoctCordSnapshotFragmentV2? = nil
    ) {
        self.spaceID = spaceID
        self.owner = owner
        self.kind = kind
        self.groupEpoch = groupEpoch
        self.groupTranscriptHash = groupTranscriptHash
        self.previousCheckpointDigest = previousCheckpointDigest
        self.configurationDigest = configurationDigest
        self.frontiers = frontiers
        self.snapshotFragment = snapshotFragment
    }

    public var isStructurallyValid: Bool {
        owner.isStructurallyValid
            && groupEpoch > 0
            && groupTranscriptHash.count == SHA256.byteCount
            && (previousCheckpointDigest == nil
                || previousCheckpointDigest?.count == SHA256.byteCount)
            && configurationDigest.count == SHA256.byteCount
            && (snapshotFragment == nil
                || (kind == .snapshot
                    && snapshotFragment?.isStructurallyValid == true))
            && !frontiers.isEmpty
            && frontiers.count <= Self.maximumFrontiers
            && frontiers.allSatisfy(\.isStructurallyValid)
            && frontiers == frontiers.sorted(by: Self.frontierOrder)
            && Set(frontiers.map { "\($0.epoch):\($0.credential.rawValue)" }).count
                == frontiers.count
    }

    public static func frontierOrder(
        _ lhs: NoctCordCredentialFrontierV2,
        _ rhs: NoctCordCredentialFrontierV2
    ) -> Bool {
        if lhs.epoch != rhs.epoch { return lhs.epoch < rhs.epoch }
        return lhs.credential.rawValue < rhs.credential.rawValue
    }
}

/// A signed NoctCord v2 payload. Transport position comes only from Core's
/// verified envelope receipt; the payload cannot claim its own position.
public struct NoctCordSecureEventV2: Codable, Equatable, Sendable {
    public static let version = 2

    public let version: Int
    public let event: NoctCordEvent
    public let credential: GroupScopedCredentialHandleV2
    public let checkpoint: NoctCordPolicyCheckpointV2?

    public init(
        event: NoctCordEvent,
        credential: GroupScopedCredentialHandleV2,
        checkpoint: NoctCordPolicyCheckpointV2? = nil
    ) {
        version = Self.version
        self.event = event
        self.credential = credential
        self.checkpoint = checkpoint
    }

    public var isStructurallyValid: Bool {
        guard version == Self.version,
              event.isStructurallyValid,
              credential.isStructurallyValid else {
            return false
        }
        guard let checkpoint else { return true }
        guard checkpoint.isStructurallyValid,
              checkpoint.spaceID == event.spaceID,
              checkpoint.owner == event.author,
              (checkpoint.kind == .snapshot
                  || checkpoint.previousCheckpointDigest != nil),
              let encoded = try? Self.checkpointConfigurationBytes(
                  event: event, kind: checkpoint.kind
              ),
              Data(SHA256.hash(data: encoded)) == checkpoint.configurationDigest,
              checkpoint.frontiers.contains(where: {
                  $0.epoch == checkpoint.groupEpoch
                      && $0.transcriptHash == checkpoint.groupTranscriptHash
                      && $0.credential == credential
              }) else {
            return false
        }
        return true
    }

    public func canonicalDigest() throws -> Data {
        guard isStructurallyValid else { throw NoctCordCodecError.invalidEvent }
        let prefix = Data("NoctCord/secure-event/v2\0".utf8)
        return Data(SHA256.hash(
            data: prefix + (try NoctweaveCoder.encode(self, sortedKeys: true))
        ))
    }

    private static func checkpointConfigurationBytes(
        event: NoctCordEvent,
        kind: NoctCordPolicyCheckpointKindV2
    ) throws -> Data {
        switch kind {
        case .snapshot:
            guard event.operation.kind == .bootstrapApplied,
                  let configuration = event.operation.bootstrapEvents else {
                throw NoctCordCodecError.invalidEvent
            }
            return try NoctweaveCoder.encode(configuration, sortedKeys: true)
        case .delta:
            guard event.operation.kind.isBootstrapConfiguration
                    || event.operation.kind == .bootstrapRequested else {
                throw NoctCordCodecError.invalidEvent
            }
            return try NoctweaveCoder.encode(event.operation, sortedKeys: true)
        }
    }
}
