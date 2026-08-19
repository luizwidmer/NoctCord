import Foundation

public enum NoctCordMediaSignalKind: String, Codable, CaseIterable, Sendable {
    case join
    case leave
    case offer
    case answer
    case iceCandidate
    case microphoneState
    case deafenState
    case screenShareStarted
    case screenShareStopped
}

public struct NoctCordMediaICECandidate: Codable, Equatable, Sendable {
    public static let maximumSDPBytes = 8 * 1_024
    public static let maximumSDPMidBytes = 256

    public let sdp: String
    public let sdpMid: String?
    public let sdpMLineIndex: Int32

    public init(sdp: String, sdpMid: String?, sdpMLineIndex: Int32) {
        self.sdp = sdp
        self.sdpMid = sdpMid
        self.sdpMLineIndex = sdpMLineIndex
    }

    public var isStructurallyValid: Bool {
        !sdp.isEmpty
            && sdp.utf8.count <= Self.maximumSDPBytes
            && !sdp.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
            && sdpMLineIndex >= 0
            && (sdpMid.map {
                !$0.isEmpty
                    && $0.utf8.count <= Self.maximumSDPMidBytes
                    && !$0.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
            } ?? true)
    }
}

/// Control-plane data only. Media samples never belong in a signaling envelope.
public struct NoctCordMediaSignal: Codable, Equatable, Sendable {
    public static let maximumSessionDescriptionBytes = 256 * 1_024
    public let kind: NoctCordMediaSignalKind
    public let value: String?
    public let iceCandidate: NoctCordMediaICECandidate?
    public let track: NoctCordScreenShareTrack?

    private init(
        kind: NoctCordMediaSignalKind,
        value: String? = nil,
        iceCandidate: NoctCordMediaICECandidate? = nil,
        track: NoctCordScreenShareTrack? = nil
    ) {
        self.kind = kind
        self.value = value
        self.iceCandidate = iceCandidate
        self.track = track
    }

    public static let join = Self(kind: .join)
    public static let leave = Self(kind: .leave)
    public static func offer(_ sdp: String) -> Self { Self(kind: .offer, value: sdp) }
    public static func answer(_ sdp: String) -> Self { Self(kind: .answer, value: sdp) }
    public static func iceCandidate(_ candidate: String) -> Self { Self(kind: .iceCandidate, value: candidate) }
    public static func iceCandidate(_ candidate: NoctCordMediaICECandidate) -> Self {
        Self(kind: .iceCandidate, iceCandidate: candidate)
    }
    public static func microphone(enabled: Bool) -> Self {
        Self(kind: .microphoneState, value: enabled ? "enabled" : "disabled")
    }
    public static func deafen(_ enabled: Bool) -> Self {
        Self(kind: .deafenState, value: enabled ? "enabled" : "disabled")
    }
    public static func screenShareStarted(_ track: NoctCordScreenShareTrack) -> Self {
        Self(kind: .screenShareStarted, track: track)
    }
    public static let screenShareStopped = Self(kind: .screenShareStopped)

    public var isStructurallyValid: Bool {
        let valueIsValid = value.map {
            !$0.isEmpty
                && $0.utf8.count <= Self.maximumSessionDescriptionBytes
                && !$0.unicodeScalars.contains(where: { $0.value == 0 })
        } ?? true
        switch kind {
        case .join, .leave, .screenShareStopped:
            return value == nil && iceCandidate == nil && track == nil
        case .offer, .answer, .iceCandidate:
            if kind == .iceCandidate {
                let legacyCandidateIsValid = value.map {
                    !$0.isEmpty
                        && $0.utf8.count <= NoctCordMediaICECandidate.maximumSDPBytes
                        && !$0.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
                } ?? false
                let structuredCandidateIsValid = iceCandidate?.isStructurallyValid == true
                return track == nil
                    && (legacyCandidateIsValid != structuredCandidateIsValid)
            }
            return valueIsValid && value != nil && iceCandidate == nil && track == nil
        case .microphoneState, .deafenState:
            return (value == "enabled" || value == "disabled") && iceCandidate == nil && track == nil
        case .screenShareStarted:
            return value == nil
                && iceCandidate == nil
                && track?.cameraIndependent == true
                && track?.trackID.isStructurallyValid == true
        }
    }
}

public struct NoctCordMediaSignalEnvelope: Codable, Equatable, Sendable {
    public static let schema = "org.noctcord.media-signal"
    public static let version = 1

    public let schema: String
    public let version: Int
    public let roomID: NoctCordMediaRoomID
    public let sender: NoctCordMediaParticipantID
    public let recipient: NoctCordMediaParticipantID?
    public let sequence: UInt64
    public let timestampMilliseconds: Int64
    public let signal: NoctCordMediaSignal

    public init(
        roomID: NoctCordMediaRoomID,
        sender: NoctCordMediaParticipantID,
        recipient: NoctCordMediaParticipantID? = nil,
        sequence: UInt64,
        timestampMilliseconds: Int64,
        signal: NoctCordMediaSignal
    ) throws {
        self.schema = Self.schema
        self.version = Self.version
        self.roomID = roomID
        self.sender = sender
        self.recipient = recipient
        self.sequence = sequence
        self.timestampMilliseconds = timestampMilliseconds
        self.signal = signal
        guard isStructurallyValid else {
            throw NoctCordMediaError.invalidEnvelope("signal envelope failed structural validation")
        }
    }

    public var isStructurallyValid: Bool {
        schema == Self.schema
            && version == Self.version
            && roomID.isStructurallyValid
            && sender.isStructurallyValid
            && (recipient?.isStructurallyValid ?? true)
            && sequence > 0
            && timestampMilliseconds >= 0
            && signal.isStructurallyValid
    }
}

public enum NoctCordMediaSignalingCodec {
    public static func encode(_ envelope: NoctCordMediaSignalEnvelope) throws -> Data {
        guard envelope.isStructurallyValid else {
            throw NoctCordMediaError.invalidEnvelope("cannot encode invalid envelope")
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(envelope)
        guard data.count <= 512 * 1024 else {
            throw NoctCordMediaError.invalidEnvelope("encoded envelope exceeds 512 KiB")
        }
        return data
    }

    public static func decode(_ data: Data) throws -> NoctCordMediaSignalEnvelope {
        guard !data.isEmpty, data.count <= 512 * 1024 else {
            throw NoctCordMediaError.invalidEnvelope("encoded envelope exceeds 512 KiB")
        }
        do {
            let envelope = try JSONDecoder().decode(NoctCordMediaSignalEnvelope.self, from: data)
            guard envelope.isStructurallyValid,
                  try encode(envelope) == data else {
                throw NoctCordMediaError.invalidEnvelope("decoded envelope failed structural validation")
            }
            return envelope
        } catch let error as NoctCordMediaError {
            throw error
        } catch {
            throw NoctCordMediaError.invalidEnvelope("invalid JSON signaling envelope")
        }
    }
}
