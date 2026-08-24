import NoctCordCore
@testable import NoctCordUI
@preconcurrency import NoctweaveCore
import XCTest

@MainActor
final class NoctCordAppModelTests: XCTestCase {
    func testStateScopesSeparateSandboxedAppFromDevelopmentRuns() {
        let sandboxed = URL(fileURLWithPath:
            "/Users/member/Library/Containers/org.noctweave.noctcord/Data/Library/Application Support/NoctCord/client-state.noctcord"
        )
        let development = URL(fileURLWithPath:
            "/Users/member/Library/Application Support/NoctCord/client-state.noctcord"
        )

        XCTAssertEqual(
            NoctCordTransportConfiguration.defaultStorageScopeIdentifier(
                for: sandboxed
            ),
            "org.noctcord.client-state.macos-sandbox.v1"
        )
        XCTAssertEqual(
            NoctCordTransportConfiguration.defaultStorageScopeIdentifier(
                for: development
            ),
            "org.noctcord.client-state.v1"
        )
    }

    func testRollbackFailureExplainsThatRelayWasNotContacted() {
        let presentation = NoctCordConnectionFailurePresentation(
            error: ClientStateStoreError.rollbackDetected
        )

        XCTAssertTrue(presentation.permitsLocalStateReset)
        XCTAssertTrue(presentation.message.contains("rollback anchor"))
        XCTAssertTrue(presentation.message.contains("No relay request was sent"))
    }

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

    func testPreviewAttachmentPickerSanitizesAndProjectsSelectedFile() async throws {
        let model = NoctCordAppModel(seedPreviewData: true)
        let originalAttachmentCount = model.selectedAttachments.count
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("noctcord-preview-attachment-\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: fileURL) }
        try Data("preview attachment\r\n".utf8).write(to: fileURL, options: .atomic)

        model.sendAttachment(at: fileURL)

        for _ in 0..<100 where model.selectedAttachments.count == originalAttachmentCount {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertNil(model.composerNotice, model.composerNotice ?? "Unexpected attachment error")
        if case .failed(let message) = model.connectionState {
            XCTFail(message)
        }
        let attachment = try XCTUnwrap(model.selectedAttachments.last)
        XCTAssertEqual(model.selectedAttachments.count, originalAttachmentCount + 1)
        XCTAssertEqual(attachment.mediaType, "text/plain")
        XCTAssertTrue(attachment.isAvailableLocally)
        XCTAssertNotNil(model.cachedAttachments[attachment.id])
        XCTAssertEqual(model.selectedSpace?.events.last?.operation.kind, .attachmentAdded)
        XCTAssertNil(model.activityMessage)
        XCTAssertNil(model.composerNotice)
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

    func testDisplayNameCanUpdateAcrossPreviewCommunities() async throws {
        let model = NoctCordAppModel(seedPreviewData: true)
        let currentMembers = Dictionary(uniqueKeysWithValues: model.spaces.map {
            ($0.id, $0.currentMember)
        })

        let updated = await model.updateDisplayName(
            "River",
            acrossAllCommunities: true
        )

        XCTAssertTrue(updated)
        XCTAssertEqual(model.userDisplayName, "River")
        for space in model.spaces {
            let currentMember = try XCTUnwrap(currentMembers[space.id])
            XCTAssertEqual(
                space.members.first { $0.id == currentMember }?.displayName,
                "River"
            )
        }
    }

    func testUserAndCommunitySettingsHaveIndependentPresentationState() {
        let model = NoctCordAppModel(seedPreviewData: true)

        model.showsUserSettings = true
        XCTAssertTrue(model.showsUserSettings)
        XCTAssertFalse(model.showsCommunitySettings)

        model.showsUserSettings = false
        model.showsCommunitySettings = true
        XCTAssertFalse(model.showsUserSettings)
        XCTAssertTrue(model.showsCommunitySettings)
    }

    func testPrivacyPreferencesCanChangeInPreviewMode() {
        let model = NoctCordAppModel(seedPreviewData: true)
        var privacy = model.privacySettings
        privacy.hideSensitiveWhenUnfocused = false
        privacy.macBlockWindowCapture = false
        privacy.secureTypingEnabled = false

        model.setPrivacySettings(privacy)

        XCTAssertEqual(model.privacySettings, privacy)
        XCTAssertEqual(
            model.settingsNotice,
            "Privacy preferences are active on this device."
        )
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

    func testCommunityLifecycleControlsFollowTheLocalMembershipRole() throws {
        let model = NoctCordAppModel(seedPreviewData: true)
        let ownerSpace = try XCTUnwrap(model.spaces.first)
        let memberSpace = try XCTUnwrap(model.spaces.first(where: { !$0.isCurrentUserOwner }))

        model.selectSpace(ownerSpace.id)
        XCTAssertTrue(try XCTUnwrap(model.selectedSpace).isCurrentUserOwner)

        model.selectSpace(memberSpace.id)
        XCTAssertFalse(try XCTUnwrap(model.selectedSpace).isCurrentUserOwner)
    }

    func testPreviewMemberCanLeaveAndOwnerCanDestroy() async throws {
        let model = NoctCordAppModel(seedPreviewData: true)
        let ownerSpace = try XCTUnwrap(model.spaces.first(where: \.isCurrentUserOwner))
        let memberSpace = try XCTUnwrap(model.spaces.first(where: { !$0.isCurrentUserOwner }))

        model.selectSpace(memberSpace.id)
        try await model.leaveSelectedCommunity()
        XCTAssertFalse(model.spaces.contains { $0.id == memberSpace.id })

        model.selectSpace(ownerSpace.id)
        try await model.destroySelectedCommunity()
        XCTAssertFalse(model.spaces.contains { $0.id == ownerSpace.id })
    }
}
