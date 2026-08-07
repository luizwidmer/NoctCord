import Foundation
import NoctCordCore
import NoctweaveCore

@main
enum NoctCordDemo {
    static func main() throws {
        let spaceID = UUID()
        let channelID = UUID()
        let owner = GroupScopedMemberHandleV2.generate()
        let member = GroupScopedMemberHandleV2.generate()
        let messageID = UUID()
        let now = Date()

        let events = [
            NoctCordEvent(
                spaceID: spaceID,
                author: owner,
                logicalClock: 1,
                createdAt: now,
                operation: .createSpace(name: "Night Shift")
            ),
            NoctCordEvent(
                spaceID: spaceID,
                author: owner,
                logicalClock: 2,
                createdAt: now.addingTimeInterval(1),
                operation: .createChannel(id: channelID, name: "general")
            ),
            NoctCordEvent(
                spaceID: spaceID,
                author: member,
                logicalClock: 3,
                createdAt: now.addingTimeInterval(2),
                operation: .postMessage(
                    id: messageID,
                    channelID: channelID,
                    text: "Hello through Noctweave."
                )
            ),
        ]

        let result = NoctCordSpaceProjection.project(
            spaceID: spaceID,
            owner: owner,
            activeMembers: [owner, member],
            events: events
        )
        let content = try NoctCordCodec.encode(events[2])
        let compact = try NoctCordCompactCodec.encode(events[2])

        print("Space: \(result.projection.name ?? "Unavailable")")
        print("Channels: \(result.projection.channels.count)")
        print("Messages: \(result.projection.messages.count)")
        print("Rejected events: \(result.rejectedEvents.count)")
        print("Noctweave content: \(content.type.canonicalName), \(content.payload.count) bytes")
        print("Realtime record: \(compact.count) bytes")
    }
}
