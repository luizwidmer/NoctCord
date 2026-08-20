import SwiftUI
import NoctCordCore
import NoctCordMedia
#if os(macOS)
import AppKit
#elseif os(iOS)
import UIKit
#endif

struct NoctCordSpaceRail: View {
    @ObservedObject var model: NoctCordAppModel

    var body: some View {
        VStack(spacing: 12) {
            NoctCordMark()
                .frame(width: 44, height: 44)
                .padding(.bottom, 10)

            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 10) {
                    ForEach(model.spaces) { space in
                        SpaceRailButton(
                            title: space.name,
                            shortName: space.shortName,
                            isSelected: model.selectedSpaceID == space.id,
                            unreadCount: space.unreadByChannel.values.reduce(0, +)
                        ) {
                            model.selectSpace(space.id)
                        }
                    }
                }
                .padding(.vertical, 2)
            }

            Menu {
                Button {
                    model.showsCreateSpace = true
                } label: {
                    Label("Create community", systemImage: "plus")
                }
                Button {
                    model.showsJoinSpace = true
                } label: {
                    Label("Join with invitation", systemImage: "person.crop.circle.badge.plus")
                }
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 16, weight: .semibold))
                    .frame(width: 42, height: 42)
                    .background(NoctCordTheme.surface)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .stroke(NoctCordTheme.border, lineWidth: 1)
                    }
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .foregroundStyle(NoctCordTheme.mutedCoral)
            .help("Create or join a community")

            Spacer(minLength: 12)

            Menu {
                ForEach(NoctCordAppearance.allCases) { appearance in
                    Button {
                        model.appearance = appearance
                    } label: {
                        Label(appearance.title, systemImage: appearance.symbol)
                    }
                }
            } label: {
                Image(systemName: model.appearance.symbol)
                    .font(.system(size: 14, weight: .medium))
                    .frame(width: 36, height: 36)
                    .background(NoctCordTheme.surface.opacity(0.72))
                    .clipShape(Circle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .foregroundStyle(NoctCordTheme.secondaryText)
            .help("Appearance")
        }
        .padding(.top, 40)
        .padding(.bottom, 16)
        .frame(width: 74)
        .background(NoctCordTheme.rail)
        .overlay(alignment: .trailing) {
            Rectangle()
                .fill(NoctCordTheme.border)
                .frame(width: 1)
        }
    }
}

private struct SpaceRailButton: View {
    let title: String
    let shortName: String
    let isSelected: Bool
    let unreadCount: Int
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            ZStack(alignment: .topTrailing) {
                Text(shortName)
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .foregroundStyle(
                        isSelected ? NoctCordTheme.warmIvory : NoctCordTheme.primaryText
                    )
                    .frame(width: 44, height: 44)
                    .background {
                        RoundedRectangle(cornerRadius: isSelected ? 15 : 17, style: .continuous)
                            .fill(
                                isSelected
                                    ? AnyShapeStyle(
                                        LinearGradient(
                                            colors: [NoctCordTheme.mutedCoral, NoctCordTheme.deepWine],
                                            startPoint: .topLeading,
                                            endPoint: .bottomTrailing
                                        )
                                    )
                                    : AnyShapeStyle(NoctCordTheme.surface)
                            )
                    }
                    .overlay {
                        RoundedRectangle(cornerRadius: isSelected ? 15 : 17, style: .continuous)
                            .stroke(
                                isHovered ? NoctCordTheme.mutedCoral.opacity(0.55) : NoctCordTheme.border,
                                lineWidth: 1
                            )
                    }
                    .scaleEffect(isHovered ? 1.04 : 1)

                if unreadCount > 0 {
                    Text(unreadCount > 9 ? "9+" : "\(unreadCount)")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 4)
                        .frame(minWidth: 16, minHeight: 16)
                        .background(NoctCordTheme.deepWine, in: Capsule())
                        .offset(x: 4, y: -4)
                }
            }
            .animation(.easeOut(duration: 0.16), value: isHovered)
        }
        .buttonStyle(.plain)
        .noctCordOnHover { isHovered = $0 }
        .help(title)
        .accessibilityLabel(title)
    }
}

struct NoctCordChannelSidebar: View {
    @ObservedObject var model: NoctCordAppModel

    var body: some View {
        VStack(spacing: 0) {
            if let space = model.selectedSpace {
                VStack(alignment: .leading, spacing: 7) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(space.name)
                            .font(.system(size: 20, weight: .bold, design: .rounded))
                            .foregroundStyle(NoctCordTheme.primaryText)
                            .lineLimit(1)
                        Spacer()
                        if model.canInviteToSelectedSpace {
                            Button {
                                model.showsInvitationExchange = true
                            } label: {
                                Image(systemName: "person.crop.circle.badge.plus")
                                    .font(.system(size: 13, weight: .semibold))
                                    .frame(width: 30, height: 30)
                                    .background(NoctCordTheme.surface, in: Circle())
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(NoctCordTheme.secondaryText)
                            .help("Invite a member")
                        }
                        Button {
                            model.showsCommunitySettings = true
                        } label: {
                            Image(systemName: "slider.horizontal.3")
                                .font(.system(size: 13, weight: .semibold))
                                .frame(width: 30, height: 30)
                                .background(NoctCordTheme.surface, in: Circle())
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(NoctCordTheme.secondaryText)
                        .help("Community settings")
                    }

                    HStack(spacing: 7) {
                        Circle()
                            .fill(relayColor(space.relayAssessment))
                            .frame(width: 7, height: 7)
                        Text("\(space.relayName) · \(compactRelayLabel(space.relayAssessment))")
                            .lineLimit(1)
                    }
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(NoctCordTheme.secondaryText)
                }
                .padding(.horizontal, 18)
                .padding(.bottom, 15)
                .frame(height: NoctCordTheme.headerHeight, alignment: .bottom)

                Divider().overlay(NoctCordTheme.border)

                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 22) {
                        channelSection(space)
                        voiceSection(space)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 18)
                }

                VStack(spacing: 0) {
                    if let activeRoomID = space.activeVoiceRoomID,
                       let room = space.voiceRooms.first(where: { $0.id == activeRoomID }) {
                        Divider().overlay(NoctCordTheme.border)
                        ActiveVoiceDock(model: model, room: room)
                    }
                    Divider().overlay(NoctCordTheme.border)
                    currentIdentityFooter(space)
                }
            } else {
                Spacer()
                Text("Select a space")
                    .foregroundStyle(NoctCordTheme.secondaryText)
                Spacer()
            }
        }
        .frame(width: 248)
        .background(NoctCordTheme.navigation)
        .overlay(alignment: .trailing) {
            Rectangle().fill(NoctCordTheme.border).frame(width: 1)
        }
    }

    private func channelSection(_ space: NoctCordSpaceSession) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            sectionHeader(
                "Text channels",
                action: space.canManageChannels
                    ? { model.showsCreateChannel = true }
                    : nil
            )
            ForEach(space.textChannels) { channel in
                ChannelRow(
                    channel: channel,
                    unreadCount: space.unreadByChannel[channel.id, default: 0],
                    isSelected: model.selectedChannelID == channel.id
                ) {
                    model.selectChannel(channel.id)
                }
            }
        }
    }

    private func voiceSection(_ space: NoctCordSpaceSession) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            sectionHeader(
                "Voice rooms",
                action: space.canManageChannels
                    ? { model.showsCreateVoiceRoom = true }
                    : nil
            )
            if space.voiceRooms.isEmpty {
                Text("No rooms yet")
                    .font(.system(size: 12))
                    .foregroundStyle(NoctCordTheme.secondaryText.opacity(0.72))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
            } else {
                ForEach(space.voiceRooms) { room in
                    VoiceRoomRow(
                        room: room,
                        isActive: space.activeVoiceRoomID == room.id
                    ) {
                        model.joinVoiceRoom(room.id)
                    }
                }
            }
        }
    }

    private func sectionHeader(_ title: String, action: (() -> Void)?) -> some View {
        HStack {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .bold))
                .tracking(0.8)
            Spacer()
            if let action {
                Button(action: action) {
                    Image(systemName: "plus")
                        .font(.system(size: 11, weight: .bold))
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.plain)
                .help("Add \(title.lowercased())")
            }
        }
        .foregroundStyle(NoctCordTheme.secondaryText)
        .padding(.horizontal, 7)
    }

    private func currentIdentityFooter(_ space: NoctCordSpaceSession) -> some View {
        Button {
            model.showsUserSettings = true
        } label: {
            HStack(spacing: 10) {
                MemberMonogram(
                    initials: model.currentMember?.initials ?? "?",
                    presence: .active,
                    size: 34
                )
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.currentMember?.displayName ?? "Unknown")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(NoctCordTheme.primaryText)
                    Text(space.identityScope == .portable ? "Portable profile" : "Isolated here")
                        .font(.system(size: 10))
                        .foregroundStyle(NoctCordTheme.secondaryText)
                }
                Spacer()
                Image(systemName: space.identityScope == .portable ? "link" : "eye.slash")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(NoctCordTheme.mutedCoral)
                    .frame(width: 28, height: 28)
                    .background(NoctCordTheme.mutedCoral.opacity(0.10), in: Circle())
            }
            .padding(.horizontal, 14)
            .frame(height: NoctCordTheme.footerHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Your profile, privacy, relays, and appearance")
    }

    private func relayColor(_ assessment: NoctCordRelayAssessment) -> Color {
        switch assessment.tier {
        case .durableCommunity, .realtimeMVP: NoctCordTheme.success
        case .encryptedGroupFallback: NoctCordTheme.warning
        case .incompatible: NoctCordTheme.mutedCoral
        }
    }

    private func compactRelayLabel(_ assessment: NoctCordRelayAssessment) -> String {
        switch assessment.tier {
        case .durableCommunity: "Realtime"
        case .realtimeMVP: "Realtime"
        case .encryptedGroupFallback: "Compatible"
        case .incompatible: "Unavailable"
        }
    }
}

private struct ChannelRow: View {
    let channel: NoctCordChannel
    let unreadCount: Int
    let isSelected: Bool
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: "number")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(isSelected ? NoctCordTheme.mutedCoral : NoctCordTheme.secondaryText)
                Text(channel.name)
                    .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
                    .lineLimit(1)
                Spacer(minLength: 4)
                if unreadCount > 0 {
                    Text("\(unreadCount)")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .frame(minHeight: 18)
                        .background(NoctCordTheme.mutedCoral, in: Capsule())
                }
            }
            .foregroundStyle(NoctCordTheme.primaryText)
            .padding(.horizontal, 10)
            .frame(height: 34)
            .background(
                isSelected
                    ? NoctCordTheme.mutedCoral.opacity(0.14)
                    : isHovered ? NoctCordTheme.surface.opacity(0.82) : Color.clear,
                in: RoundedRectangle(cornerRadius: 10, style: .continuous)
            )
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .noctCordOnHover { isHovered = $0 }
    }
}

private struct ActiveVoiceDock: View {
    @ObservedObject var model: NoctCordAppModel
    let room: NoctCordVoiceRoom

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "waveform.circle.fill")
                    .foregroundStyle(NoctCordTheme.success)
                VStack(alignment: .leading, spacing: 2) {
                    Text(room.name)
                        .font(.system(size: 11.5, weight: .semibold))
                        .lineLimit(1)
                    Text(connectionLabel)
                        .font(.system(size: 9.5))
                        .foregroundStyle(NoctCordTheme.secondaryText)
                }
                Spacer()
                Button {
                    model.joinVoiceRoom(room.id)
                } label: {
                    Image(systemName: "phone.down.fill")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 30, height: 30)
                        .background(NoctCordTheme.mutedCoral, in: Circle())
                }
                .buttonStyle(.plain)
                .help("Leave voice room")
            }

            HStack(spacing: 8) {
                callButton(
                    model.callSnapshot?.microphoneMuted == true ? "mic.slash.fill" : "mic.fill",
                    active: model.callSnapshot?.microphoneMuted == true,
                    help: "Mute microphone"
                ) {
                    model.setCallMuted(!(model.callSnapshot?.microphoneMuted ?? false))
                }
                callButton(
                    model.callSnapshot?.deafened == true ? "speaker.slash.fill" : "speaker.wave.2.fill",
                    active: model.callSnapshot?.deafened == true,
                    help: "Deafen"
                ) {
                    model.setCallDeafened(!(model.callSnapshot?.deafened ?? false))
                }
                callButton(
                    "rectangle.on.rectangle",
                    active: model.callSnapshot?.localScreenShare != nil,
                    help: "Share screen"
                ) {
                    if model.callSnapshot?.localScreenShare == nil {
                        model.startScreenShare()
                    } else {
                        model.stopScreenShare()
                    }
                }
            }
        }
        .padding(12)
        .background(NoctCordTheme.success.opacity(0.055))
    }

    private var connectionLabel: String {
        let peers = max(0, (model.callSnapshot?.participants.count ?? 1) - 1)
        return peers == 1 ? "1 peer connected" : "\(peers) peers connected"
    }

    private func callButton(
        _ symbol: String,
        active: Bool,
        help: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(active ? .white : NoctCordTheme.secondaryText)
                .frame(maxWidth: .infinity)
                .frame(height: 30)
                .background(
                    active ? NoctCordTheme.mutedCoral : NoctCordTheme.input,
                    in: RoundedRectangle(cornerRadius: 9)
                )
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

private struct VoiceRoomRow: View {
    let room: NoctCordVoiceRoom
    let isActive: Bool
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: isActive ? "waveform.circle.fill" : "waveform")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(isActive ? NoctCordTheme.success : NoctCordTheme.secondaryText)
                Text(room.name)
                    .font(.system(size: 13, weight: isActive ? .semibold : .regular))
                Spacer()
                if room.participantCount > 0 {
                    Label("\(room.participantCount)", systemImage: "person.2.fill")
                        .labelStyle(.titleAndIcon)
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(NoctCordTheme.secondaryText)
                }
            }
            .foregroundStyle(NoctCordTheme.primaryText)
            .padding(.horizontal, 10)
            .frame(height: 34)
            .background(
                isActive
                    ? NoctCordTheme.success.opacity(0.12)
                    : isHovered ? NoctCordTheme.surface.opacity(0.82) : Color.clear,
                in: RoundedRectangle(cornerRadius: 10, style: .continuous)
            )
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .noctCordOnHover { isHovered = $0 }
    }
}

struct NoctCordConversationHeader: View {
    @ObservedObject var model: NoctCordAppModel
    let compact: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "number")
                .font(.system(size: 17, weight: .bold))
                .foregroundStyle(NoctCordTheme.mutedCoral)
            VStack(alignment: .leading, spacing: 2) {
                Text(model.selectedChannel?.name ?? "Select a channel")
                    .font(.system(size: 16, weight: .bold, design: .rounded))
                    .foregroundStyle(NoctCordTheme.primaryText)
                if !compact {
                    Text("Encrypted community channel")
                        .font(.system(size: 10))
                        .foregroundStyle(NoctCordTheme.secondaryText)
                }
            }
            Spacer(minLength: 8)

            if !compact {
                HStack(spacing: 7) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 11, weight: .medium))
                    TextField("Search", text: $model.searchQuery)
                        .textFieldStyle(.plain)
                        .font(.system(size: 11))
                }
                .foregroundStyle(NoctCordTheme.secondaryText)
                .padding(.horizontal, 11)
                .frame(width: 176, height: 32)
                .background(NoctCordTheme.input, in: Capsule())
                .overlay { Capsule().stroke(NoctCordTheme.border, lineWidth: 1) }
            }

            if !compact {
                HeaderIconButton(
                    symbol: model.showsMemberInspector ? "person.2.fill" : "person.2",
                    help: "Toggle member list",
                    isActive: model.showsMemberInspector
                ) {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        model.showsMemberInspector.toggle()
                    }
                }
            }
        }
        .padding(.horizontal, 22)
        .padding(.bottom, 13)
        .frame(height: NoctCordTheme.headerHeight, alignment: .bottom)
        .background(NoctCordTheme.surface.opacity(0.88))
        .overlay(alignment: .bottom) {
            Rectangle().fill(NoctCordTheme.border).frame(height: 1)
        }
    }
}

struct NoctCordRemoteScreenShareStage: View {
    @ObservedObject var model: NoctCordAppModel

    private var tracks: [(NoctCordMediaParticipantID, NoctCordMediaRemoteVideoTrack)] {
        (model.callSnapshot?.remoteVideoTracks ?? [:])
            .sorted { $0.key.rawValue < $1.key.rawValue }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "rectangle.on.rectangle.angled")
                    .foregroundStyle(NoctCordTheme.mutedCoral)
                Text(tracks.count == 1 ? "Screen share" : "Screen shares")
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                Text("End-to-end call media")
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundStyle(NoctCordTheme.secondaryText)
            }

            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 260), spacing: 10)],
                spacing: 10
            ) {
                ForEach(tracks, id: \.0) { participant, track in
                    ZStack(alignment: .bottomLeading) {
                        NoctCordMediaRemoteVideoView(
                            track: track,
                            contentMode: .aspectFit
                        )
                        .aspectRatio(16 / 9, contentMode: .fit)

                        Text(displayName(for: participant))
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 9)
                            .frame(height: 25)
                            .background(.black.opacity(0.62), in: Capsule())
                            .padding(9)
                    }
                    .background(.black)
                    .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 13, style: .continuous)
                            .stroke(NoctCordTheme.border, lineWidth: 1)
                    }
                }
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .background(NoctCordTheme.surface.opacity(0.94))
        .overlay(alignment: .bottom) {
            Rectangle().fill(NoctCordTheme.border).frame(height: 1)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Remote screen sharing")
    }

    private func displayName(for participant: NoctCordMediaParticipantID) -> String {
        if let member = model.selectedSpace?.members.first(where: {
            $0.id.rawValue == participant.rawValue
        }) {
            return member.displayName
        }
        return "Participant \(participant.rawValue.prefix(8))"
    }
}

private struct HeaderIconButton: View {
    let symbol: String
    let help: String
    let isActive: Bool
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(isActive ? NoctCordTheme.mutedCoral : NoctCordTheme.secondaryText)
                .frame(width: 34, height: 34)
                .background(
                    isActive
                        ? NoctCordTheme.mutedCoral.opacity(0.12)
                        : isHovered ? NoctCordTheme.input : Color.clear,
                    in: Circle()
                )
        }
        .buttonStyle(.plain)
        .noctCordOnHover { isHovered = $0 }
        .help(help)
    }
}

struct NoctCordMessageTimeline: View {
    @ObservedObject var model: NoctCordAppModel

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                LazyVStack(alignment: .leading, spacing: 3) {
                    channelIntroduction
                    ForEach(model.selectedMessages) { message in
                        MessageRow(
                            message: message,
                            isCurrentUser: message.authorID == model.selectedSpace?.currentMember
                        ) { reaction in
                            model.toggleReaction(reaction, messageID: message.id)
                        }
                        .id(message.id)
                    }
                    ForEach(model.selectedAttachments) { attachment in
                        AttachmentRow(
                            attachment: attachment,
                            cached: model.cachedAttachments[attachment.id]
                        ) {
                            if attachment.isAvailableLocally {
                                model.selectedAttachmentID = attachment.id
                            } else {
                                model.downloadAttachment(attachment.id)
                            }
                        }
                        .id(attachment.id)
                    }
                }
                .padding(.horizontal, 24)
                .padding(.top, 24)
                .padding(.bottom, 18)
            }
            .onChange(of: model.selectedMessages.count) { _, _ in
                if let last = model.selectedMessages.last?.id {
                    withAnimation(.easeOut(duration: 0.2)) {
                        proxy.scrollTo(last, anchor: .bottom)
                    }
                }
            }
            .onChange(of: model.selectedChannelID) { _, _ in
                if let last = model.selectedMessages.last?.id {
                    proxy.scrollTo(last, anchor: .bottom)
                }
            }
        }
        .background {
            LinearGradient(
                colors: [
                    NoctCordTheme.canvas,
                    NoctCordTheme.mutedCoral.opacity(0.025),
                    NoctCordTheme.canvas,
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
    }

    private var channelIntroduction: some View {
        VStack(alignment: .leading, spacing: 7) {
            Image(systemName: "number")
                .font(.system(size: 21, weight: .bold))
                .foregroundStyle(NoctCordTheme.mutedCoral)
                .frame(width: 46, height: 46)
                .background(NoctCordTheme.mutedCoral.opacity(0.12), in: RoundedRectangle(cornerRadius: 14))
            Text(model.selectedChannel?.name ?? "Channel")
                .font(.system(size: 24, weight: .bold, design: .rounded))
                .foregroundStyle(NoctCordTheme.primaryText)
            Text("This is the beginning of the encrypted channel history.")
                .font(.system(size: 12))
                .foregroundStyle(NoctCordTheme.secondaryText)
        }
        .padding(.bottom, 18)
    }
}

private struct MessageRow: View {
    let message: NoctCordMessagePresentation
    let isCurrentUser: Bool
    let onReaction: (String) -> Void
    @State private var isHovered = false

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            MemberMonogram(
                initials: message.authorInitials,
                presence: .active,
                size: 36,
                accent: isCurrentUser
            )

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 7) {
                    Text(message.authorName)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(
                            isCurrentUser ? NoctCordTheme.mutedCoral : NoctCordTheme.primaryText
                        )
                    Text(message.createdAt, style: .time)
                        .font(.system(size: 9))
                        .foregroundStyle(NoctCordTheme.secondaryText.opacity(0.78))
                    if message.editedAt != nil {
                        Text("edited")
                            .font(.system(size: 9))
                            .foregroundStyle(NoctCordTheme.secondaryText.opacity(0.72))
                    }
                    if message.isPinned {
                        Image(systemName: "pin.fill")
                            .font(.system(size: 9))
                            .foregroundStyle(NoctCordTheme.mutedCoral)
                    }
                }

                Text(message.isRetracted ? "Message retracted" : message.text)
                    .font(.system(size: 14))
                    .italic(message.isRetracted)
                    .foregroundStyle(
                        message.isRetracted
                            ? NoctCordTheme.secondaryText
                            : NoctCordTheme.primaryText.opacity(0.94)
                    )
                    .lineSpacing(3)
                    .textSelection(.enabled)

                if !message.reactions.isEmpty {
                    HStack(spacing: 6) {
                        ForEach(Array(message.reactions.enumerated()), id: \.offset) { _, reaction in
                            Button {
                                onReaction(reaction.value)
                            } label: {
                                HStack(spacing: 4) {
                                    Text(reaction.value)
                                    Text("\(reaction.count)")
                                        .font(.system(size: 9, weight: .semibold))
                                }
                                .font(.system(size: 11))
                                .padding(.horizontal, 8)
                                .frame(height: 25)
                                .background(
                                    reaction.selected
                                        ? NoctCordTheme.mutedCoral.opacity(0.16)
                                        : NoctCordTheme.input,
                                    in: Capsule()
                                )
                                .overlay {
                                    Capsule().stroke(
                                        reaction.selected
                                            ? NoctCordTheme.mutedCoral.opacity(0.45)
                                            : NoctCordTheme.border,
                                        lineWidth: 1
                                    )
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }

            Spacer(minLength: 8)

            if isHovered && !message.isRetracted {
                Button {
                    onReaction("✓")
                } label: {
                    Image(systemName: "checkmark.circle")
                        .font(.system(size: 12, weight: .semibold))
                        .frame(width: 28, height: 28)
                        .background(NoctCordTheme.elevated, in: Circle())
                        .overlay { Circle().stroke(NoctCordTheme.border, lineWidth: 1) }
                }
                .buttonStyle(.plain)
                .foregroundStyle(NoctCordTheme.secondaryText)
                .help("Acknowledge")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .background(
            isHovered ? NoctCordTheme.surface.opacity(0.58) : Color.clear,
            in: RoundedRectangle(cornerRadius: 13, style: .continuous)
        )
        .contentShape(Rectangle())
        .noctCordOnHover { isHovered = $0 }
    }
}

struct NoctCordComposer: View {
    @ObservedObject var model: NoctCordAppModel
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            if shouldSuggestCommands {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 7) {
                        ForEach(model.availableBotCommands, id: \.command.name) { item in
                            Button {
                                model.composerText = "/\(item.command.name) "
                                model.clearComposerNotice()
                                isFocused = true
                            } label: {
                                HStack(spacing: 6) {
                                    Text("/\(item.command.name)")
                                        .fontWeight(.semibold)
                                    Text(item.command.summary)
                                        .foregroundStyle(NoctCordTheme.secondaryText)
                                        .lineLimit(1)
                                }
                                .font(.system(size: 10.5))
                                .padding(.horizontal, 10)
                                .frame(height: 29)
                                .background(NoctCordTheme.elevated, in: Capsule())
                                .overlay { Capsule().stroke(NoctCordTheme.border) }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }

            if let notice = model.composerNotice {
                Label(notice, systemImage: "exclamationmark.circle.fill")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(NoctCordTheme.warning)
            }

            HStack(alignment: .bottom, spacing: 10) {
                Button {
                    model.showsAttachmentImporter = true
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(NoctCordTheme.secondaryText)
                        .frame(width: 32, height: 32)
                        .background(NoctCordTheme.surface, in: Circle())
                        .overlay { Circle().stroke(NoctCordTheme.border) }
                }
                .buttonStyle(.plain)
                .disabled(!model.canAttachInSelectedChannel)
                .opacity(model.canAttachInSelectedChannel ? 1 : 0.42)
                .help("Upload a sanitized, encrypted attachment")

                TextField(
                    model.canSendInSelectedChannel
                        ? "Message #\(model.selectedChannel?.name ?? "channel")"
                        : "Read-only channel",
                    text: $model.composerText,
                    axis: .vertical
                )
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .lineLimit(1...4)
                .autocorrectionDisabled(model.privacySettings.secureTypingEnabled)
                .focused($isFocused)
                .disabled(!model.canSendInSelectedChannel)
                .onSubmit { model.sendCurrentMessage() }
                .onChange(of: model.composerText) { _, _ in
                    model.clearComposerNotice()
                }

                Image(systemName: "lock.fill")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(NoctCordTheme.secondaryText.opacity(0.72))
                    .frame(width: 24, height: 32)
                    .help("Compact end-to-end encrypted delivery")

                Button {
                    model.sendCurrentMessage()
                } label: {
                    Image(systemName: "paperplane.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 34, height: 34)
                        .background(
                            model.composerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                ? NoctCordTheme.secondaryText.opacity(0.34)
                                : NoctCordTheme.mutedCoral,
                            in: Circle()
                        )
                }
                .buttonStyle(.plain)
                .disabled(
                    !model.canSendInSelectedChannel
                        || model.composerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                )
                .keyboardShortcut(.return, modifiers: [])
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(NoctCordTheme.input, in: RoundedRectangle(cornerRadius: 17, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 17, style: .continuous)
                    .stroke(isFocused ? NoctCordTheme.mutedCoral.opacity(0.42) : NoctCordTheme.border, lineWidth: 1)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .frame(minHeight: NoctCordTheme.footerHeight)
        .background(NoctCordTheme.canvas)
    }

    private var shouldSuggestCommands: Bool {
        model.composerText.hasPrefix("/")
            && !model.availableBotCommands.isEmpty
            && !model.composerText.contains(" ")
    }
}

private struct AttachmentRow: View {
    let attachment: NoctCordAttachmentPresentation
    let cached: NoctCordDownloadedAttachment?
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                preview
                    .frame(width: 64, height: 52)
                    .background(NoctCordTheme.input, in: RoundedRectangle(cornerRadius: 11))
                    .clipShape(RoundedRectangle(cornerRadius: 11))
                VStack(alignment: .leading, spacing: 4) {
                    Text(typeLabel)
                        .font(.system(size: 12.5, weight: .semibold))
                    Text("\(ByteCountFormatter.string(fromByteCount: Int64(attachment.byteCount), countStyle: .file)) · encrypted")
                        .font(.system(size: 10.5))
                        .foregroundStyle(NoctCordTheme.secondaryText)
                    Text(attachment.isExpired ? "Relay copy expired" : "Available until \(attachment.expiresAt.formatted(date: .abbreviated, time: .shortened))")
                        .font(.system(size: 9.5))
                        .foregroundStyle(attachment.isExpired ? NoctCordTheme.warning : NoctCordTheme.secondaryText)
                }
                Spacer()
                Image(systemName: attachment.isAvailableLocally ? "eye" : "arrow.down.circle")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(NoctCordTheme.mutedCoral)
                    .frame(width: 34, height: 34)
                    .background(NoctCordTheme.mutedCoral.opacity(0.10), in: Circle())
            }
            .foregroundStyle(NoctCordTheme.primaryText)
            .padding(10)
            .frame(maxWidth: 430)
            .background(
                isHovered ? NoctCordTheme.elevated : NoctCordTheme.surface,
                in: RoundedRectangle(cornerRadius: 15)
            )
            .overlay { RoundedRectangle(cornerRadius: 15).stroke(NoctCordTheme.border) }
            .contentShape(RoundedRectangle(cornerRadius: 15))
        }
        .buttonStyle(.plain)
        .disabled(attachment.isExpired && !attachment.isAvailableLocally)
        .noctCordOnHover { isHovered = $0 }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private var preview: some View {
        if let cached, cached.mediaType.hasPrefix("image/") {
            #if os(macOS)
            if let image = NSImage(data: cached.bytes) {
                Image(nsImage: image).resizable().scaledToFill()
            } else {
                fallbackIcon
            }
            #elseif os(iOS)
            if let image = UIImage(data: cached.bytes) {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                fallbackIcon
            }
            #endif
        } else {
            fallbackIcon
        }
    }

    private var fallbackIcon: some View {
        Image(systemName: symbol)
            .font(.system(size: 20, weight: .medium))
            .foregroundStyle(NoctCordTheme.mutedCoral)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var typeLabel: String {
        if attachment.mediaType.hasPrefix("image/") { return "Image" }
        if attachment.mediaType.hasPrefix("video/") { return "Video" }
        if attachment.mediaType.hasPrefix("audio/") { return "Audio" }
        if attachment.mediaType == "application/pdf" { return "PDF document" }
        return "Document"
    }

    private var symbol: String {
        if attachment.mediaType.hasPrefix("image/") { return "photo" }
        if attachment.mediaType.hasPrefix("video/") { return "film" }
        if attachment.mediaType.hasPrefix("audio/") { return "waveform" }
        if attachment.mediaType == "application/pdf" { return "doc.richtext" }
        return "doc"
    }
}

struct NoctCordAttachmentViewer: View {
    let attachment: NoctCordDownloadedAttachment?
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Encrypted attachment")
                        .font(.system(size: 15, weight: .bold, design: .rounded))
                    Text(attachment?.mediaType ?? "Unavailable")
                        .font(.system(size: 10))
                        .foregroundStyle(NoctCordTheme.secondaryText)
                }
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .bold))
                        .frame(width: 30, height: 30)
                        .background(NoctCordTheme.input, in: Circle())
                }
                .buttonStyle(.plain)
            }
            .padding(18)
            Divider().overlay(NoctCordTheme.border)

            Group {
                if let attachment {
                    attachmentContent(attachment)
                } else {
                    ContentUnavailableView(
                        "Attachment unavailable",
                        systemImage: "exclamationmark.triangle",
                        description: Text("Download the encrypted relay copy before opening it.")
                    )
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(18)
        }
        .frame(minWidth: 560, minHeight: 430)
        .background(NoctCordTheme.canvas)
        .foregroundStyle(NoctCordTheme.primaryText)
    }

    @ViewBuilder
    private func attachmentContent(_ attachment: NoctCordDownloadedAttachment) -> some View {
        if attachment.mediaType.hasPrefix("image/") {
            #if os(macOS)
            if let image = NSImage(data: attachment.bytes) {
                Image(nsImage: image).resizable().scaledToFit()
            } else {
                invalidContent
            }
            #elseif os(iOS)
            if let image = UIImage(data: attachment.bytes) {
                Image(uiImage: image).resizable().scaledToFit()
            } else {
                invalidContent
            }
            #endif
        } else if attachment.mediaType.hasPrefix("text/"),
                  let text = String(data: attachment.bytes, encoding: .utf8) {
            ScrollView {
                Text(text)
                    .font(.system(size: 12, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
            }
            .background(NoctCordTheme.input, in: RoundedRectangle(cornerRadius: 14))
        } else {
            VStack(spacing: 12) {
                Image(systemName: "doc.fill")
                    .font(.system(size: 42))
                    .foregroundStyle(NoctCordTheme.mutedCoral)
                Text("The file is authenticated and available in memory.")
                    .font(.system(size: 12, weight: .semibold))
                Text(ByteCountFormatter.string(
                    fromByteCount: Int64(attachment.bytes.count),
                    countStyle: .file
                ))
                .font(.system(size: 10.5))
                .foregroundStyle(NoctCordTheme.secondaryText)
            }
        }
    }

    private var invalidContent: some View {
        ContentUnavailableView(
            "Cannot render attachment",
            systemImage: "doc.badge.ellipsis",
            description: Text("The authenticated bytes could not be rendered by this platform.")
        )
    }
}

struct NoctCordMemberInspector: View {
    @ObservedObject var model: NoctCordAppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let space = model.selectedSpace {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Members")
                            .font(.system(size: 16, weight: .bold, design: .rounded))
                            .foregroundStyle(NoctCordTheme.primaryText)
                        Text("\(space.members.count) in this space")
                            .font(.system(size: 10))
                            .foregroundStyle(NoctCordTheme.secondaryText)
                    }
                    Spacer()
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            model.showsMemberInspector = false
                        }
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 10, weight: .bold))
                            .frame(width: 26, height: 26)
                            .background(NoctCordTheme.input, in: Circle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(NoctCordTheme.secondaryText)
                }
                .padding(.horizontal, 17)
                .padding(.bottom, 16)
                .frame(height: NoctCordTheme.headerHeight, alignment: .bottom)

                Divider().overlay(NoctCordTheme.border)

                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 20) {
                        memberSection("Active", members: space.members.filter { $0.presence == .active })
                        memberSection("Away", members: space.members.filter { $0.presence == .away })
                        memberSection("Offline", members: space.members.filter { $0.presence == .offline })
                    }
                    .padding(14)
                }
            }
        }
        .frame(width: 232)
        .background(NoctCordTheme.navigation)
        .overlay(alignment: .leading) {
            Rectangle().fill(NoctCordTheme.border).frame(width: 1)
        }
    }

    @ViewBuilder
    private func memberSection(_ title: String, members: [NoctCordMemberViewState]) -> some View {
        if !members.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text(title.uppercased())
                    .font(.system(size: 9, weight: .bold))
                    .tracking(0.8)
                    .foregroundStyle(NoctCordTheme.secondaryText)
                    .padding(.horizontal, 5)
                ForEach(members) { member in
                    HStack(spacing: 9) {
                        MemberMonogram(
                            initials: member.initials,
                            presence: member.presence,
                            size: 32
                        )
                        VStack(alignment: .leading, spacing: 2) {
                            Text(member.displayName)
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(
                                    member.presence == .offline
                                        ? NoctCordTheme.secondaryText
                                        : NoctCordTheme.primaryText
                                )
                            Text(member.roleName)
                                .font(.system(size: 9.5))
                                .foregroundStyle(NoctCordTheme.secondaryText)
                        }
                        if member.isBot {
                            Text("APP")
                                .font(.system(size: 7.5, weight: .bold))
                                .tracking(0.5)
                                .foregroundStyle(NoctCordTheme.warmIvory)
                                .padding(.horizontal, 6)
                                .frame(height: 17)
                                .background(NoctCordTheme.mutedCoral, in: Capsule())
                        }
                        Spacer()
                    }
                    .padding(.horizontal, 6)
                    .frame(height: 42)
                }
            }
        }
    }
}

struct MemberMonogram: View {
    let initials: String
    let presence: NoctCordPresence
    let size: CGFloat
    var accent = false

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            Text(initials)
                .font(.system(size: size * 0.30, weight: .bold, design: .rounded))
                .foregroundStyle(accent ? NoctCordTheme.warmIvory : NoctCordTheme.primaryText)
                .frame(width: size, height: size)
                .background(
                    accent
                        ? AnyShapeStyle(
                            LinearGradient(
                                colors: [NoctCordTheme.mutedCoral, NoctCordTheme.deepWine],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        : AnyShapeStyle(NoctCordTheme.input),
                    in: RoundedRectangle(cornerRadius: size * 0.34, style: .continuous)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: size * 0.34, style: .continuous)
                        .stroke(NoctCordTheme.border, lineWidth: 1)
                }

            Circle()
                .fill(presenceColor)
                .frame(width: size * 0.25, height: size * 0.25)
                .overlay { Circle().stroke(NoctCordTheme.navigation, lineWidth: 2) }
                .offset(x: 1, y: 1)
        }
    }

    private var presenceColor: Color {
        switch presence {
        case .active: NoctCordTheme.success
        case .away: NoctCordTheme.warning
        case .offline: NoctCordTheme.secondaryText.opacity(0.45)
        }
    }
}

extension View {
    @ViewBuilder
    func noctCordOnHover(_ action: @escaping (Bool) -> Void) -> some View {
        #if os(macOS)
        self.onHover(perform: action)
        #else
        self
        #endif
    }
}
