import Foundation
import NoctCordCore
@preconcurrency import NoctweaveCore
@testable import NoctCordUI
import XCTest

final class NoctCordApplicationSecurityTests: XCTestCase {
    func testRejectedGroupEventsCannotPoisonOwnerBootstrapOrAcknowledgeRequests() throws {
        let spaceID = UUID()
        let owner = GroupScopedMemberHandleV2(rawValue: Data(repeating: 1, count: 32).base64EncodedString())
        let member = GroupScopedMemberHandleV2(rawValue: Data(repeating: 2, count: 32).base64EncodedString())
        func event(_ author: GroupScopedMemberHandleV2, _ clock: UInt64,
                   _ operation: NoctCordOperation) -> NoctCordEvent {
            NoctCordEvent(spaceID: spaceID, author: author, logicalClock: clock, operation: operation)
        }
        let created = event(owner, 1, .createSpace(name: "Community"))
        let request = event(member, 2, .requestBootstrap())
        let injectedRole = event(member, 3, .defineRole(NoctCordRole(
            id: UUID(), name: "Forged admin", position: 10, permissions: [.manageSpace]
        )))
        let forgedAcknowledgement = event(member, 4, .applyBootstrap([created], satisfying: [request.id]))
        let events = [created, request, injectedRole, forgedAcknowledgement]
        XCTAssertTrue(events.allSatisfy(\.isStructurallyValid))

        let accepted = NoctCordTransportCoordinator.acceptedBootstrapHistory(
            spaceID: spaceID, owner: owner, activeMembers: [owner, member], events: events
        )
        XCTAssertEqual(accepted, [created, request])
        XCTAssertEqual(accepted.flatMap { $0.operation.bootstrapRequestIDs ?? [] }, [])
    }

    func testBootstrapHistoryDoesNotTrustAnEventReusingANestedAcceptedID() throws {
        let spaceID = UUID()
        let owner = GroupScopedMemberHandleV2(rawValue: Data(repeating: 1, count: 32).base64EncodedString())
        let member = GroupScopedMemberHandleV2(rawValue: Data(repeating: 2, count: 32).base64EncodedString())
        func event(_ author: GroupScopedMemberHandleV2, _ clock: UInt64,
                   _ operation: NoctCordOperation) -> NoctCordEvent {
            NoctCordEvent(spaceID: spaceID, author: author, logicalClock: clock, operation: operation)
        }
        let created = event(owner, 1, .createSpace(name: "Community"))
        let request = event(member, 2, .requestBootstrap())
        let nested = event(owner, 3, .renameSpace("Renamed"))
        let bootstrap = event(owner, 4, .applyBootstrap([nested]))
        // Nested application events have no separate outer transport event.
        // A malicious member can therefore submit this ID in a fresh envelope.
        let forgedAcknowledgement = NoctCordEvent(
            id: nested.id, spaceID: spaceID, author: member, logicalClock: 5,
            operation: .applyBootstrap([created], satisfying: [request.id])
        )
        let events = [created, request, bootstrap, forgedAcknowledgement]
        XCTAssertTrue(events.allSatisfy(\.isStructurallyValid))

        let accepted = NoctCordTransportCoordinator.acceptedBootstrapHistory(
            spaceID: spaceID, owner: owner, activeMembers: [owner, member], events: events
        )
        XCTAssertEqual(accepted, [created, request, bootstrap])
        XCTAssertEqual(accepted.flatMap { $0.operation.bootstrapRequestIDs ?? [] }, [])
    }
    func testBotHostDispatchesOnlyCurrentlyValidAcceptedCommands() async throws {
        let spaceID = UUID()
        let channelID = UUID()
        let owner = GroupScopedMemberHandleV2(rawValue: Data(repeating: 1, count: 32).base64EncodedString())
        let member = GroupScopedMemberHandleV2(rawValue: Data(repeating: 2, count: 32).base64EncodedString())
        let botMember = GroupScopedMemberHandleV2(rawValue: Data(repeating: 3, count: 32).base64EncodedString())
        func event(_ author: GroupScopedMemberHandleV2, _ clock: UInt64,
                   _ operation: NoctCordOperation) -> NoctCordEvent {
            NoctCordEvent(spaceID: spaceID, author: author, logicalClock: clock, operation: operation)
        }

        let bot = NoctCordBotApplication(
            id: UUID(), memberHandle: botMember, name: "Audit bot",
            commands: [NoctCordBotCommand(name: "status", summary: "Show status")]
        )
        let allowed = event(owner, 4, .invokeBot(NoctCordBotCommandInvocation(
            botID: bot.id, channelID: channelID, commandName: "status"
        )))
        let rejected = event(member, 6, .invokeBot(NoctCordBotCommandInvocation(
            botID: bot.id, channelID: channelID, commandName: "status"
        )))
        let history = [
            event(owner, 1, .createSpace(name: "Community")),
            event(owner, 2, .createChannel(id: channelID, name: "general")),
            event(owner, 3, .installBot(bot)),
            allowed,
            event(owner, 5, .setChannelPermissions(
                channelID: channelID, roleID: nil,
                allow: [], deny: [.useApplicationCommands]
            )),
            rejected,
        ]
        XCTAssertTrue(history.allSatisfy(\.isStructurallyValid))
        let result = NoctCordSpaceProjection.project(
            spaceID: spaceID, owner: owner,
            activeMembers: [owner, member, botMember], events: history
        )
        XCTAssertEqual(result.rejectedEvents.map(\.eventID), [rejected.id])
        XCTAssertEqual(
            NoctCordBotHost.dispatchableInvocations(from: result), [allowed]
        )

        let runtime = NoctCordBotRuntime(
            botID: bot.id,
            memberHandleRawValue: botMember.rawValue,
            ledger: NoctCordInMemoryBotInvocationLedger()
        ) { _ in "ok" }
        do {
            _ = try await runtime.prepareResponse(
                for: rejected, projection: result.projection
            )
            XCTFail("Rejected group event reached the bot runtime")
        } catch let error as NoctCordBotRuntimeError {
            XCTAssertEqual(error, .botUnavailable)
        }

        let updated = NoctCordBotApplication(
            id: bot.id, memberHandle: botMember, name: "Audit bot",
            commands: [NoctCordBotCommand(name: "health", summary: "Show health")]
        )
        let afterCommandRemoval = NoctCordSpaceProjection.project(
            spaceID: spaceID, owner: owner,
            activeMembers: [owner, member, botMember],
            events: history + [event(owner, 7, .updateBot(updated))]
        )
        XCTAssertTrue(afterCommandRemoval.rejectedEvents.map(\.eventID).contains(rejected.id))
        XCTAssertTrue(NoctCordBotHost.dispatchableInvocations(
            from: afterCommandRemoval
        ).isEmpty)
    }

    func testQueuedBotCommandCannotRunAfterInvokerLosesChannelPermission() async throws {
        let spaceID = UUID(), channelID = UUID()
        let owner = GroupScopedMemberHandleV2(rawValue: Data(repeating: 1, count: 32).base64EncodedString())
        let member = GroupScopedMemberHandleV2(rawValue: Data(repeating: 2, count: 32).base64EncodedString())
        let botMember = GroupScopedMemberHandleV2(rawValue: Data(repeating: 3, count: 32).base64EncodedString())
        func event(_ author: GroupScopedMemberHandleV2, _ clock: UInt64,
                   _ operation: NoctCordOperation) -> NoctCordEvent {
            NoctCordEvent(spaceID: spaceID, author: author, logicalClock: clock, operation: operation)
        }
        let bot = NoctCordBotApplication(
            id: UUID(), memberHandle: botMember, name: "Audit bot",
            commands: [NoctCordBotCommand(name: "status", summary: "Show status")]
        )
        let invocation = NoctCordBotCommandInvocation(
            botID: bot.id, channelID: channelID, commandName: "status"
        )
        let command = event(member, 4, .invokeBot(invocation))
        let activeHistory = [
            event(owner, 1, .createSpace(name: "Community")),
            event(owner, 2, .createChannel(id: channelID, name: "general")),
            event(owner, 3, .installBot(bot)),
            command,
        ]
        let active = NoctCordSpaceProjection.project(
            spaceID: spaceID, owner: owner,
            activeMembers: [owner, member, botMember], events: activeHistory
        )
        XCTAssertEqual(NoctCordBotHost.dispatchableInvocations(from: active), [command])

        let revoked = NoctCordSpaceProjection.project(
            spaceID: spaceID, owner: owner, activeMembers: [owner, member, botMember],
            events: activeHistory + [event(owner, 5, .setChannelPermissions(
                channelID: channelID, roleID: nil,
                allow: [], deny: [.useApplicationCommands]
            ))]
        )
        XCTAssertEqual(revoked.acceptedEvents.count, 5)
        XCTAssertNotNil(revoked.projection.botInvocations[invocation.id],
                        "The command was valid when posted and remains in history")
        XCTAssertTrue(NoctCordBotHost.dispatchableInvocations(from: revoked).isEmpty)
        let removed = NoctCordSpaceProjection.project(
            spaceID: spaceID, owner: owner, activeMembers: [owner, botMember],
            historicalMembers: [member], events: activeHistory
        )
        XCTAssertNotNil(removed.projection.botInvocations[invocation.id])
        XCTAssertTrue(NoctCordBotHost.dispatchableInvocations(from: removed).isEmpty,
                      "Historical authors must not retain current bot authority")

        let counter = BotHandlerCounter()
        let runtime = NoctCordBotRuntime(
            botID: bot.id, memberHandleRawValue: botMember.rawValue,
            ledger: NoctCordInMemoryBotInvocationLedger()
        ) { _ in
            await counter.increment()
            return "ok"
        }
        do {
            _ = try await runtime.prepareResponse(for: command, projection: revoked.projection)
            XCTFail("Revoked command reached the handler")
        } catch let error as NoctCordBotRuntimeError {
            XCTAssertEqual(error, .botUnavailable)
        }
        let deniedCount = await counter.value()
        XCTAssertEqual(deniedCount, 0)

        let allowed = try await runtime.prepareResponse(for: command, projection: active.projection)
        XCTAssertNotNil(allowed, "An authorized queued command must still run")
        let allowedCount = await counter.value()
        XCTAssertEqual(allowedCount, 1)
    }

}

private actor BotHandlerCounter {
    private var count = 0
    func increment() { count += 1 }
    func value() -> Int { count }
}
