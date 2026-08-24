import Foundation

#if canImport(WebRTC)
@preconcurrency import WebRTC
#if os(macOS) && canImport(ScreenCaptureKit)
@preconcurrency import ScreenCaptureKit
#endif
#if os(iOS) && canImport(ReplayKit)
@preconcurrency import ReplayKit
#endif
#if os(iOS) && canImport(AVFoundation)
@preconcurrency import AVFoundation
#endif

public final class NoctCordWebRTCMediaDriver: NoctCordMediaDriver, @unchecked Sendable {
    private let runtime: NoctCordWebRTCRuntime

    public init() {
        runtime = NoctCordWebRTCRuntime.shared
    }

    public func makeSession(
        configuration: NoctCordMediaRoomConfiguration,
        eventHandler: @escaping @Sendable (NoctCordMediaDriverEvent) -> Void,
        signalingSink: any NoctCordMediaSignalingSink
    ) async throws -> any NoctCordMediaDriverSession {
        try configuration.validate()
        _ = try NoctCordWebRTCIceServerMapper.map(configuration.iceServers)
        return NoctCordRawWebRTCMediaSession(
            configuration: configuration,
            runtime: runtime,
            eventHandler: eventHandler,
            signalingSink: signalingSink
        )
    }
}

private final class NoctCordWebRTCRuntime: @unchecked Sendable {
    static let shared = NoctCordWebRTCRuntime()

    let factory: RTCPeerConnectionFactory

    private init() {
        RTCInitializeSSL()
        factory = RTCPeerConnectionFactory(
            encoderFactory: RTCDefaultVideoEncoderFactory(),
            decoderFactory: RTCDefaultVideoDecoderFactory()
        )
    }
}

private actor NoctCordRawSignalingCoordinator {
    private let roomID: NoctCordMediaRoomID
    private let sender: NoctCordMediaParticipantID
    private let sink: any NoctCordMediaSignalingSink
    private var nextSequence: UInt64 = 1

    init(
        roomID: NoctCordMediaRoomID,
        sender: NoctCordMediaParticipantID,
        sink: any NoctCordMediaSignalingSink
    ) {
        self.roomID = roomID
        self.sender = sender
        self.sink = sink
    }

    func send(
        _ signal: NoctCordMediaSignal,
        to recipient: NoctCordMediaParticipantID?
    ) async throws -> NoctCordMediaSignalEnvelope {
        let (followingSequence, overflow) = nextSequence.addingReportingOverflow(1)
        guard !overflow else {
            throw NoctCordMediaError.invalidState("signaling sequence is exhausted")
        }
        let envelope = try NoctCordMediaSignalEnvelope(
            roomID: roomID,
            sender: sender,
            recipient: recipient,
            sequence: nextSequence,
            timestampMilliseconds: Int64(Date().timeIntervalSince1970 * 1_000),
            signal: signal
        )
        nextSequence = followingSequence
        try await sink.send(envelope)
        return envelope
    }
}

private final class NoctCordRawWebRTCMediaSession: NSObject, NoctCordMediaDriverSession, @unchecked Sendable {
    private let queue = DispatchQueue(label: "org.noctcord.media.webrtc", qos: .userInitiated)
    private let configuration: NoctCordMediaRoomConfiguration
    private let runtime: NoctCordWebRTCRuntime
    private let eventHandler: @Sendable (NoctCordMediaDriverEvent) -> Void
    private let signalingCoordinator: NoctCordRawSignalingCoordinator
    private let peerConfiguration: RTCConfiguration
    private let peerConstraints: RTCMediaConstraints
    private let offerConstraints: RTCMediaConstraints
    private let audioTrack: RTCAudioTrack
    private var peers: [NoctCordMediaParticipantID: NoctCordRawPeer] = [:]
    private var localVideoTrack: RTCVideoTrack?
    private var localScreenCapture: (any NoctCordRawScreenCapture)?
    private var joined = false
    private var deafened = false
#if os(iOS) && canImport(AVFoundation)
    private var audioSessionWasActive = false
    private var previousAudioConfiguration: RTCAudioSessionConfiguration?
#endif

    init(
        configuration: NoctCordMediaRoomConfiguration,
        runtime: NoctCordWebRTCRuntime,
        eventHandler: @escaping @Sendable (NoctCordMediaDriverEvent) -> Void,
        signalingSink: any NoctCordMediaSignalingSink
    ) {
        self.configuration = configuration
        self.runtime = runtime
        self.eventHandler = eventHandler
        signalingCoordinator = NoctCordRawSignalingCoordinator(
            roomID: configuration.roomID,
            sender: configuration.participant.id,
            sink: signalingSink
        )

        peerConfiguration = RTCConfiguration()
        peerConfiguration.sdpSemantics = .unifiedPlan
        peerConfiguration.continualGatheringPolicy = .gatherContinually
        peerConfiguration.iceServers = configuration.iceServers.map {
            RTCIceServer(
                urlStrings: $0.urls,
                username: $0.username,
                credential: $0.credential
            )
        }
        peerConstraints = RTCMediaConstraints(
            mandatoryConstraints: nil,
            optionalConstraints: ["DtlsSrtpKeyAgreement": "true"]
        )
        offerConstraints = RTCMediaConstraints(
            mandatoryConstraints: [
                kRTCMediaConstraintsOfferToReceiveAudio: kRTCMediaConstraintsValueTrue,
                kRTCMediaConstraintsOfferToReceiveVideo: kRTCMediaConstraintsValueTrue,
            ],
            optionalConstraints: nil
        )

        let audioSource = runtime.factory.audioSource(with: RTCMediaConstraints(
            mandatoryConstraints: nil,
            optionalConstraints: nil
        ))
        audioTrack = runtime.factory.audioTrack(
            with: audioSource,
            trackId: "noctcord-microphone-\(configuration.participant.id.rawValue)"
        )
        super.init()
    }

    func join() async throws {
        do {
            try configureAudioSessionIfNeeded()
            try await perform { [self] in
                guard !self.joined else { return }
                self.joined = true
            }
            _ = try await sendGenerated(.join)
        } catch {
            try? await perform { [self] in self.joined = false }
            deactivateAudioSessionIfNeeded()
            throw error
        }
    }

    func leave() async {
        guard (try? await perform { [self] in self.joined }) == true else { return }
        _ = try? await sendGenerated(.leave)
        try? await perform { [self] in
            self.joined = false
            self.peers.values.forEach { $0.connection.close() }
            self.peers.removeAll()
        }
        deactivateAudioSessionIfNeeded()
    }

    func send(
        _ signal: NoctCordMediaSignal,
        to recipient: NoctCordMediaParticipantID?
    ) async throws -> NoctCordMediaSignalEnvelope {
        try await sendGenerated(signal, to: recipient)
    }

    func handleIncomingSignal(_ envelope: NoctCordMediaSignalEnvelope) async throws {
        let isJoined = try await perform { [self] in self.joined }
        guard isJoined else { throw NoctCordMediaError.invalidState("session is not joined") }
        guard envelope.roomID == configuration.roomID,
              envelope.sender != configuration.participant.id,
              envelope.recipient == nil || envelope.recipient == configuration.participant.id else {
            return
        }

        try await perform { [self] in
            self.process(envelope.signal, from: envelope.sender)
        }
    }

    func setMicrophoneEnabled(_ enabled: Bool) async throws {
        try await perform { [self] in
            guard self.joined else { throw NoctCordMediaError.invalidState("session is not joined") }
            self.audioTrack.isEnabled = enabled
        }
        _ = try await sendGenerated(.microphone(enabled: enabled))
    }

    func setDeafened(_ enabled: Bool) async throws {
        try await perform { [self] in
            guard self.joined else { throw NoctCordMediaError.invalidState("session is not joined") }
            self.deafened = enabled
            self.peers.values.flatMap(\.remoteAudioTracks).forEach { $0.isEnabled = !enabled }
        }
        _ = try await sendGenerated(.deafen(enabled))
    }

    func publishScreenShare(_ track: NoctCordScreenShareTrack) async throws {
        let capture = try await NoctCordRawScreenCaptureFactory.make(
            track: track,
            runtime: runtime,
            runtimeErrorHandler: { [weak self] error in
                guard let self else { return }
                self.eventHandler(.screenShareFailed(
                    participant: self.configuration.participant.id,
                    error: error
                ))
            }
        )
        try await capture.start()
        let previousCapture = try await perform { [self] in
            guard self.joined else { throw NoctCordMediaError.invalidState("session is not joined") }
            let previousCapture = self.localScreenCapture
            self.localScreenCapture = capture
            self.localVideoTrack = capture.videoTrack
            for peer in self.peers.values {
                if let sender = peer.screenSender {
                    _ = peer.connection.removeTrack(sender)
                }
                peer.screenSender = peer.connection.add(capture.videoTrack, streamIds: ["noctcord-screen"])
                if self.isDesignatedOfferer(for: peer.remoteParticipant) {
                    self.createOffer(for: peer)
                }
            }
            return previousCapture
        }
        await previousCapture?.stop()
        _ = try await sendGenerated(.screenShareStarted(track))
    }

    func stopScreenShare() async throws {
        let capture = try await perform { [self] in
            let capture = self.localScreenCapture
            self.localScreenCapture = nil
            self.localVideoTrack?.isEnabled = false
            self.localVideoTrack = nil
            for peer in self.peers.values {
                if let sender = peer.screenSender {
                    _ = peer.connection.removeTrack(sender)
                    peer.screenSender = nil
                    if self.isDesignatedOfferer(for: peer.remoteParticipant) {
                        self.createOffer(for: peer)
                    }
                }
            }
            return capture
        }
        await capture?.stop()
        _ = try await sendGenerated(.screenShareStopped)
    }

    private func sendGenerated(
        _ signal: NoctCordMediaSignal,
        to recipient: NoctCordMediaParticipantID? = nil
    ) async throws -> NoctCordMediaSignalEnvelope {
        let isJoined = try await perform { [self] in
            guard self.joined else { throw NoctCordMediaError.invalidState("session is not joined") }
            return true
        }
        guard isJoined else { throw NoctCordMediaError.invalidState("session is not joined") }
        return try await signalingCoordinator.send(signal, to: recipient)
    }

    private func configureAudioSessionIfNeeded() throws {
#if os(iOS) && canImport(AVFoundation)
        guard !audioSessionWasActive else { return }
        let audioSession = RTCAudioSession.sharedInstance()
        let current = RTCAudioSessionConfiguration.current()
        let configuration = RTCAudioSessionConfiguration.webRTC()
        configuration.category = AVAudioSession.Category.playAndRecord.rawValue
        configuration.mode = AVAudioSession.Mode.voiceChat.rawValue
        configuration.categoryOptions = [
            .allowBluetoothHFP,
            .allowBluetoothA2DP,
            .defaultToSpeaker,
        ]
        audioSession.lockForConfiguration()
        defer { audioSession.unlockForConfiguration() }
        do {
            try audioSession.setConfiguration(configuration, active: true)
        } catch {
            throw NoctCordMediaError.transportFailure(
                "iOS audio session configuration failed: \(error.localizedDescription)"
            )
        }
        previousAudioConfiguration = current
        audioSessionWasActive = true
#endif
    }

    private func deactivateAudioSessionIfNeeded() {
#if os(iOS) && canImport(AVFoundation)
        guard audioSessionWasActive else { return }
        let audioSession = RTCAudioSession.sharedInstance()
        audioSession.lockForConfiguration()
        defer { audioSession.unlockForConfiguration() }
        if let previousAudioConfiguration {
            try? audioSession.setConfiguration(previousAudioConfiguration, active: false)
        } else {
            try? audioSession.setActive(false)
        }
        previousAudioConfiguration = nil
        audioSessionWasActive = false
#endif
    }

    private func process(_ signal: NoctCordMediaSignal, from sender: NoctCordMediaParticipantID) {
        switch signal.kind {
        case .join:
            let isNewPeer = peers[sender] == nil
            let peer = peer(for: sender)
            if isNewPeer {
                eventHandler(.participantJoined(NoctCordMediaParticipant(id: sender)))
                Task { _ = try? await self.sendGenerated(.join, to: sender) }
            }
            if isNewPeer && configuration.participant.id.rawValue < sender.rawValue {
                createOffer(for: peer)
            }
        case .leave:
            if let peer = peers.removeValue(forKey: sender) {
                peer.connection.close()
            }
            eventHandler(.participantLeft(sender))
        case .offer:
            guard !isDesignatedOfferer(for: sender),
                  let value = signal.value,
                  let peer = peers[sender] ?? Optional(peer(for: sender)) else { return }
            let description = RTCSessionDescription(type: .offer, sdp: value)
                peer.connection.setRemoteDescription(description) { [weak self, weak peer] error in
                guard let self, let peer, error == nil else { return }
                self.addPendingRemoteCandidates(to: peer)
                peer.connection.answer(for: self.offerConstraints) { [weak self, weak peer] answer, error in
                    guard let self, let peer, let answer, error == nil else { return }
                    peer.connection.setLocalDescription(answer) { [weak self, weak peer] error in
                        guard let self, let peer, error == nil else { return }
                    let sdp = answer.sdp
                    let recipient = peer.remoteParticipant
                    Task {
                            _ = try? await self.sendGenerated(.answer(sdp), to: recipient)
                        }
                    }
                }
            }
        case .answer:
            guard isDesignatedOfferer(for: sender),
                  let value = signal.value,
                  let peer = peers[sender] else { return }
            peer.connection.setRemoteDescription(
                RTCSessionDescription(type: .answer, sdp: value),
                completionHandler: { [weak self, weak peer] error in
                    guard let self, let peer else { return }
                    peer.isMakingOffer = false
                    guard error == nil else {
                        self.resumeQueuedOfferIfNeeded(for: peer)
                        return
                    }
                    self.addPendingRemoteCandidates(to: peer)
                    self.resumeQueuedOfferIfNeeded(for: peer)
                }
            )
        case .iceCandidate:
            guard let peer = peers[sender] else { return }
            let candidate: NoctCordMediaICECandidate?
            if let encoded = signal.iceCandidate {
                candidate = encoded
            } else if let legacyValue = signal.value {
                candidate = NoctCordMediaICECandidate(sdp: legacyValue, sdpMid: nil, sdpMLineIndex: 0)
            } else {
                candidate = nil
            }
            guard let candidate else { return }
            add(
                RTCIceCandidate(
                    sdp: candidate.sdp,
                    sdpMLineIndex: candidate.sdpMLineIndex,
                    sdpMid: candidate.sdpMid
                ),
                to: peer
            )
        case .microphoneState:
            if let value = signal.value {
                eventHandler(.microphoneState(participant: sender, enabled: value == "enabled"))
            }
        case .deafenState:
            if let value = signal.value {
                eventHandler(.deafenState(participant: sender, enabled: value == "enabled"))
            }
        case .screenShareStarted:
            if let track = signal.track {
                eventHandler(.screenShareStarted(participant: sender, track: track))
            }
            if isDesignatedOfferer(for: sender) {
                createOffer(for: peer(for: sender))
            }
        case .screenShareStopped:
            eventHandler(.screenShareStopped(participant: sender))
            if isDesignatedOfferer(for: sender) {
                createOffer(for: peer(for: sender))
            }
        }
    }

    private func peer(for participant: NoctCordMediaParticipantID) -> NoctCordRawPeer {
        if let peer = peers[participant] { return peer }
        let connection = runtime.factory.peerConnection(
            with: peerConfiguration,
            constraints: peerConstraints,
            delegate: nil
        )!
        let peer = NoctCordRawPeer(
            remoteParticipant: participant,
            connection: connection,
            owner: self
        )
        connection.delegate = peer
        connection.add(audioTrack, streamIds: ["noctcord-audio"])
        if let localVideoTrack {
            peer.screenSender = connection.add(localVideoTrack, streamIds: ["noctcord-screen"])
        }
        peers[participant] = peer
        return peer
    }

    private func createOffer(for peer: NoctCordRawPeer) {
        guard !peer.isMakingOffer,
              peer.connection.signalingState == .stable else {
            peer.needsOffer = true
            return
        }
        peer.isMakingOffer = true
        peer.connection.offer(for: offerConstraints) { [weak self, weak peer] offer, error in
            guard let self, let peer else { return }
            guard let offer, error == nil else {
                peer.isMakingOffer = false
                self.resumeQueuedOfferIfNeeded(for: peer)
                return
            }
            peer.connection.setLocalDescription(offer) { [weak self, weak peer] error in
                guard let self, let peer else { return }
                guard error == nil else {
                    peer.isMakingOffer = false
                    self.resumeQueuedOfferIfNeeded(for: peer)
                    return
                }
                let sdp = offer.sdp
                let recipient = peer.remoteParticipant
                Task {
                    do {
                        _ = try await self.sendGenerated(.offer(sdp), to: recipient)
                    } catch {
                        peer.isMakingOffer = false
                        self.resumeQueuedOfferIfNeeded(for: peer)
                    }
                }
            }
        }
    }

    private func resumeQueuedOfferIfNeeded(for peer: NoctCordRawPeer) {
        guard peer.needsOffer else { return }
        peer.needsOffer = false
        createOffer(for: peer)
    }

    /// Exactly one endpoint is allowed to initiate SDP negotiation for a
    /// given peer pair. This prevents offer glare when both participants
    /// start or stop screen sharing at the same time while still allowing the
    /// designated endpoint to negotiate tracks added by either side.
    private func isDesignatedOfferer(
        for participant: NoctCordMediaParticipantID
    ) -> Bool {
        configuration.participant.id.rawValue < participant.rawValue
    }

    private func add(_ candidate: RTCIceCandidate, to peer: NoctCordRawPeer) {
        guard peer.connection.remoteDescription != nil else {
            peer.pendingRemoteCandidates.append(candidate)
            return
        }
        peer.connection.add(candidate, completionHandler: { _ in })
    }

    private func addPendingRemoteCandidates(to peer: NoctCordRawPeer) {
        let candidates = peer.pendingRemoteCandidates
        peer.pendingRemoteCandidates.removeAll()
        candidates.forEach { peer.connection.add($0, completionHandler: { _ in }) }
    }

    private func perform<T: Sendable>(_ operation: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do { continuation.resume(returning: try operation()) }
                catch { continuation.resume(throwing: error) }
            }
        }
    }

    fileprivate func didGenerate(_ candidate: RTCIceCandidate, for peer: NoctCordRawPeer) {
        let signal = NoctCordMediaSignal.iceCandidate(
            NoctCordMediaICECandidate(
                sdp: candidate.sdp,
                sdpMid: candidate.sdpMid,
                sdpMLineIndex: candidate.sdpMLineIndex
            )
        )
        Task { _ = try? await sendGenerated(signal, to: peer.remoteParticipant) }
    }

    fileprivate func didAdd(_ stream: RTCMediaStream, for peer: NoctCordRawPeer) {
        peer.remoteAudioTracks = stream.audioTracks
        peer.remoteAudioTracks.forEach { $0.isEnabled = !deafened }
    }

    fileprivate func didAddReceiver(_ receiver: RTCRtpReceiver, for peer: NoctCordRawPeer) {
        guard let track = receiver.track else { return }
        if let audioTrack = track as? RTCAudioTrack {
            peer.remoteAudioTracksByReceiver[receiver.receiverId] = audioTrack
            peer.remoteAudioTracks = Array(peer.remoteAudioTracksByReceiver.values)
            audioTrack.isEnabled = !deafened
            return
        }
        if let videoTrack = track as? RTCVideoTrack {
            didAdd(videoTrack, for: peer, receiverID: receiver.receiverId)
        }
    }

    fileprivate func didRemoveReceiver(_ receiver: RTCRtpReceiver, for peer: NoctCordRawPeer) {
        if let audioTrack = peer.remoteAudioTracksByReceiver.removeValue(forKey: receiver.receiverId) {
            peer.remoteAudioTracks.removeAll { $0.trackId == audioTrack.trackId }
        }
        if let removed = peer.remoteVideoTracks.removeValue(forKey: receiver.receiverId) {
            eventHandler(.remoteVideoTrackRemoved(
                participant: peer.remoteParticipant,
                trackID: removed.trackID
            ))
        }
    }

    private func didAdd(_ videoTrack: RTCVideoTrack, for peer: NoctCordRawPeer, receiverID: String) {
        let handle = NoctCordMediaRemoteVideoTrack(track: videoTrack)
        peer.remoteVideoTracks[receiverID] = handle
        eventHandler(.remoteVideoTrackAdded(
            participant: peer.remoteParticipant,
            track: handle
        ))
    }

    fileprivate func didChangeConnectionState(_ state: RTCIceConnectionState, for peer: NoctCordRawPeer) {
        let stateName: String
        switch state {
        case .new: stateName = "new"
        case .checking: stateName = "checking"
        case .connected: stateName = "connected"
        case .completed: stateName = "completed"
        case .failed: stateName = "failed"
        case .disconnected: stateName = "disconnected"
        case .closed: stateName = "closed"
        case .count: stateName = "unknown"
        @unknown default: stateName = "unknown"
        }
        eventHandler(.peerConnectionState(
            participant: peer.remoteParticipant,
            state: stateName
        ))
        peer.disconnectGeneration &+= 1
        let generation = peer.disconnectGeneration
        switch state {
        case .failed, .closed:
            removePeerIfDisconnected(peer, generation: generation)
        case .disconnected:
            Task { [weak self, weak peer] in
                try? await Task.sleep(for: .seconds(15))
                guard let self, let peer else { return }
                self.removePeerIfDisconnected(peer, generation: generation)
            }
        default:
            break
        }
    }

    private func removePeerIfDisconnected(
        _ peer: NoctCordRawPeer,
        generation: UInt64
    ) {
        queue.async { [weak self, weak peer] in
            guard let self, let peer,
                  peer.disconnectGeneration == generation,
                  self.peers[peer.remoteParticipant] === peer else { return }
            switch peer.connection.iceConnectionState {
            case .failed, .closed, .disconnected:
                self.peers.removeValue(forKey: peer.remoteParticipant)
                peer.connection.close()
                self.eventHandler(.participantLeft(peer.remoteParticipant))
            default:
                break
            }
        }
    }
}

private protocol NoctCordRawScreenCapture: AnyObject, Sendable {
    var videoTrack: RTCVideoTrack { get }
    func start() async throws
    func stop() async
}

private enum NoctCordRawScreenCaptureFactory {
    static func make(
        track: NoctCordScreenShareTrack,
        runtime: NoctCordWebRTCRuntime,
        runtimeErrorHandler: @escaping @Sendable (NoctCordMediaError) -> Void
    ) async throws -> any NoctCordRawScreenCapture {
        switch track.source {
        case let .display(identifier):
#if os(macOS) && canImport(ScreenCaptureKit)
            return try await NoctCordMacRawScreenCapture(
                runtime: runtime,
                displayID: identifier,
                runtimeErrorHandler: runtimeErrorHandler
            )
#else
            _ = identifier
            throw NoctCordMediaError.runtimeUnavailable("ScreenCaptureKit is unavailable on this target")
#endif
        case .replayKitBroadcast:
#if os(iOS) && canImport(ReplayKit)
            return try NoctCordIOSRawScreenCapture(
                runtime: runtime,
                runtimeErrorHandler: runtimeErrorHandler
            )
#else
            throw NoctCordMediaError.runtimeUnavailable("ReplayKit is unavailable on this target")
#endif
        }
    }
}

private final class NoctCordRawVideoCapturer: RTCVideoCapturer, @unchecked Sendable {
    private let source: RTCVideoSource

    init(source: RTCVideoSource) {
        self.source = source
        super.init(delegate: source)
    }

    func push(sampleBuffer: CMSampleBuffer) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let rtcBuffer = RTCCVPixelBuffer(pixelBuffer: pixelBuffer)
        let timestamp = Int64(DispatchTime.now().uptimeNanoseconds)
        let frame = RTCVideoFrame(buffer: rtcBuffer, rotation: ._0, timeStampNs: timestamp)
        source.capturer(self, didCapture: frame)
    }
}

#if os(macOS) && canImport(ScreenCaptureKit)
private final class NoctCordMacRawScreenCapture: NSObject, NoctCordRawScreenCapture, SCStreamOutput, @unchecked Sendable {
    let videoTrack: RTCVideoTrack
    private let stream: SCStream
    private let capturer: NoctCordRawVideoCapturer
    private let outputQueue = DispatchQueue(label: "org.noctcord.media.screencapturekit")

    init(
        runtime: NoctCordWebRTCRuntime,
        displayID: UInt32,
        runtimeErrorHandler: @escaping @Sendable (NoctCordMediaError) -> Void
    ) async throws {
        _ = runtimeErrorHandler
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
            throw NoctCordMediaError.noCaptureSource
        }
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let configuration = SCStreamConfiguration()
        configuration.queueDepth = 3
        stream = SCStream(filter: filter, configuration: configuration, delegate: nil)
        let source = runtime.factory.videoSource()
        capturer = NoctCordRawVideoCapturer(source: source)
        videoTrack = runtime.factory.videoTrack(
            with: source,
            trackId: "noctcord-screen-\(displayID)"
        )
        super.init()
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: outputQueue)
    }

    func start() async throws {
        try await stream.startCapture()
    }

    func stop() async {
        try? await stream.stopCapture()
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of outputType: SCStreamOutputType) {
        guard outputType == .screen else { return }
        capturer.push(sampleBuffer: sampleBuffer)
    }
}
#endif

#if os(iOS) && canImport(ReplayKit)
private final class NoctCordIOSRawScreenCapture: NSObject, NoctCordRawScreenCapture, @unchecked Sendable {
    let videoTrack: RTCVideoTrack
    private let recorder = RPScreenRecorder.shared()
    private let capturer: NoctCordRawVideoCapturer
    private let runtimeErrorHandler: @Sendable (NoctCordMediaError) -> Void

    init(
        runtime: NoctCordWebRTCRuntime,
        runtimeErrorHandler: @escaping @Sendable (NoctCordMediaError) -> Void
    ) throws {
        self.runtimeErrorHandler = runtimeErrorHandler
        guard recorder.isAvailable else {
            throw NoctCordMediaError.permissionUnavailable(.screenCapture)
        }
        let source = runtime.factory.videoSource()
        capturer = NoctCordRawVideoCapturer(source: source)
        videoTrack = runtime.factory.videoTrack(with: source, trackId: "noctcord-replaykit-screen")
        super.init()
    }

    func start() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            recorder.startCapture(handler: { [weak self] sampleBuffer, sampleBufferType, error in
                if let error {
                    self?.runtimeErrorHandler(.transportFailure(
                        "ReplayKit screen capture failed: \(error.localizedDescription)"
                    ))
                    return
                }
                if sampleBufferType == .video {
                    self?.capturer.push(sampleBuffer: sampleBuffer)
                }
            }, completionHandler: { error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume() }
            })
        }
    }

    func stop() async {
        await withCheckedContinuation { continuation in
            recorder.stopCapture { _ in continuation.resume() }
        }
    }

}
#endif

private final class NoctCordRawPeer: NSObject, RTCPeerConnectionDelegate, @unchecked Sendable {
    let remoteParticipant: NoctCordMediaParticipantID
    let connection: RTCPeerConnection
    weak var owner: NoctCordRawWebRTCMediaSession?
    var remoteAudioTracks: [RTCAudioTrack] = []
    var remoteAudioTracksByReceiver: [String: RTCAudioTrack] = [:]
    var pendingRemoteCandidates: [RTCIceCandidate] = []
    var screenSender: RTCRtpSender?
    var remoteVideoTracks: [String: NoctCordMediaRemoteVideoTrack] = [:]
    var isMakingOffer = false
    var needsOffer = false
    var disconnectGeneration: UInt64 = 0

    init(
        remoteParticipant: NoctCordMediaParticipantID,
        connection: RTCPeerConnection,
        owner: NoctCordRawWebRTCMediaSession
    ) {
        self.remoteParticipant = remoteParticipant
        self.connection = connection
        self.owner = owner
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {}
    func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState) {
        owner?.didChangeConnectionState(newState, for: self)
    }
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {
        owner?.didGenerate(candidate, for: self)
    }
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {
        owner?.didAdd(stream, for: self)
    }
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {}
    func peerConnection(
        _ peerConnection: RTCPeerConnection,
        didAdd receiver: RTCRtpReceiver,
        streams: [RTCMediaStream]
    ) {
        owner?.didAddReceiver(receiver, for: self)
    }
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove receiver: RTCRtpReceiver) {
        owner?.didRemoveReceiver(receiver, for: self)
    }
    func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {}
}

#else

public struct NoctCordWebRTCMediaDriver: NoctCordMediaDriver {
    public init() {}

    public func makeSession(
        configuration: NoctCordMediaRoomConfiguration,
        eventHandler: @escaping @Sendable (NoctCordMediaDriverEvent) -> Void,
        signalingSink: any NoctCordMediaSignalingSink
    ) async throws -> any NoctCordMediaDriverSession {
        _ = configuration
        _ = eventHandler
        _ = signalingSink
        throw NoctCordMediaError.runtimeUnavailable(
            "stasel/WebRTC 150.0.0 is unavailable for this target"
        )
    }
}

#endif
