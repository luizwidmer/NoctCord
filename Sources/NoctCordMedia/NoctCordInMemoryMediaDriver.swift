import Foundation

public actor NoctCordInMemoryMediaNetwork {
    private struct Endpoint {
        let participant: NoctCordMediaParticipant
        let handler: @Sendable (NoctCordMediaDriverEvent) -> Void
    }

    private var rooms: [NoctCordMediaRoomID: [NoctCordMediaParticipantID: Endpoint]] = [:]

    public init() {}

    fileprivate func join(
        configuration: NoctCordMediaRoomConfiguration,
        handler: @escaping @Sendable (NoctCordMediaDriverEvent) -> Void
    ) throws {
        var endpoints = rooms[configuration.roomID, default: [:]]
        guard endpoints[configuration.participant.id] == nil else {
            throw NoctCordMediaError.transportFailure("participant is already joined")
        }
        let existing = endpoints.values.map(\.participant)
        endpoints[configuration.participant.id] = Endpoint(participant: configuration.participant, handler: handler)
        rooms[configuration.roomID] = endpoints

        for participant in existing {
            handler(.participantJoined(participant))
        }
        for endpoint in endpoints.values where endpoint.participant.id != configuration.participant.id {
            endpoint.handler(.participantJoined(configuration.participant))
        }
    }

    fileprivate func leave(roomID: NoctCordMediaRoomID, participantID: NoctCordMediaParticipantID) {
        guard var endpoints = rooms[roomID] else { return }
        endpoints.removeValue(forKey: participantID)
        rooms[roomID] = endpoints.isEmpty ? nil : endpoints
        for endpoint in endpoints.values {
            endpoint.handler(.participantLeft(participantID))
        }
    }

    fileprivate func send(
        roomID: NoctCordMediaRoomID,
        sender: NoctCordMediaParticipantID,
        envelope: NoctCordMediaSignalEnvelope
    ) throws {
        guard let endpoints = rooms[roomID], endpoints[sender] != nil else {
            throw NoctCordMediaError.transportFailure("sender is not joined")
        }
        for endpoint in endpoints.values where endpoint.participant.id != sender {
            if envelope.recipient == nil || envelope.recipient == endpoint.participant.id {
                endpoint.handler(.signal(envelope))
            }
        }
    }

    fileprivate func broadcast(
        roomID: NoctCordMediaRoomID,
        sender: NoctCordMediaParticipantID,
        event: NoctCordMediaDriverEvent
    ) throws {
        guard let endpoints = rooms[roomID], endpoints[sender] != nil else {
            throw NoctCordMediaError.transportFailure("sender is not joined")
        }
        for endpoint in endpoints.values where endpoint.participant.id != sender {
            endpoint.handler(event)
        }
    }
}

public struct NoctCordInMemoryMediaDriver: NoctCordMediaDriver {
    private let network: NoctCordInMemoryMediaNetwork

    public init(network: NoctCordInMemoryMediaNetwork = NoctCordInMemoryMediaNetwork()) {
        self.network = network
    }

    public func makeSession(
        configuration: NoctCordMediaRoomConfiguration,
        eventHandler: @escaping @Sendable (NoctCordMediaDriverEvent) -> Void,
        signalingSink: any NoctCordMediaSignalingSink
    ) async throws -> any NoctCordMediaDriverSession {
        NoctCordInMemoryMediaSession(
            configuration: configuration,
            network: network,
            eventHandler: eventHandler,
            signalingSink: signalingSink
        )
    }
}

private actor NoctCordInMemoryMediaSession: NoctCordMediaDriverSession {
    private let configuration: NoctCordMediaRoomConfiguration
    private let network: NoctCordInMemoryMediaNetwork
    private let eventHandler: @Sendable (NoctCordMediaDriverEvent) -> Void
    private let signalingSink: any NoctCordMediaSignalingSink
    private var nextSequence: UInt64 = 1
    private var joined = false

    init(
        configuration: NoctCordMediaRoomConfiguration,
        network: NoctCordInMemoryMediaNetwork,
        eventHandler: @escaping @Sendable (NoctCordMediaDriverEvent) -> Void,
        signalingSink: any NoctCordMediaSignalingSink
    ) {
        self.configuration = configuration
        self.network = network
        self.eventHandler = eventHandler
        self.signalingSink = signalingSink
    }

    func join() async throws {
        guard !joined else { return }
        try await network.join(configuration: configuration, handler: eventHandler)
        joined = true
    }

    func leave() async {
        guard joined else { return }
        await network.leave(roomID: configuration.roomID, participantID: configuration.participant.id)
        joined = false
    }

    func send(_ signal: NoctCordMediaSignal, to recipient: NoctCordMediaParticipantID?) async throws -> NoctCordMediaSignalEnvelope {
        guard joined else { throw NoctCordMediaError.invalidState("session is not joined") }
        let envelope = try NoctCordMediaSignalEnvelope(
            roomID: configuration.roomID,
            sender: configuration.participant.id,
            recipient: recipient,
            sequence: nextSequence,
            timestampMilliseconds: Int64(Date().timeIntervalSince1970 * 1_000),
            signal: signal
        )
        nextSequence += 1
        try await signalingSink.send(envelope)
        try await network.send(roomID: configuration.roomID, sender: configuration.participant.id, envelope: envelope)
        return envelope
    }

    func handleIncomingSignal(_ envelope: NoctCordMediaSignalEnvelope) async throws {
        guard joined else { throw NoctCordMediaError.invalidState("session is not joined") }
        _ = envelope
    }

    func setMicrophoneEnabled(_ enabled: Bool) async throws {
        guard joined else { throw NoctCordMediaError.invalidState("session is not joined") }
        try await network.broadcast(
            roomID: configuration.roomID,
            sender: configuration.participant.id,
            event: .microphoneState(participant: configuration.participant.id, enabled: enabled)
        )
    }

    func setDeafened(_ enabled: Bool) async throws {
        guard joined else { throw NoctCordMediaError.invalidState("session is not joined") }
        try await network.broadcast(
            roomID: configuration.roomID,
            sender: configuration.participant.id,
            event: .deafenState(participant: configuration.participant.id, enabled: enabled)
        )
    }

    func publishScreenShare(_ track: NoctCordScreenShareTrack) async throws {
        guard joined else { throw NoctCordMediaError.invalidState("session is not joined") }
        try await network.broadcast(
            roomID: configuration.roomID,
            sender: configuration.participant.id,
            event: .screenShareStarted(participant: configuration.participant.id, track: track)
        )
    }

    func stopScreenShare() async throws {
        guard joined else { throw NoctCordMediaError.invalidState("session is not joined") }
        try await network.broadcast(
            roomID: configuration.roomID,
            sender: configuration.participant.id,
            event: .screenShareStopped(participant: configuration.participant.id)
        )
    }
}
