import NoctCordCore
@testable import NoctCordUI
import XCTest

@MainActor
final class NoctCordAppModelTests: XCTestCase {
    func testPreviewUsesRealProjectionAndDurableRealtimeRelayAssessment() {
        let model = NoctCordAppModel(seedPreviewData: true)

        XCTAssertEqual(model.selectedSpace?.relayAssessment.tier, .durableCommunity)
        XCTAssertEqual(model.selectedSpace?.relayAssessment.deliveryProfile, .immediate)
        XCTAssertFalse(model.selectedMessages.isEmpty)
        XCTAssertFalse(model.selectedSpace?.projection.channels.isEmpty ?? true)
    }

    func testSendingMessageAppendsAnEventAndUpdatesVisibleProjection() {
        let model = NoctCordAppModel(seedPreviewData: true)
        let originalEventCount = model.selectedSpace?.events.count
        let originalMessageCount = model.selectedMessages.count

        model.composerText = "A message created by the UI model"
        model.sendCurrentMessage()

        XCTAssertEqual(model.selectedSpace?.events.count, (originalEventCount ?? 0) + 1)
        XCTAssertEqual(model.selectedMessages.count, originalMessageCount + 1)
        XCTAssertEqual(model.selectedMessages.last?.text, "A message created by the UI model")
        XCTAssertTrue(model.composerText.isEmpty)
    }

    func testPreviewSpaceCreationDefaultsToOneProjectedGeneralChannel() {
        let model = NoctCordAppModel(seedPreviewData: true)
        let originalSpaceCount = model.spaces.count

        model.createSpace(name: "Quiet Circle", identityScope: .isolated)

        XCTAssertEqual(model.spaces.count, originalSpaceCount + 1)
        XCTAssertEqual(model.selectedSpace?.name, "Quiet Circle")
        XCTAssertEqual(model.selectedSpace?.identityScope, .isolated)
        XCTAssertEqual(model.selectedSpace?.textChannels.map(\.name), ["general"])
        XCTAssertEqual(model.selectedSpace?.relayAssessment.tier, .encryptedGroupFallback)
    }

    func testProductionSpaceCreationRequiresAConnectedRelay() {
        let model = NoctCordAppModel(seedPreviewData: false)

        model.createSpace(name: "Quiet Circle", identityScope: .isolated)

        XCTAssertTrue(model.spaces.isEmpty)
        XCTAssertEqual(
            model.connectionState,
            .failed("Connect a relay before creating a space.")
        )
    }

    func testSelectingChannelClearsItsUnreadCount() throws {
        let model = NoctCordAppModel(seedPreviewData: true)
        let unreadChannel = try XCTUnwrap(
            model.selectedSpace?.unreadByChannel.first(where: { $0.value > 0 })?.key
        )

        model.selectChannel(unreadChannel)

        XCTAssertEqual(model.selectedSpace?.unreadByChannel[unreadChannel], 0)
    }

    func testIdentityScopeCanChangePerCommunity() {
        let model = NoctCordAppModel(seedPreviewData: true)
        let firstSpaceID = model.spaces[0].id
        let secondSpaceID = model.spaces[1].id
        XCTAssertEqual(model.selectedSpace?.identityScope, .portable)

        model.setIdentityScope(.isolated)
        model.selectSpace(secondSpaceID)
        model.setIdentityScope(.portable)

        XCTAssertEqual(model.spaces.first { $0.id == firstSpaceID }?.identityScope, .isolated)
        XCTAssertEqual(model.spaces.first { $0.id == secondSpaceID }?.identityScope, .portable)
    }

    func testMemberCannotCreateChannelWithoutPermission() {
        let model = NoctCordAppModel(seedPreviewData: true)
        let memberSpaceID = model.spaces[1].id
        model.selectSpace(memberSpaceID)
        let originalEventCount = model.selectedSpace?.events.count

        model.createChannel(name: "not-authorized")

        XCTAssertEqual(model.selectedSpace?.events.count, originalEventCount)
        XCTAssertFalse(model.selectedSpace?.textChannels.contains { $0.name == "not-authorized" } ?? true)
    }

    func testReadOnlyAndHiddenChannelPoliciesReachTheComposerAndSidebar() throws {
        let model = NoctCordAppModel(seedPreviewData: true)
        let memberSpaceID = model.spaces[1].id
        model.selectSpace(memberSpaceID)

        XCTAssertEqual(model.selectedSpace?.textChannels.map(\.name), ["spec-review"])
        XCTAssertFalse(model.canSendInSelectedChannel)

        let originalEventCount = try XCTUnwrap(model.selectedSpace?.events.count)
        model.composerText = "This must not publish"
        model.sendCurrentMessage()

        XCTAssertEqual(model.selectedSpace?.events.count, originalEventCount)
        XCTAssertFalse(model.composerText.isEmpty)
        XCTAssertNotNil(model.composerNotice)
    }

    func testSlashCommandPublishesAProjectedBotInvocation() throws {
        let model = NoctCordAppModel(seedPreviewData: true)
        let originalEventCount = try XCTUnwrap(model.selectedSpace?.events.count)

        model.composerText = "/status relay"
        model.sendCurrentMessage()

        XCTAssertEqual(model.selectedSpace?.events.count, originalEventCount + 1)
        XCTAssertEqual(model.selectedSpace?.events.last?.operation.kind, .botCommandInvoked)
        XCTAssertEqual(model.selectedMessages.last?.text, "/status relay")
        XCTAssertTrue(model.composerText.isEmpty)
    }

    func testRoleManagementUpdatesPreviewProjection() throws {
        let model = NoctCordAppModel(seedPreviewData: true)
        let roleID = UUID()
        let member = try XCTUnwrap(
            model.selectedSpace?.members.first { $0.displayName == "Mara" }
        )

        model.saveRole(
            id: roleID,
            name: "Reviewer",
            position: 12,
            permissions: [.manageMessages]
        )
        model.setRole(roleID, for: member.id, assigned: true)

        XCTAssertEqual(model.selectedSpace?.projection.roles[roleID]?.name, "Reviewer")
        XCTAssertTrue(
            model.selectedSpace?.projection.roleAssignments[member.id, default: []]
                .contains(roleID) == true
        )
    }
}
