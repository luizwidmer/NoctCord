import Foundation

public enum NoctCordMediaDriverEvent: Equatable, Sendable {
    case participantJoined(NoctCordMediaParticipant)
    case participantLeft(NoctCordMediaParticipantID)
    case signal(NoctCordMediaSignalEnvelope)
    case microphoneState(participant: NoctCordMediaParticipantID, enabled: Bool)
    case deafenState(participant: NoctCordMediaParticipantID, enabled: Bool)
    case peerConnectionState(participant: NoctCordMediaParticipantID, state: String)
    case screenShareStarted(participant: NoctCordMediaParticipantID, track: NoctCordScreenShareTrack)
    case screenShareStopped(participant: NoctCordMediaParticipantID)
    case screenShareFailed(participant: NoctCordMediaParticipantID, error: NoctCordMediaError)
    case remoteVideoTrackAdded(participant: NoctCordMediaParticipantID, track: NoctCordMediaRemoteVideoTrack)
    case remoteVideoTrackRemoved(participant: NoctCordMediaParticipantID, trackID: String)
}

public protocol NoctCordMediaSignalingSink: Sendable {
    func send(_ envelope: NoctCordMediaSignalEnvelope) async throws
}

public struct NoctCordDiscardingSignalingSink: NoctCordMediaSignalingSink {
    public init() {}

    public func send(_ envelope: NoctCordMediaSignalEnvelope) async throws {
        _ = envelope
    }
}

public protocol NoctCordMediaDriver: Sendable {
    func makeSession(
        configuration: NoctCordMediaRoomConfiguration,
        eventHandler: @escaping @Sendable (NoctCordMediaDriverEvent) -> Void,
        signalingSink: any NoctCordMediaSignalingSink
    ) async throws -> any NoctCordMediaDriverSession
}

public protocol NoctCordMediaDriverSession: Sendable {
    func join() async throws
    func leave() async
    func send(_ signal: NoctCordMediaSignal, to recipient: NoctCordMediaParticipantID?) async throws -> NoctCordMediaSignalEnvelope
    func handleIncomingSignal(_ envelope: NoctCordMediaSignalEnvelope) async throws
    func setMicrophoneEnabled(_ enabled: Bool) async throws
    func setDeafened(_ enabled: Bool) async throws
    func publishScreenShare(_ track: NoctCordScreenShareTrack) async throws
    func stopScreenShare() async throws
}

public actor NoctCordMediaRoom {
    private let configuration: NoctCordMediaRoomConfiguration
    private let driver: any NoctCordMediaDriver
    private let permissionProvider: any NoctCordMediaPermissionProvider
    private let signalingSink: any NoctCordMediaSignalingSink
    private var driverSession: (any NoctCordMediaDriverSession)?
    private var state: NoctCordMediaRoomState = .idle
    private var participants: [NoctCordMediaParticipantID: NoctCordMediaParticipant] = [:]
    private var microphoneMuted = false
    private var microphonePermissionGranted = false
    private var deafened = false
    private var remoteMicrophoneEnabled: [NoctCordMediaParticipantID: Bool] = [:]
    private var remoteDeafened: [NoctCordMediaParticipantID: Bool] = [:]
    private var remoteConnectionStates: [NoctCordMediaParticipantID: String] = [:]
    private var localScreenShare: NoctCordScreenShareTrack?
    private var screenShareError: NoctCordMediaError?
    private var remoteScreenShares: [NoctCordMediaParticipantID: NoctCordScreenShareTrack] = [:]
    private var remoteVideoTracks: [NoctCordMediaParticipantID: NoctCordMediaRemoteVideoTrack] = [:]
    private var lastReceivedSequence: [NoctCordMediaParticipantID: UInt64] = [:]
    private var lastJoinTimestampMilliseconds: [NoctCordMediaParticipantID: Int64] = [:]

    public init(
        configuration: NoctCordMediaRoomConfiguration,
        driver: any NoctCordMediaDriver,
        permissionProvider: any NoctCordMediaPermissionProvider = NoctCordUnavailablePermissionProvider(),
        signalingSink: any NoctCordMediaSignalingSink = NoctCordDiscardingSignalingSink()
    ) {
        self.configuration = configuration
        self.driver = driver
        self.permissionProvider = permissionProvider
        self.signalingSink = signalingSink
        self.microphoneMuted = !configuration.wantsMicrophone
        self.participants[configuration.participant.id] = configuration.participant
    }

    public func snapshot() -> NoctCordMediaRoomSnapshot {
        NoctCordMediaRoomSnapshot(
            state: state,
            localParticipant: configuration.participant,
            participants: Array(participants.values),
            microphoneMuted: microphoneMuted,
            deafened: deafened,
            remoteMicrophoneEnabled: remoteMicrophoneEnabled,
            remoteDeafened: remoteDeafened,
            remoteConnectionStates: remoteConnectionStates,
            localScreenShare: localScreenShare,
            remoteScreenShares: remoteScreenShares,
            remoteVideoTracks: remoteVideoTracks,
            screenShareError: screenShareError,
            lastReceivedSequence: lastReceivedSequence
        )
    }

    public func join() async throws {
        guard case .idle = state else {
            throw NoctCordMediaError.invalidState("room can only join from idle")
        }
        state = .joining
        var joiningSession: (any NoctCordMediaDriverSession)?
        do {
            try configuration.validate()
            screenShareError = nil
            if configuration.wantsMicrophone {
                try await requestMicrophonePermission()
            }
            try requireJoining()
            let session = try await driver.makeSession(
                configuration: configuration,
                eventHandler: { [weak self] event in
                    Task { await self?.receive(event) }
                },
                signalingSink: signalingSink
            )
            joiningSession = session
            try requireJoining()
            driverSession = session
            try await session.join()
            try requireJoining()
            state = .joined
        } catch {
            await joiningSession?.leave()
            driverSession = nil
            switch state {
            case .leaving, .left: break
            default:
                state = .failed((error as? NoctCordMediaError) ?? .transportFailure(error.localizedDescription))
            }
            throw error
        }
    }

    public func leave() async {
        guard driverSession != nil else {
            state = .left
            return
        }
        state = .leaving
        await driverSession?.leave()
        driverSession = nil
        state = .left
        localScreenShare = nil
        remoteScreenShares.removeAll()
        remoteVideoTracks.removeAll()
        screenShareError = nil
        lastReceivedSequence.removeAll()
        lastJoinTimestampMilliseconds.removeAll()
    }

    public func setMicrophoneMuted(_ muted: Bool) async throws {
        try requireJoined()
        if !muted && !microphonePermissionGranted {
            try await requestMicrophonePermission()
            try requireJoined()
        }
        try await driverSession?.setMicrophoneEnabled(!muted)
        try requireJoined()
        microphoneMuted = muted
    }

    public func setDeafened(_ deafened: Bool) async throws {
        try requireJoined()
        try await driverSession?.setDeafened(deafened)
        self.deafened = deafened
    }

    public func startScreenShare(using source: any NoctCordScreenShareSource) async throws {
        try requireJoined()
        screenShareError = nil
        let permission = try await source.requestAccess()
        guard permission == .granted || permission == .requiresUserAction else {
            throw permission == .denied
                ? NoctCordMediaError.permissionDenied(.screenCapture)
                : NoctCordMediaError.permissionUnavailable(.screenCapture)
        }
        let track = try await source.makeTrack()
        try requireJoined()
        guard let driverSession else {
            throw NoctCordMediaError.invalidState("room is not joined")
        }
        try await driverSession.publishScreenShare(track)
        do {
            try requireJoined()
        } catch {
            try? await driverSession.stopScreenShare()
            throw error
        }
        localScreenShare = track
    }

    public func stopScreenShare() async throws {
        try requireJoined()
        try await driverSession?.stopScreenShare()
        localScreenShare = nil
        screenShareError = nil
    }

    /// Entry point for a relay or application transport that delivers an
    /// already-authenticated signaling envelope outside the media driver.
    /// Invalid, misaddressed, and replayed envelopes are ignored.
    public func handleIncomingSignal(_ envelope: NoctCordMediaSignalEnvelope) async throws {
        guard accept(envelope) else { return }
        try await driverSession?.handleIncomingSignal(envelope)
        apply(envelope.signal, from: envelope.sender)
    }

    @discardableResult
    public func send(_ signal: NoctCordMediaSignal, to recipient: NoctCordMediaParticipantID? = nil) async throws -> NoctCordMediaSignalEnvelope {
        try requireJoined()
        guard let driverSession else {
            throw NoctCordMediaError.invalidState("room is not joined")
        }
        return try await driverSession.send(signal, to: recipient)
    }

    private func requireJoined() throws {
        guard case .joined = state, driverSession != nil else {
            throw NoctCordMediaError.invalidState("room is not joined")
        }
    }

    private func requireJoining() throws {
        guard case .joining = state else {
            throw NoctCordMediaError.invalidState("room was left while joining")
        }
    }

    private func requestMicrophonePermission() async throws {
        let permission = try await permissionProvider.request([.microphone]).microphone
        guard permission == .granted else {
            throw permission == .denied
                ? NoctCordMediaError.permissionDenied(.microphone)
                : NoctCordMediaError.permissionUnavailable(.microphone)
        }
        microphonePermissionGranted = true
    }

    private func receive(_ event: NoctCordMediaDriverEvent) {
        switch event {
        case let .participantJoined(participant):
            guard participant.id != configuration.participant.id else { return }
            participants[participant.id] = participant
        case let .participantLeft(participant):
            participants.removeValue(forKey: participant)
            remoteScreenShares.removeValue(forKey: participant)
            remoteMicrophoneEnabled.removeValue(forKey: participant)
            remoteDeafened.removeValue(forKey: participant)
            remoteConnectionStates.removeValue(forKey: participant)
            remoteVideoTracks.removeValue(forKey: participant)
            lastReceivedSequence.removeValue(forKey: participant)
            lastJoinTimestampMilliseconds.removeValue(forKey: participant)
        case let .signal(envelope):
            guard envelope.roomID == configuration.roomID,
                  envelope.sender != configuration.participant.id,
                  envelope.recipient == nil || envelope.recipient == configuration.participant.id,
                  envelope.isStructurallyValid else { return }
            guard accept(envelope) else { return }
        case let .microphoneState(participant, enabled):
            guard participant != configuration.participant.id else { return }
            participants[participant] = participants[participant] ?? NoctCordMediaParticipant(id: participant)
            remoteMicrophoneEnabled[participant] = enabled
        case let .deafenState(participant, enabled):
            guard participant != configuration.participant.id else { return }
            participants[participant] = participants[participant] ?? NoctCordMediaParticipant(id: participant)
            remoteDeafened[participant] = enabled
        case let .peerConnectionState(participant, connectionState):
            guard participant != configuration.participant.id else { return }
            participants[participant] = participants[participant] ?? NoctCordMediaParticipant(id: participant)
            remoteConnectionStates[participant] = connectionState
        case let .screenShareStarted(participant, track):
            guard participant != configuration.participant.id else { return }
            remoteScreenShares[participant] = track
        case let .screenShareStopped(participant):
            remoteScreenShares.removeValue(forKey: participant)
        case let .screenShareFailed(participant, error):
            guard participant == configuration.participant.id else { return }
            localScreenShare = nil
            screenShareError = error
        case let .remoteVideoTrackAdded(participant, track):
            guard participant != configuration.participant.id else { return }
            participants[participant] = participants[participant] ?? NoctCordMediaParticipant(id: participant)
            remoteVideoTracks[participant] = track
        case let .remoteVideoTrackRemoved(participant, trackID):
            guard remoteVideoTracks[participant]?.trackID == trackID else { return }
            remoteVideoTracks.removeValue(forKey: participant)
        }
    }

    private func accept(_ envelope: NoctCordMediaSignalEnvelope) -> Bool {
        guard envelope.roomID == configuration.roomID,
              envelope.sender != configuration.participant.id,
              envelope.recipient == nil || envelope.recipient == configuration.participant.id,
              envelope.isStructurallyValid else {
            return false
        }

        // A participant keeps the same group-scoped identifier when its app
        // restarts, while each fresh WebRTC session begins its sequence at 1.
        // Treat a newer join as an authenticated session boundary so valid
        // reconnect signaling is not mistaken for a replay. Replayed joins
        // cannot roll the boundary backwards.
        if envelope.signal.kind == .join, envelope.sequence == 1 {
            guard envelope.timestampMilliseconds
                    > (lastJoinTimestampMilliseconds[envelope.sender] ?? -1) else {
                return false
            }
            lastJoinTimestampMilliseconds[envelope.sender] = envelope.timestampMilliseconds
            lastReceivedSequence[envelope.sender] = envelope.sequence
            return true
        }

        guard envelope.sequence > (lastReceivedSequence[envelope.sender] ?? 0) else {
            return false
        }
        lastReceivedSequence[envelope.sender] = envelope.sequence
        return true
    }

    private func apply(_ signal: NoctCordMediaSignal, from sender: NoctCordMediaParticipantID) {
        switch signal.kind {
        case .screenShareStarted:
            if let track = signal.track { remoteScreenShares[sender] = track }
        case .screenShareStopped:
            remoteScreenShares.removeValue(forKey: sender)
        default:
            break
        }
    }
}
