import XCTest
@testable import NoctCordMedia
import Foundation

final class NoctCordMediaTests: XCTestCase {
    private let roomID: NoctCordMediaRoomID = "room-1"

    func testSignalingEnvelopeRoundTripsDeterministically() throws {
        let envelope = try NoctCordMediaSignalEnvelope(
            roomID: roomID,
            sender: "alice",
            recipient: "bob",
            sequence: 1,
            timestampMilliseconds: 1_800_000_000_000,
            signal: .offer("v=0\r\no=- 1 1 IN IP4 0.0.0.0")
        )

        let first = try NoctCordMediaSignalingCodec.encode(envelope)
        let second = try NoctCordMediaSignalingCodec.encode(envelope)
        XCTAssertEqual(first, second)
        XCTAssertEqual(try NoctCordMediaSignalingCodec.decode(first), envelope)
    }

    func testICEServerValidationAndWebRTCMapping() throws {
        let stun = try NoctCordMediaICEServer(url: "stun:stun.example.test:3478")
        let turn = try NoctCordMediaICEServer(
            url: "turns:turn.example.test:5349?transport=tcp",
            username: "alice",
            credential: "short-lived-token"
        )
        let mappings = try NoctCordWebRTCIceServerMapper.map([stun, turn])
        XCTAssertEqual(mappings.map(\.urls), [stun.urls, turn.urls])
        XCTAssertEqual(mappings[1].username, "alice")
        XCTAssertEqual(mappings[1].credential, "short-lived-token")

        XCTAssertThrowsError(try NoctCordMediaICEServer(url: "https://example.test"))
        XCTAssertThrowsError(try NoctCordMediaICEServer(url: "turn:example.test", username: "alice"))
        XCTAssertThrowsError(try NoctCordMediaICEServer(url: "turn:alice:secret@example.test"))
    }

    func testSignalingRejectsReplayAndWrongRecipient() async throws {
        let network = NoctCordInMemoryMediaNetwork()
        let driver = NoctCordInMemoryMediaDriver(network: network)
        let permissions = NoctCordFixedPermissionProvider(
            snapshot: .init(microphone: .granted)
        )
        let alice = NoctCordMediaRoom(
            configuration: .init(roomID: roomID, participant: .init(id: "alice")),
            driver: driver,
            permissionProvider: permissions
        )
        let bob = NoctCordMediaRoom(
            configuration: .init(roomID: roomID, participant: .init(id: "bob")),
            driver: driver,
            permissionProvider: permissions
        )

        try await alice.join()
        try await bob.join()
        let first = try await alice.send(.offer("first"), to: "bob")
        _ = try await alice.send(.answer("second"), to: "bob")
        XCTAssertEqual(first.sequence, 1)

        try await Task.sleep(for: .milliseconds(50))
        let snapshot = await bob.snapshot()
        XCTAssertEqual(snapshot.lastReceivedSequence["alice"], 2)

        let stale = try NoctCordMediaSignalEnvelope(
            roomID: roomID,
            sender: "alice",
            recipient: "bob",
            sequence: 1,
            timestampMilliseconds: 1_800_000_000_001,
            signal: .offer("stale")
        )
        try await bob.handleIncomingSignal(stale)
        let replaySnapshot = await bob.snapshot()
        XCTAssertEqual(replaySnapshot.lastReceivedSequence["alice"], 2)

        let restartedJoin = try NoctCordMediaSignalEnvelope(
            roomID: roomID,
            sender: "alice",
            recipient: "bob",
            sequence: 1,
            timestampMilliseconds: 1_800_000_000_010,
            signal: .join
        )
        try await bob.handleIncomingSignal(restartedJoin)
        let restartedJoinSnapshot = await bob.snapshot()
        XCTAssertEqual(restartedJoinSnapshot.lastReceivedSequence["alice"], 1)

        let restartedOffer = try NoctCordMediaSignalEnvelope(
            roomID: roomID,
            sender: "alice",
            recipient: "bob",
            sequence: 2,
            timestampMilliseconds: 1_800_000_000_011,
            signal: .offer("new session")
        )
        try await bob.handleIncomingSignal(restartedOffer)
        let restartedOfferSnapshot = await bob.snapshot()
        XCTAssertEqual(restartedOfferSnapshot.lastReceivedSequence["alice"], 2)

        let replayedOldJoin = try NoctCordMediaSignalEnvelope(
            roomID: roomID,
            sender: "alice",
            recipient: "bob",
            sequence: 1,
            timestampMilliseconds: 1_800_000_000_009,
            signal: .join
        )
        try await bob.handleIncomingSignal(replayedOldJoin)
        let replayedJoinSnapshot = await bob.snapshot()
        XCTAssertEqual(replayedJoinSnapshot.lastReceivedSequence["alice"], 2)
    }

    func testMuteDeafenAndScreenShareReachOtherRoom() async throws {
        let network = NoctCordInMemoryMediaNetwork()
        let driver = NoctCordInMemoryMediaDriver(network: network)
        let permissions = NoctCordFixedPermissionProvider(snapshot: .init(microphone: .granted, screenCapture: .granted))
        let alice = NoctCordMediaRoom(
            configuration: .init(roomID: roomID, participant: .init(id: "alice")),
            driver: driver,
            permissionProvider: permissions
        )
        let bob = NoctCordMediaRoom(
            configuration: .init(roomID: roomID, participant: .init(id: "bob")),
            driver: driver,
            permissionProvider: permissions
        )
        try await alice.join()
        try await bob.join()

        try await alice.setMicrophoneMuted(true)
        try await alice.setDeafened(true)
        let track = NoctCordScreenShareTrack(
            trackID: try NoctCordMediaTrackID("display-1"),
            source: .display(identifier: 1)
        )
        try await alice.startScreenShare(
            using: NoctCordDescriptorScreenShareSource(permission: .granted, track: track)
        )
        try await Task.sleep(for: .milliseconds(50))

        let snapshot = await bob.snapshot()
        XCTAssertEqual(snapshot.remoteScreenShares["alice"], track)
        XCTAssertTrue(snapshot.participants.contains { $0.id.rawValue == "alice" })
        XCTAssertEqual(snapshot.remoteMicrophoneEnabled["alice"], false)
        XCTAssertEqual(snapshot.remoteDeafened["alice"], true)
    }

    func testRemoteVideoTrackLifecycleReachesRoomSnapshot() async throws {
        let driver = NoctCordRemoteVideoLifecycleDriver()
        let room = NoctCordMediaRoom(
            configuration: .init(roomID: roomID, participant: .init(id: "alice")),
            driver: driver,
            permissionProvider: NoctCordFixedPermissionProvider(snapshot: .init(microphone: .granted))
        )
        try await room.join()

        let track = try NoctCordMediaRemoteVideoTrack(unavailableTrackID: "remote-screen-1")
        await driver.emit(.remoteVideoTrackAdded(participant: "bob", track: track))
        try await Task.sleep(for: .milliseconds(20))
        let added = await room.snapshot()
        XCTAssertEqual(added.remoteVideoTracks["bob"], track)
        XCTAssertEqual(added.remoteVideoTracks["bob"]?.trackID, "remote-screen-1")

        await driver.emit(.remoteVideoTrackRemoved(participant: "bob", trackID: "remote-screen-1"))
        try await Task.sleep(for: .milliseconds(20))
        let removed = await room.snapshot()
        XCTAssertNil(removed.remoteVideoTracks["bob"])
    }

    func testScreenSharePermissionIsRequiredBeforePublish() async throws {
        let network = NoctCordInMemoryMediaNetwork()
        let driver = NoctCordInMemoryMediaDriver(network: network)
        let room = NoctCordMediaRoom(
            configuration: .init(roomID: roomID, participant: .init(id: "alice")),
            driver: driver,
            permissionProvider: NoctCordFixedPermissionProvider(
                snapshot: NoctCordMediaPermissionSnapshot(
                    microphone: .granted,
                    screenCapture: .denied
                )
            )
        )
        try await room.join()
        let track = NoctCordScreenShareTrack(
            trackID: try NoctCordMediaTrackID("display-1"),
            source: .display(identifier: 1)
        )
        do {
            try await room.startScreenShare(
                using: NoctCordDescriptorScreenShareSource(permission: .denied, track: track)
            )
            XCTFail("expected screen permission failure")
        } catch let error as NoctCordMediaError {
            XCTAssertEqual(error, .permissionDenied(.screenCapture))
        }
    }

    func testWebRTCAdapterCreatesARealSessionWhenBinaryRuntimeIsLinked() async throws {
        let driver = NoctCordWebRTCMediaDriver()
        do {
            let session = try await driver.makeSession(
                configuration: .init(roomID: roomID, participant: .init(id: "alice")),
                eventHandler: { _ in },
                signalingSink: NoctCordDiscardingSignalingSink()
            )
            XCTAssertNotNil(session)
        } catch let error as NoctCordMediaError {
            guard case .runtimeUnavailable = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }
    }

    func testRawWebRTCNegotiatesOfferAndAnswerThroughInjectedSink() async throws {
        let aliceSink = NoctCordLoopbackSink()
        let bobSink = NoctCordLoopbackSink()
        let permissions = NoctCordFixedPermissionProvider(snapshot: .init(microphone: .granted))
        let driver = NoctCordWebRTCMediaDriver()
        let alice = NoctCordMediaRoom(
            configuration: .init(roomID: roomID, participant: .init(id: "alice")),
            driver: driver,
            permissionProvider: permissions,
            signalingSink: aliceSink
        )
        let bob = NoctCordMediaRoom(
            configuration: .init(roomID: roomID, participant: .init(id: "bob")),
            driver: driver,
            permissionProvider: permissions,
            signalingSink: bobSink
        )
        let recorder = NoctCordSignalKindRecorder()

        aliceSink.setHandler { envelope in
            await recorder.append(envelope.signal.kind)
            try await bob.handleIncomingSignal(envelope)
        }
        bobSink.setHandler { envelope in
            await recorder.append(envelope.signal.kind)
            try await alice.handleIncomingSignal(envelope)
        }

        do {
            try await alice.join()
            try await bob.join()
        } catch let error as NoctCordMediaError {
            guard case .runtimeUnavailable = error else { throw error }
            throw XCTSkip("raw WebRTC runtime is unavailable")
        }
        var aliceSnapshot = await alice.snapshot()
        var bobSnapshot = await bob.snapshot()
        for _ in 0..<50 {
            if isConnected(aliceSnapshot.remoteConnectionStates["bob"]),
               isConnected(bobSnapshot.remoteConnectionStates["alice"]) {
                break
            }
            try await Task.sleep(for: .milliseconds(100))
            aliceSnapshot = await alice.snapshot()
            bobSnapshot = await bob.snapshot()
        }

        let kinds = await recorder.values()
        XCTAssertTrue(kinds.contains(.join))
        XCTAssertTrue(kinds.contains(.offer))
        XCTAssertTrue(kinds.contains(.answer))
        XCTAssertTrue(isConnected(aliceSnapshot.remoteConnectionStates["bob"]))
        XCTAssertTrue(isConnected(bobSnapshot.remoteConnectionStates["alice"]))
    }

    func testRawWebRTCMeshNegotiatesThreePeersWithTargetedJoinAcknowledgements() async throws {
        let aliceSink = NoctCordLoopbackSink()
        let bobSink = NoctCordLoopbackSink()
        let carolSink = NoctCordLoopbackSink()
        let permissions = NoctCordFixedPermissionProvider(snapshot: .init(microphone: .granted))
        let driver = NoctCordWebRTCMediaDriver()
        let alice = NoctCordMediaRoom(
            configuration: .init(roomID: roomID, participant: .init(id: "alice")),
            driver: driver,
            permissionProvider: permissions,
            signalingSink: aliceSink
        )
        let bob = NoctCordMediaRoom(
            configuration: .init(roomID: roomID, participant: .init(id: "bob")),
            driver: driver,
            permissionProvider: permissions,
            signalingSink: bobSink
        )
        let carol = NoctCordMediaRoom(
            configuration: .init(roomID: roomID, participant: .init(id: "carol")),
            driver: driver,
            permissionProvider: permissions,
            signalingSink: carolSink
        )
        let recorder = NoctCordSignalKindRecorder()

        aliceSink.setHandler { envelope in
            await recorder.append(envelope.signal.kind)
            switch envelope.recipient?.rawValue {
            case "bob": try await bob.handleIncomingSignal(envelope)
            case "carol": try await carol.handleIncomingSignal(envelope)
            default:
                try await bob.handleIncomingSignal(envelope)
                try await carol.handleIncomingSignal(envelope)
            }
        }
        bobSink.setHandler { envelope in
            await recorder.append(envelope.signal.kind)
            switch envelope.recipient?.rawValue {
            case "alice": try await alice.handleIncomingSignal(envelope)
            case "carol": try await carol.handleIncomingSignal(envelope)
            default:
                try await alice.handleIncomingSignal(envelope)
                try await carol.handleIncomingSignal(envelope)
            }
        }
        carolSink.setHandler { envelope in
            await recorder.append(envelope.signal.kind)
            switch envelope.recipient?.rawValue {
            case "alice": try await alice.handleIncomingSignal(envelope)
            case "bob": try await bob.handleIncomingSignal(envelope)
            default:
                try await alice.handleIncomingSignal(envelope)
                try await bob.handleIncomingSignal(envelope)
            }
        }

        do {
            try await alice.join()
            try await bob.join()
            try await carol.join()
        } catch let error as NoctCordMediaError {
            guard case .runtimeUnavailable = error else { throw error }
            throw XCTSkip("raw WebRTC runtime is unavailable")
        }

        var aliceSnapshot = await alice.snapshot()
        var bobSnapshot = await bob.snapshot()
        var carolSnapshot = await carol.snapshot()
        for _ in 0..<80 {
            let aliceConnected = ["bob", "carol"].allSatisfy {
                isConnected(aliceSnapshot.remoteConnectionStates[$0])
            }
            let bobConnected = ["alice", "carol"].allSatisfy {
                isConnected(bobSnapshot.remoteConnectionStates[$0])
            }
            let carolConnected = ["alice", "bob"].allSatisfy {
                isConnected(carolSnapshot.remoteConnectionStates[$0])
            }
            if aliceConnected && bobConnected && carolConnected { break }
            try await Task.sleep(for: .milliseconds(100))
            aliceSnapshot = await alice.snapshot()
            bobSnapshot = await bob.snapshot()
            carolSnapshot = await carol.snapshot()
        }

        let kinds = await recorder.values()
        XCTAssertTrue(kinds.contains(.offer))
        XCTAssertTrue(kinds.contains(.answer))
        XCTAssertEqual(aliceSnapshot.participants.count, 3)
        XCTAssertEqual(bobSnapshot.participants.count, 3)
        XCTAssertEqual(carolSnapshot.participants.count, 3)
        XCTAssertTrue(["bob", "carol"].allSatisfy { isConnected(aliceSnapshot.remoteConnectionStates[$0]) })
        XCTAssertTrue(["alice", "carol"].allSatisfy { isConnected(bobSnapshot.remoteConnectionStates[$0]) })
        XCTAssertTrue(["alice", "bob"].allSatisfy { isConnected(carolSnapshot.remoteConnectionStates[$0]) })
    }

    private func isConnected(_ state: String?) -> Bool {
        state == "connected" || state == "completed"
    }
}

private final class NoctCordLoopbackSink: NoctCordMediaSignalingSink, @unchecked Sendable {
    private let lock = NSLock()
    private var handler: (@Sendable (NoctCordMediaSignalEnvelope) async throws -> Void)?

    func setHandler(_ handler: @escaping @Sendable (NoctCordMediaSignalEnvelope) async throws -> Void) {
        lock.lock()
        self.handler = handler
        lock.unlock()
    }

    func send(_ envelope: NoctCordMediaSignalEnvelope) async throws {
        let handler = lock.withLock { self.handler }
        guard let handler else {
            throw NoctCordMediaError.transportFailure("loopback signaling handler is not installed")
        }
        try await handler(envelope)
    }
}

private actor NoctCordSignalKindRecorder {
    private var kinds: [NoctCordMediaSignalKind] = []

    func append(_ kind: NoctCordMediaSignalKind) {
        kinds.append(kind)
    }

    func values() -> [NoctCordMediaSignalKind] { kinds }
}

private actor NoctCordRemoteVideoLifecycleState {
    private var handler: (@Sendable (NoctCordMediaDriverEvent) -> Void)?

    func setHandler(_ handler: @escaping @Sendable (NoctCordMediaDriverEvent) -> Void) {
        self.handler = handler
    }

    func emit(_ event: NoctCordMediaDriverEvent) {
        handler?(event)
    }
}

private struct NoctCordRemoteVideoLifecycleDriver: NoctCordMediaDriver {
    private let state = NoctCordRemoteVideoLifecycleState()

    func makeSession(
        configuration: NoctCordMediaRoomConfiguration,
        eventHandler: @escaping @Sendable (NoctCordMediaDriverEvent) -> Void,
        signalingSink: any NoctCordMediaSignalingSink
    ) async throws -> any NoctCordMediaDriverSession {
        _ = configuration
        _ = signalingSink
        await state.setHandler(eventHandler)
        return NoctCordRemoteVideoLifecycleSession()
    }

    func emit(_ event: NoctCordMediaDriverEvent) async {
        await state.emit(event)
    }
}

private actor NoctCordRemoteVideoLifecycleSession: NoctCordMediaDriverSession {
    func join() async throws {}
    func leave() async {}

    func send(
        _ signal: NoctCordMediaSignal,
        to recipient: NoctCordMediaParticipantID?
    ) async throws -> NoctCordMediaSignalEnvelope {
        try NoctCordMediaSignalEnvelope(
            roomID: "room-1",
            sender: "alice",
            recipient: recipient,
            sequence: 1,
            timestampMilliseconds: 1_800_000_000_000,
            signal: signal
        )
    }

    func handleIncomingSignal(_ envelope: NoctCordMediaSignalEnvelope) async throws { _ = envelope }
    func setMicrophoneEnabled(_ enabled: Bool) async throws { _ = enabled }
    func setDeafened(_ enabled: Bool) async throws { _ = enabled }
    func publishScreenShare(_ track: NoctCordScreenShareTrack) async throws { _ = track }
    func stopScreenShare() async throws {}
}
