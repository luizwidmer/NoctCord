import XCTest
@testable import NoctCordMedia
import Foundation
#if canImport(WebRTC)
@preconcurrency import WebRTC
#endif

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

    func testSignalingDecoderRejectsUnboundedAndNonCanonicalInput() throws {
        let envelope = try NoctCordMediaSignalEnvelope(
            roomID: roomID,
            sender: "alice",
            recipient: "bob",
            sequence: 1,
            timestampMilliseconds: 1_800_000_000_000,
            signal: .iceCandidate("candidate:1 1 UDP 1 192.0.2.1 1234 typ host")
        )
        let canonical = try NoctCordMediaSignalingCodec.encode(envelope)

        var nonCanonical = canonical
        nonCanonical.append(0x20)
        XCTAssertThrowsError(try NoctCordMediaSignalingCodec.decode(nonCanonical))

        let oversizedIdentifier = try JSONEncoder().encode([
            "rawValue": String(repeating: "r", count: 257)
        ])
        XCTAssertThrowsError(
            try JSONDecoder().decode(NoctCordMediaRoomID.self, from: oversizedIdentifier)
        )

        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: canonical) as? [String: Any]
        )
        var signal = try XCTUnwrap(object["signal"] as? [String: Any])
        signal["iceCandidate"] = [
            "sdp": "candidate:1 1 UDP 1 192.0.2.1 1234 typ host",
            "sdpMid": "0",
            "sdpMLineIndex": 0
        ]
        object["signal"] = signal
        let ambiguousCandidate = try JSONSerialization.data(
            withJSONObject: object,
            options: [.sortedKeys, .withoutEscapingSlashes]
        )
        XCTAssertThrowsError(try NoctCordMediaSignalingCodec.decode(ambiguousCandidate))

        object["unexpected"] = true
        let unknownField = try JSONSerialization.data(
            withJSONObject: object,
            options: [.sortedKeys, .withoutEscapingSlashes]
        )
        XCTAssertThrowsError(try NoctCordMediaSignalingCodec.decode(unknownField))

        XCTAssertFalse(
            NoctCordMediaICECandidate(
                sdp: String(repeating: "c", count: NoctCordMediaICECandidate.maximumSDPBytes + 1),
                sdpMid: "0",
                sdpMLineIndex: 0
            ).isStructurallyValid
        )
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
                configuration: .init(roomID: roomID, participant: .init(id: "alice"), wantsMicrophone: false),
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

    #if canImport(WebRTC)
    func testRawWebRTCReceiveOnlySessionStartsWithMicrophoneDisabled() async throws {
        let session = try await NoctCordWebRTCMediaDriver().makeSession(
            configuration: .init(
                roomID: roomID, participant: .init(id: "alice"), wantsMicrophone: false
            ),
            eventHandler: { _ in },
            signalingSink: NoctCordDiscardingSignalingSink()
        )
        let inspection = try XCTUnwrap(session as? any NoctCordRawMicrophoneInspectable)
        let state = try await inspection.inspectLocalMicrophoneState()
        XCTAssertFalse(state.enabled)
        XCTAssertEqual(state.localAudioSenders, 0)
    }

    func testRawWebRTCReceiveOnlyPeerHasNoLocalAudioSender() async throws {
        let session = try await NoctCordWebRTCMediaDriver().makeSession(
            configuration: .init(
                roomID: roomID, participant: .init(id: "alice"), wantsMicrophone: false
            ),
            eventHandler: { _ in },
            signalingSink: NoctCordDiscardingSignalingSink()
        )
        try await session.join()
        try await session.handleIncomingSignal(.init(
            roomID: roomID, sender: "bob", recipient: "alice", sequence: 1,
            timestampMilliseconds: 1, signal: .join
        ))
        let inspection = try XCTUnwrap(session as? any NoctCordRawMicrophoneInspectable)
        let state = try await inspection.inspectLocalMicrophoneState()
        await session.leave()
        XCTAssertFalse(state.enabled)
        XCTAssertEqual(state.localAudioSenders, 0)
    }

    func testRawWebRTCFailedScreenShareAnnouncementStopsCapture() async throws {
        let capture = NoctCordScreenCaptureLifecycleFixture()
        let driver = NoctCordWebRTCMediaDriver(screenCaptureFactory: { capture })
        let room = NoctCordMediaRoom(
            configuration: .init(
                roomID: roomID, participant: .init(id: "alice"), wantsMicrophone: false
            ),
            driver: driver, signalingSink: NoctCordFailingScreenShareSink()
        )
        try await room.join()
        do {
            try await room.startScreenShare(using: NoctCordDescriptorScreenShareSource(
                permission: .granted,
                track: .init(trackID: try NoctCordMediaTrackID("mock-screen"), source: .display(identifier: 1))
            ))
            XCTFail("The screen-share announcement should fail")
        } catch let error as NoctCordMediaError {
            guard case .transportFailure = error else { return XCTFail("Unexpected error: \(error)") }
        }
        let stopped = await capture.lifecycle.stopped
        let snapshot = await room.snapshot()
        await room.leave()
        XCTAssertEqual(stopped, 1)
        XCTAssertNil(snapshot.localScreenShare)
    }

    func testRawWebRTCLeaveStopsTheStartedScreenCapture() async throws {
        let capture = NoctCordScreenCaptureLifecycleFixture()
        let driver = NoctCordWebRTCMediaDriver(screenCaptureFactory: { capture })
        let room = NoctCordMediaRoom(
            configuration: .init(
                roomID: roomID, participant: .init(id: "alice"), wantsMicrophone: false
            ),
            driver: driver
        )
        try await room.join()
        try await room.startScreenShare(using: NoctCordDescriptorScreenShareSource(
            permission: .granted,
            track: .init(trackID: try NoctCordMediaTrackID("mock-screen"), source: .display(identifier: 1))
        ))
        let started = await capture.lifecycle.started
        XCTAssertEqual(started, 1)

        await room.leave()

        let stopped = await capture.lifecycle.stopped
        XCTAssertEqual(stopped, 1)
        let snapshot = await room.snapshot()
        XCTAssertEqual(snapshot.state, .left)
        XCTAssertNil(snapshot.localScreenShare)
    }

    func testRawWebRTCLeaveStopsCaptureThatFinishesStartingAfterLeave() async throws {
        let started = expectation(description: "Fake capture starts and pauses")
        let gate = NoctCordLifecycleGate()
        let capture = NoctCordScreenCaptureLifecycleFixture(
            startGate: gate, onStart: { started.fulfill() }
        )
        let driver = NoctCordWebRTCMediaDriver(screenCaptureFactory: { capture })
        let room = NoctCordMediaRoom(
            configuration: .init(
                roomID: roomID, participant: .init(id: "alice"), wantsMicrophone: false
            ),
            driver: driver
        )
        try await room.join()
        let source = NoctCordDescriptorScreenShareSource(
            permission: .granted,
            track: .init(trackID: try NoctCordMediaTrackID("mock-screen"), source: .display(identifier: 1))
        )
        let sharing = Task { try await room.startScreenShare(using: source) }
        await fulfillment(of: [started], timeout: 2)

        await room.leave()
        await gate.open()
        do {
            try await sharing.value
            XCTFail("A screen share must not finish joining a room that was left")
        } catch let error as NoctCordMediaError {
            guard case .invalidState = error else { return XCTFail("Unexpected error: \(error)") }
        }

        let stopped = await capture.lifecycle.stopped
        XCTAssertEqual(stopped, 1)
        let snapshot = await room.snapshot()
        XCTAssertEqual(snapshot.state, .left)
        XCTAssertNil(snapshot.localScreenShare)
    }

    func testRawWebRTCRejectsScreenShareStartedDuringLeave() async throws {
        let signaling = expectation(description: "Leave has reached its suspended network send")
        let gate = NoctCordLifecycleGate()
        let capture = NoctCordScreenCaptureLifecycleFixture()
        let driver = NoctCordWebRTCMediaDriver(screenCaptureFactory: { capture })
        let session = try await driver.makeSession(
            configuration: .init(
                roomID: roomID, participant: .init(id: "alice"), wantsMicrophone: false
            ),
            eventHandler: { _ in },
            signalingSink: NoctCordBlockingLeaveSink(gate: gate, onLeave: { signaling.fulfill() })
        )
        try await session.join()
        let track = NoctCordScreenShareTrack(
            trackID: try NoctCordMediaTrackID("mock-screen"), source: .display(identifier: 1)
        )
        let leaving = Task { await session.leave() }
        await fulfillment(of: [signaling], timeout: 2)

        var rejected = false
        do {
            try await session.publishScreenShare(track)
        } catch let error as NoctCordMediaError {
            if case .invalidState = error { rejected = true }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        await gate.open()
        await leaving.value

        XCTAssertTrue(rejected)
        let started = await capture.lifecycle.started
        XCTAssertEqual(started, 0)
    }
    #endif

    func testReceiveOnlyRoomRequestsPermissionBeforeLaterUnmute() async throws {
        let permissions = NoctCordPermissionRequestRecorder()
        let room = NoctCordMediaRoom(
            configuration: .init(
                roomID: roomID, participant: .init(id: "alice"), wantsMicrophone: false
            ),
            driver: NoctCordInMemoryMediaDriver(),
            permissionProvider: permissions
        )
        try await room.join()
        let initialRequests = await permissions.requests
        XCTAssertEqual(initialRequests, 0)
        let initial = await room.snapshot()
        XCTAssertTrue(initial.microphoneMuted)

        do {
            try await room.setMicrophoneMuted(false)
            XCTFail("Microphone permission is required before enabling an initially unrequested microphone")
        } catch let error as NoctCordMediaError {
            XCTAssertEqual(error, .permissionDenied(.microphone))
        }
        let denied = await room.snapshot()
        XCTAssertTrue(denied.microphoneMuted)
        await permissions.allow()
        try await room.setMicrophoneMuted(false)
        let allowed = await room.snapshot()
        XCTAssertFalse(allowed.microphoneMuted)
        try await room.setMicrophoneMuted(true)
        try await room.setMicrophoneMuted(false)
        let requested = await permissions.requests
        XCTAssertEqual(requested, 2)
        await room.leave()
    }

    func testLeavingWhileJoinWaitsForPermissionRemainsTerminal() async throws {
        let requested = expectation(description: "Join waits for the permission result")
        let gate = NoctCordLifecycleGate()
        let permissions = NoctCordPermissionRequestRecorder(
            gate: gate, onRequest: { requested.fulfill() }
        )
        await permissions.allow()
        let room = NoctCordMediaRoom(
            configuration: .init(roomID: roomID, participant: .init(id: "alice")),
            driver: NoctCordInMemoryMediaDriver(), permissionProvider: permissions
        )
        let joining = Task { try await room.join() }
        await fulfillment(of: [requested], timeout: 2)

        await room.leave()
        await gate.open()
        do {
            try await joining.value
            XCTFail("A delayed permission grant must not undo leaving the room")
        } catch let error as NoctCordMediaError {
            guard case .invalidState = error else { return XCTFail("Unexpected error: \(error)") }
        }
        let snapshot = await room.snapshot()
        await room.leave()
        XCTAssertEqual(snapshot.state, .left)
    }

    func testLeavingWhileJoinCreatesDriverReleasesTheLateSession() async throws {
        let created = expectation(description: "Driver creation pauses")
        let gate = NoctCordLifecycleGate()
        let lifecycle = NoctCordJoinLifecycle()
        let room = NoctCordMediaRoom(
            configuration: .init(
                roomID: roomID, participant: .init(id: "alice"), wantsMicrophone: false
            ),
            driver: NoctCordDelayedJoinDriver(
                lifecycle: lifecycle, creationGate: gate, onCreate: { created.fulfill() }
            )
        )
        let joining = Task { try await room.join() }
        await fulfillment(of: [created], timeout: 2)

        await room.leave()
        await gate.open()
        do {
            try await joining.value
            XCTFail("A late-created session must not join a room that was left")
        } catch let error as NoctCordMediaError {
            guard case .invalidState = error else { return XCTFail("Unexpected error: \(error)") }
        }
        let snapshot = await room.snapshot()
        let joins = await lifecycle.joins
        let leaves = await lifecycle.leaves
        await room.leave()
        XCTAssertEqual(snapshot.state, .left)
        XCTAssertEqual(joins, 0)
        XCTAssertGreaterThanOrEqual(leaves, 1)
    }

    func testLeavingWhileDriverJoinsStopsAnyLateActivation() async throws {
        let started = expectation(description: "Driver join pauses before activation")
        let gate = NoctCordLifecycleGate()
        let lifecycle = NoctCordJoinLifecycle()
        let room = NoctCordMediaRoom(
            configuration: .init(
                roomID: roomID, participant: .init(id: "alice"), wantsMicrophone: false
            ),
            driver: NoctCordDelayedJoinDriver(
                lifecycle: lifecycle, joinGate: gate, onJoin: { started.fulfill() }
            )
        )
        let joining = Task { try await room.join() }
        await fulfillment(of: [started], timeout: 2)

        await room.leave()
        await gate.open()
        do {
            try await joining.value
            XCTFail("A late driver completion must not undo leaving the room")
        } catch let error as NoctCordMediaError {
            guard case .invalidState = error else { return XCTFail("Unexpected error: \(error)") }
        }
        let snapshot = await room.snapshot()
        let active = await lifecycle.active
        await room.leave()
        XCTAssertEqual(snapshot.state, .left)
        XCTAssertFalse(active)
    }

    func testRawWebRTCNegotiatesOfferAndAnswerThroughInjectedSink() async throws {
        let aliceSink = NoctCordLoopbackSink()
        let bobSink = NoctCordLoopbackSink()
        let permissions = NoctCordFixedPermissionProvider(snapshot: .init(microphone: .granted))
        let driver = NoctCordWebRTCMediaDriver()
        let alice = NoctCordMediaRoom(
            configuration: .init(roomID: roomID, participant: .init(id: "alice"), wantsMicrophone: false),
            driver: driver,
            permissionProvider: permissions,
            signalingSink: aliceSink
        )
        let bob = NoctCordMediaRoom(
            configuration: .init(roomID: roomID, participant: .init(id: "bob"), wantsMicrophone: false),
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
        XCTAssertTrue(
            isConnected(aliceSnapshot.remoteConnectionStates["bob"]),
            "Alice/Bob ICE state: \(aliceSnapshot.remoteConnectionStates); signals: \(kinds)"
        )
        XCTAssertTrue(
            isConnected(bobSnapshot.remoteConnectionStates["alice"]),
            "Bob/Alice ICE state: \(bobSnapshot.remoteConnectionStates); signals: \(kinds)"
        )
    }

    func testRawWebRTCMeshNegotiatesThreePeersWithTargetedJoinAcknowledgements() async throws {
        let aliceSink = NoctCordLoopbackSink()
        let bobSink = NoctCordLoopbackSink()
        let carolSink = NoctCordLoopbackSink()
        let permissions = NoctCordFixedPermissionProvider(snapshot: .init(microphone: .granted))
        let driver = NoctCordWebRTCMediaDriver()
        let alice = NoctCordMediaRoom(
            configuration: .init(roomID: roomID, participant: .init(id: "alice"), wantsMicrophone: false),
            driver: driver,
            permissionProvider: permissions,
            signalingSink: aliceSink
        )
        let bob = NoctCordMediaRoom(
            configuration: .init(roomID: roomID, participant: .init(id: "bob"), wantsMicrophone: false),
            driver: driver,
            permissionProvider: permissions,
            signalingSink: bobSink
        )
        let carol = NoctCordMediaRoom(
            configuration: .init(roomID: roomID, participant: .init(id: "carol"), wantsMicrophone: false),
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
        XCTAssertTrue(
            ["bob", "carol"].allSatisfy { isConnected(aliceSnapshot.remoteConnectionStates[$0]) },
            "Alice mesh ICE state: \(aliceSnapshot.remoteConnectionStates); signals: \(kinds)"
        )
        XCTAssertTrue(
            ["alice", "carol"].allSatisfy { isConnected(bobSnapshot.remoteConnectionStates[$0]) },
            "Bob mesh ICE state: \(bobSnapshot.remoteConnectionStates); signals: \(kinds)"
        )
        XCTAssertTrue(
            ["alice", "bob"].allSatisfy { isConnected(carolSnapshot.remoteConnectionStates[$0]) },
            "Carol mesh ICE state: \(carolSnapshot.remoteConnectionStates); signals: \(kinds)"
        )
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

private actor NoctCordLifecycleGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.resume() }
    }
}

private actor NoctCordPermissionRequestRecorder: NoctCordMediaPermissionProvider {
    private var granted = false
    private(set) var requests = 0
    private let gate: NoctCordLifecycleGate?
    private let onRequest: @Sendable () -> Void

    init(gate: NoctCordLifecycleGate? = nil, onRequest: @escaping @Sendable () -> Void = {}) {
        self.gate = gate
        self.onRequest = onRequest
    }

    func allow() { granted = true }

    func request(_ permissions: Set<NoctCordMediaPermission>) async throws -> NoctCordMediaPermissionSnapshot {
        requests += 1
        onRequest()
        await gate?.wait()
        guard granted else { throw NoctCordMediaError.permissionDenied(.microphone) }
        return .init(microphone: .granted)
    }
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

#if canImport(WebRTC)
private actor NoctCordScreenCaptureLifecycle {
    private(set) var started = 0
    private(set) var stopped = 0
    func start() { started += 1 }
    func stop() { stopped += 1 }
}

private final class NoctCordScreenCaptureLifecycleFixture: NoctCordRawScreenCapture, @unchecked Sendable {
    let videoTrack: RTCVideoTrack
    let lifecycle = NoctCordScreenCaptureLifecycle()
    private let startGate: NoctCordLifecycleGate?
    private let onStart: @Sendable () -> Void

    init(startGate: NoctCordLifecycleGate? = nil, onStart: @escaping @Sendable () -> Void = {}) {
        self.startGate = startGate
        self.onStart = onStart
        let factory = RTCPeerConnectionFactory()
        videoTrack = factory.videoTrack(with: factory.videoSource(), trackId: "mock-screen")
    }

    func start() async throws {
        await lifecycle.start()
        onStart()
        await startGate?.wait()
    }
    func stop() async { await lifecycle.stop() }
}

private struct NoctCordBlockingLeaveSink: NoctCordMediaSignalingSink {
    let gate: NoctCordLifecycleGate
    let onLeave: @Sendable () -> Void

    func send(_ envelope: NoctCordMediaSignalEnvelope) async throws {
        if envelope.signal.kind == .leave {
            onLeave()
            await gate.wait()
        }
    }
}

private struct NoctCordFailingScreenShareSink: NoctCordMediaSignalingSink {
    func send(_ envelope: NoctCordMediaSignalEnvelope) async throws {
        if envelope.signal.kind == .screenShareStarted {
            throw NoctCordMediaError.transportFailure("fixture rejected the screen-share signal")
        }
    }
}
#endif

private actor NoctCordJoinLifecycle {
    private(set) var joins = 0
    private(set) var leaves = 0
    private(set) var active = false
    func beginJoin() { joins += 1 }
    func activate() { active = true }
    func leave() { leaves += 1; active = false }
}

private struct NoctCordDelayedJoinDriver: NoctCordMediaDriver {
    let lifecycle: NoctCordJoinLifecycle
    var creationGate: NoctCordLifecycleGate?
    var joinGate: NoctCordLifecycleGate?
    var onCreate: @Sendable () -> Void = {}
    var onJoin: @Sendable () -> Void = {}

    func makeSession(
        configuration: NoctCordMediaRoomConfiguration,
        eventHandler: @escaping @Sendable (NoctCordMediaDriverEvent) -> Void,
        signalingSink: any NoctCordMediaSignalingSink
    ) async throws -> any NoctCordMediaDriverSession {
        onCreate()
        await creationGate?.wait()
        return NoctCordDelayedJoinSession(lifecycle: lifecycle, gate: joinGate, onJoin: onJoin)
    }
}

private actor NoctCordDelayedJoinSession: NoctCordMediaDriverSession {
    let lifecycle: NoctCordJoinLifecycle
    let gate: NoctCordLifecycleGate?
    let onJoin: @Sendable () -> Void

    init(lifecycle: NoctCordJoinLifecycle, gate: NoctCordLifecycleGate?, onJoin: @escaping @Sendable () -> Void) {
        self.lifecycle = lifecycle
        self.gate = gate
        self.onJoin = onJoin
    }

    func join() async throws {
        await lifecycle.beginJoin()
        onJoin()
        await gate?.wait()
        await lifecycle.activate()
    }
    func leave() async { await lifecycle.leave() }
    func send(_ signal: NoctCordMediaSignal, to recipient: NoctCordMediaParticipantID?) async throws -> NoctCordMediaSignalEnvelope {
        try .init(roomID: "room-1", sender: "alice", recipient: recipient, sequence: 1,
                  timestampMilliseconds: 1, signal: signal)
    }
    func handleIncomingSignal(_ envelope: NoctCordMediaSignalEnvelope) async throws {}
    func setMicrophoneEnabled(_ enabled: Bool) async throws {}
    func setDeafened(_ enabled: Bool) async throws {}
    func publishScreenShare(_ track: NoctCordScreenShareTrack) async throws {}
    func stopScreenShare() async throws {}
}
