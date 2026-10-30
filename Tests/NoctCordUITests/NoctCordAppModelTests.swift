import NoctCordCore
import NoctCordMedia
@testable import NoctCordUI
@preconcurrency import NoctweaveCore
import XCTest

@MainActor
final class NoctCordAppModelTests: XCTestCase {
    func testLeavingPendingMediaJoinDoesNotRestoreTheCall() async throws {
        let model = NoctCordAppModel(seedPreviewData: true)
        let requested = expectation(description: "fake microphone permission requested")
        let permissions = NoctCordModelPermissionGate(granted: true, onRequest: { requested.fulfill() })
        let room = try modelMediaRoom(participant: "pending", permissions: permissions)
        let joining = Task { try await model.joinMediaRoom(room) }
        await fulfillment(of: [requested], timeout: 2)

        await model.stopMediaRoom()
        await permissions.release()
        _ = try? await joining.value

        let snapshot = await room.snapshot()
        XCTAssertEqual(snapshot.state, .left)
        XCTAssertNil(model.callSnapshot)
        await room.leave()
        await model.stopMediaRoom()
    }

    func testStaleMediaJoinCannotReplaceOrClearANewerCall() async throws {
        for permissionGranted in [true, false] {
            let model = NoctCordAppModel(seedPreviewData: true)
            let requested = expectation(description: "old fake microphone permission requested")
            let permissions = NoctCordModelPermissionGate(
                granted: permissionGranted, onRequest: { requested.fulfill() }
            )
            let oldRoom = try modelMediaRoom(participant: "old", permissions: permissions)
            let oldJoin = Task { try await model.joinMediaRoom(oldRoom) }
            await fulfillment(of: [requested], timeout: 2)
            await model.stopMediaRoom()
            let newRoom = try modelMediaRoom(participant: "new", permissions: nil)
            try await model.joinMediaRoom(newRoom)

            await permissions.release()
            _ = try? await oldJoin.value

            XCTAssertEqual(model.callSnapshot?.localParticipant.id.rawValue, "new")
            let oldSnapshot = await oldRoom.snapshot()
            XCTAssertEqual(oldSnapshot.state, .left)
            await oldRoom.leave()
            await newRoom.leave()
            await model.stopMediaRoom()
        }
    }

    func testOldMediaControlCompletionCannotRestoreOrFailANewerCall() async throws {
        for controlFails in [false, true] {
            let model = NoctCordAppModel(seedPreviewData: true)
            let started = expectation(description: "fake driver deafen suspended")
            let gate = NoctCordModelControlGate(fails: controlFails, onStart: { started.fulfill() })
            let oldRoom = NoctCordMediaRoom(
                configuration: .init(roomID: "model-room", participant: .init(id: "old"), wantsMicrophone: false),
                driver: NoctCordModelControlDriver(gate: gate)
            )
            try await model.joinMediaRoom(oldRoom)
            let control = Task {
                await model.updateMediaRoom(oldRoom, performing: { try await $0.setDeafened(true) })
            }
            await fulfillment(of: [started], timeout: 2)
            await model.stopMediaRoom()
            let newRoom = try modelMediaRoom(participant: "new", permissions: nil)
            try await model.joinMediaRoom(newRoom)
            let priorConnectionState = model.connectionState

            await gate.release()
            let result = await control.value

            XCTAssertNil(result)
            XCTAssertEqual(model.callSnapshot?.localParticipant.id.rawValue, "new")
            XCTAssertEqual(model.connectionState, priorConnectionState)
            await model.stopMediaRoom()
        }
    }

    func testMediaControlsWaitForPendingJoinToFinish() async throws {
        let model = NoctCordAppModel(seedPreviewData: true)
        let requested = expectation(description: "fake microphone permission pending")
        let permissions = NoctCordModelPermissionGate(granted: true, onRequest: { requested.fulfill() })
        let room = try modelMediaRoom(participant: "pending", permissions: permissions)
        let joining = Task { try await model.joinMediaRoom(room) }
        await fulfillment(of: [requested], timeout: 2)
        let initialSnapshot = await room.snapshot()
        XCTAssertEqual(initialSnapshot.state, .joining)
        let priorConnectionState = model.connectionState

        let pendingControl = await model.updateMediaRoom(room, performing: { try await $0.setDeafened(true) })

        XCTAssertNil(pendingControl)
        XCTAssertEqual(model.connectionState, priorConnectionState)
        await permissions.release()
        try await joining.value
        let joinedControl = await model.updateMediaRoom(room, performing: { try await $0.setDeafened(true) })
        XCTAssertEqual(joinedControl?.deafened, true)
        await model.stopMediaRoom()
    }

    func testVerifiedMediaStateRequiresTeardownOnEpochRemovalAndRoomCredentialChanges() throws {
        let preview = NoctCordAppModel(seedPreviewData: true)
        let relay = try XCTUnwrap(preview.selectedSpace?.relayAssessment)
        let spaceID = UUID()
        let roomID = UUID()
        let owner = GroupScopedMemberHandleV2.generate()
        let member = GroupScopedMemberHandleV2.generate()
        let current = try verifiedMediaSession(
            spaceID: spaceID, roomID: roomID, owner: owner, member: member,
            relay: relay, routeByte: 0x11, keyByte: 0x21
        )
        XCTAssertFalse(NoctCordAppModel.mediaStateRequiresStop(
            roomID: roomID, previous: current, updated: current
        ))

        var newEpoch = current
        newEpoch.groupEpoch += 1
        XCTAssertTrue(NoctCordAppModel.mediaStateRequiresStop(
            roomID: roomID, previous: current, updated: newEpoch
        ))

        let removedMember = try verifiedMediaSession(
            spaceID: spaceID, roomID: roomID, owner: owner, member: member,
            relay: relay, routeByte: 0x11, keyByte: 0x21, memberIsActive: false
        )
        XCTAssertFalse(removedMember.projection.activeMembers.contains(member))
        XCTAssertTrue(NoctCordAppModel.mediaStateRequiresStop(
            roomID: roomID, previous: current, updated: removedMember
        ))

        let newRoute = try verifiedMediaSession(
            spaceID: spaceID, roomID: roomID, owner: owner, member: member,
            relay: relay, routeByte: 0x12, keyByte: 0x21
        )
        XCTAssertTrue(NoctCordAppModel.mediaStateRequiresStop(
            roomID: roomID, previous: current, updated: newRoute
        ))

        let newKey = try verifiedMediaSession(
            spaceID: spaceID, roomID: roomID, owner: owner, member: member,
            relay: relay, routeByte: 0x11, keyByte: 0x22
        )
        XCTAssertTrue(NoctCordAppModel.mediaStateRequiresStop(
            roomID: roomID, previous: current, updated: newKey
        ))

        var unverified = current
        unverified.policyMode = .awaitingOwnerCheckpoint
        XCTAssertTrue(NoctCordAppModel.mediaStateRequiresStop(
            roomID: roomID, previous: current, updated: unverified
        ))
        XCTAssertTrue(NoctCordAppModel.mediaStateRequiresStop(
            roomID: roomID, previous: current, updated: nil
        ))
    }

    private func verifiedMediaSession(
        spaceID: UUID,
        roomID: UUID,
        owner: GroupScopedMemberHandleV2,
        member: GroupScopedMemberHandleV2,
        relay: NoctCordRelayAssessment,
        routeByte: UInt8,
        keyByte: UInt8,
        memberIsActive: Bool = true
    ) throws -> NoctCordSpaceSession {
        let route = NoctCordRealtimeRouteV1(
            routeCapability: Data(repeating: routeByte, count: 32),
            appendCapability: Data(repeating: routeByte &+ 0x30, count: 32),
            readCapability: Data(repeating: routeByte &+ 0x60, count: 32),
            expiresAt: Date(timeIntervalSince1970: 2_000_000_000)
        )
        let events = [
            NoctCordEvent(
                spaceID: spaceID, author: owner, logicalClock: 1,
                operation: .createSpace(name: "Call test")
            ),
            NoctCordEvent(
                spaceID: spaceID, author: owner, logicalClock: 2,
                operation: .createVoiceRoom(
                    id: roomID,
                    spec: NoctCordVoiceRoomSpecV1(
                        name: "Call", signalingKey: Data(repeating: keyByte, count: 32),
                        realtimeRoute: route
                    )
                )
            ),
        ]
        let active: Set<GroupScopedMemberHandleV2> = memberIsActive ? [owner, member] : [owner]
        let result = NoctCordSpaceProjection.project(
            spaceID: spaceID, owner: owner, activeMembers: active, events: events
        )
        XCTAssertTrue(result.rejectedEvents.isEmpty)
        XCTAssertNotNil(result.projection.voiceRooms[roomID])
        return NoctCordSpaceSession(
            id: spaceID,
            groupEpoch: 2,
            shortName: "CT",
            currentMember: member,
            identityScope: .isolated,
            members: [
                NoctCordMemberViewState(
                    id: owner, displayName: "Owner", roleName: "Owner", presence: .active
                ),
                NoctCordMemberViewState(
                    id: member, displayName: "Member", roleName: "Member", presence: .active
                ),
            ],
            events: events,
            policyMode: .verified,
            legacyArchiveEvents: [],
            legacyArchiveProjection: nil,
            projection: result.projection,
            unreadByChannel: [:],
            voiceRooms: [NoctCordUI.NoctCordVoiceRoom(id: roomID, name: "Call", participantCount: 0)],
            activeVoiceRoomID: roomID,
            relayName: "Test relay",
            relayAssessment: relay
        )
    }

    private func modelMediaRoom(
        participant: String,
        permissions: NoctCordModelPermissionGate?
    ) throws -> NoctCordMediaRoom {
        NoctCordMediaRoom(
            configuration: .init(
                roomID: "model-room",
                participant: .init(id: try NoctCordMediaParticipantID(participant), displayName: participant),
                wantsMicrophone: permissions != nil
            ),
            driver: NoctCordInMemoryMediaDriver(),
            permissionProvider: permissions ?? NoctCordModelPermissionGate(granted: true)
        )
    }

    func testPurgeDrainsPendingPreviewWorkAndReturnsToSetup() async throws {
        let model = NoctCordAppModel(seedPreviewData: true)
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("noctcord-reset-input-\(UUID()).txt")
        defer { try? FileManager.default.removeItem(at: file) }
        try Data("private attachment".utf8).write(to: file)
        model.sendAttachment(at: file)
        model.composerText = "unsent draft"
        model.searchQuery = "private search"
        var resetCompleted = false
        model.onResetCompleted = { resetCompleted = true }
        await model.purgeAndReset()
        XCTAssertTrue(resetCompleted)
        XCTAssertFalse(model.isResetting)
        XCTAssertTrue(model.spaces.isEmpty)
        XCTAssertTrue(model.cachedAttachments.isEmpty)
        XCTAssertTrue(model.composerText.isEmpty)
        XCTAssertTrue(model.searchQuery.isEmpty)
        XCTAssertEqual(model.connectionState, .needsSetup)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
    }

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

    func testInvalidMessageAndCommandKeepTheDraftForCorrection() throws {
        let model = NoctCordAppModel(seedPreviewData: true)
        let originalEventCount = try XCTUnwrap(model.selectedSpace?.events.count)
        for draft in [
            String(repeating: "a", count: 16_385),
            "/status " + String(repeating: "a", count: 2_049),
        ] {
            model.composerText = draft

            model.sendCurrentMessage()

            XCTAssertEqual(model.composerText, draft)
            XCTAssertEqual(model.selectedSpace?.events.count, originalEventCount)
            XCTAssertNotNil(model.composerNotice)
        }
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

    func testSelectingCommunityMarksItsVisibleChannelRead() throws {
        let model = NoctCordAppModel(seedPreviewData: true)
        let nextSpace = try XCTUnwrap(model.spaces.last)
        let nextChannel = try XCTUnwrap(nextSpace.textChannels.first)
        XCTAssertGreaterThan(nextSpace.unreadByChannel[nextChannel.id, default: 0], 0)

        model.selectSpace(nextSpace.id)

        XCTAssertEqual(model.selectedChannelID, nextChannel.id)
        XCTAssertEqual(model.selectedSpace?.unreadByChannel[nextChannel.id], 0)
    }

    func testUnreadCountsTrackNewRemoteMessagesWithoutCountingRefreshesOrOwnMessages() throws {
        let model = NoctCordAppModel(seedPreviewData: true)
        let original = try XCTUnwrap(model.spaces.first)
        let channel = try XCTUnwrap(original.textChannels.first)
        let remote = try XCTUnwrap(original.members.first { $0.id != original.currentMember })
        var updated = original
        let remoteEvent = NoctCordEvent(
            spaceID: original.id,
            author: remote.id,
            logicalClock: try updated.projection.nextLogicalClock(),
            operation: .postMessage(id: UUID(), channelID: channel.id, text: "New remote message")
        )
        try updated.projection.apply(remoteEvent)
        updated.events.append(remoteEvent)

        updated.reconcileUnreadCounts(from: original, visibleChannelID: nil)

        let expectedUnread = original.unreadByChannel[channel.id, default: 0] + 1
        XCTAssertEqual(updated.unreadByChannel[channel.id], expectedUnread)
        var refreshed = updated
        refreshed.reconcileUnreadCounts(from: updated, visibleChannelID: nil)
        XCTAssertEqual(refreshed.unreadByChannel[channel.id], expectedUnread)

        let ownEvent = NoctCordEvent(
            spaceID: original.id,
            author: original.currentMember,
            logicalClock: try refreshed.projection.nextLogicalClock(),
            operation: .postMessage(id: UUID(), channelID: channel.id, text: "My reply")
        )
        try refreshed.projection.apply(ownEvent)
        refreshed.events.append(ownEvent)
        refreshed.reconcileUnreadCounts(from: updated, visibleChannelID: nil)
        XCTAssertEqual(refreshed.unreadByChannel[channel.id], expectedUnread)

        updated.reconcileUnreadCounts(from: refreshed, visibleChannelID: channel.id)
        XCTAssertEqual(updated.unreadByChannel[channel.id], 0)
    }

    func testUnreadCountsDiscardArchivedChannelsAndDoNotCountInitialHistory() throws {
        let model = NoctCordAppModel(seedPreviewData: true)
        let original = try XCTUnwrap(model.spaces.first)
        let unreadChannelID = try XCTUnwrap(original.unreadByChannel.first { $0.value > 0 }?.key)
        var loaded = original
        loaded.reconcileUnreadCounts(from: nil, visibleChannelID: nil)
        XCTAssertEqual(loaded.unreadByChannel.values.reduce(0, +), 0)

        let archive = NoctCordEvent(
            spaceID: original.id,
            author: original.currentMember,
            logicalClock: try loaded.projection.nextLogicalClock(),
            operation: .archiveChannel(id: unreadChannelID)
        )
        try loaded.projection.apply(archive)
        loaded.events.append(archive)
        loaded.reconcileUnreadCounts(from: original, visibleChannelID: nil)
        XCTAssertNil(loaded.unreadByChannel[unreadChannelID])
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

    func testSlashCommandAllowsWhitespaceBetweenCommandAndArguments() throws {
        let model = NoctCordAppModel(seedPreviewData: true)
        let originalEventCount = try XCTUnwrap(model.selectedSpace?.events.count)
        model.composerText = "/status   relay"

        model.sendCurrentMessage()

        XCTAssertEqual(model.selectedSpace?.events.count, originalEventCount + 1)
        XCTAssertEqual(model.selectedSpace?.events.last?.operation.botInvocation?.arguments, "relay")
        XCTAssertTrue(model.composerText.isEmpty)
        XCTAssertNil(model.composerNotice)
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

private actor NoctCordModelPermissionGate: NoctCordMediaPermissionProvider {
    private let granted: Bool
    private let onRequest: @Sendable () -> Void
    private var isReleased = false
    private var waiter: CheckedContinuation<Void, Never>?

    init(granted: Bool, onRequest: @escaping @Sendable () -> Void = {}) {
        self.granted = granted
        self.onRequest = onRequest
    }

    func request(_ permissions: Set<NoctCordMediaPermission>) async throws -> NoctCordMediaPermissionSnapshot {
        onRequest()
        if !isReleased { await withCheckedContinuation { waiter = $0 } }
        guard granted else { throw NoctCordMediaError.permissionDenied(.microphone) }
        return .init(microphone: .granted)
    }

    func release() {
        isReleased = true
        waiter?.resume()
        waiter = nil
    }
}

private actor NoctCordModelControlGate {
    private let fails: Bool
    private let onStart: @Sendable () -> Void
    private var isReleased = false
    private var waiter: CheckedContinuation<Void, Never>?
    init(fails: Bool, onStart: @escaping @Sendable () -> Void) {
        self.fails = fails
        self.onStart = onStart
    }
    func run() async throws {
        onStart()
        if !isReleased { await withCheckedContinuation { waiter = $0 } }
        if fails { throw NoctCordMediaError.transportFailure("fake deafen failure") }
    }
    func release() { isReleased = true; waiter?.resume(); waiter = nil }
}

private struct NoctCordModelControlDriver: NoctCordMediaDriver {
    let gate: NoctCordModelControlGate
    func makeSession(
        configuration: NoctCordMediaRoomConfiguration,
        eventHandler: @escaping @Sendable (NoctCordMediaDriverEvent) -> Void,
        signalingSink: any NoctCordMediaSignalingSink
    ) async throws -> any NoctCordMediaDriverSession {
        NoctCordModelControlSession(gate: gate)
    }
}

private actor NoctCordModelControlSession: NoctCordMediaDriverSession {
    let gate: NoctCordModelControlGate
    init(gate: NoctCordModelControlGate) { self.gate = gate }
    func join() async throws {}
    func leave() async {}
    func send(_ signal: NoctCordMediaSignal, to recipient: NoctCordMediaParticipantID?) async throws -> NoctCordMediaSignalEnvelope {
        try NoctCordMediaSignalEnvelope(roomID: "model-room", sender: "old", recipient: recipient,
            sequence: 1, timestampMilliseconds: 1, signal: signal)
    }
    func handleIncomingSignal(_ envelope: NoctCordMediaSignalEnvelope) async throws {}
    func setMicrophoneEnabled(_ enabled: Bool) async throws {}
    func setDeafened(_ enabled: Bool) async throws { try await gate.run() }
    func publishScreenShare(_ track: NoctCordScreenShareTrack) async throws {}
    func stopScreenShare() async throws {}
}
