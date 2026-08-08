import Foundation
import NoctCordCore
import NoctCordMedia
@preconcurrency import NoctweaveCore

actor NoctCordRelayMediaSignalingSink: NoctCordMediaSignalingSink {
    private let coordinator: NoctCordTransportCoordinator
    private let spaceID: UUID
    private let room: NoctCordCore.NoctCordVoiceRoom
    private let author: GroupScopedMemberHandleV2

    init(
        coordinator: NoctCordTransportCoordinator,
        spaceID: UUID,
        room: NoctCordCore.NoctCordVoiceRoom,
        author: GroupScopedMemberHandleV2
    ) {
        self.coordinator = coordinator
        self.spaceID = spaceID
        self.room = room
        self.author = author
    }

    func send(_ envelope: NoctCordMediaSignalEnvelope) async throws {
        let recipient = envelope.recipient.map {
            GroupScopedMemberHandleV2(rawValue: $0.rawValue)
        }
        guard recipient?.isStructurallyValid ?? true else {
            throw NoctCordTransportError.eventRejected
        }
        let signal = try NoctCordCallSignalCrypto.seal(
            envelope,
            spaceID: spaceID,
            room: room,
            author: author,
            recipient: recipient
        )
        try await coordinator.publishRealtimeCallSignal(
            spaceID: spaceID,
            roomID: room.id,
            signal: signal
        )
    }
}
