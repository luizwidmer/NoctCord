import SwiftUI
import NoctCordCore
@preconcurrency import NoctweaveCore

struct NoctCordCommunitySettingsSheet: View {
    @ObservedObject var model: NoctCordAppModel
    @Environment(\.dismiss) private var dismiss
    @State private var section: Section = .overview

    private enum Section: String, CaseIterable, Identifiable {
        case overview = "Overview"
        case roles = "Roles"
        case channels = "Channel access"
        case applications = "Apps & bots"

        var id: String { rawValue }

        var symbol: String {
            switch self {
            case .overview: "rectangle.3.group.fill"
            case .roles: "person.3.sequence.fill"
            case .channels: "number.square.fill"
            case .applications: "puzzlepiece.extension.fill"
            }
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 7) {
                Label("Community", systemImage: "slider.horizontal.3")
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                    .padding(.horizontal, 12)
                    .padding(.bottom, 10)

                ForEach(Section.allCases) { item in
                    Button {
                        section = item
                    } label: {
                        Label(item.rawValue, systemImage: item.symbol)
                            .font(.system(size: 11.5, weight: .semibold))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 11)
                            .frame(height: 38)
                            .background(
                                section == item
                                    ? NoctCordTheme.mutedCoral.opacity(0.16)
                                    : Color.clear,
                                in: RoundedRectangle(cornerRadius: 11, style: .continuous)
                            )
                            .contentShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(
                        section == item
                            ? NoctCordTheme.primaryText
                            : NoctCordTheme.secondaryText
                    )
                }

                Spacer()
            }
            .padding(14)
            .frame(width: 176)
            .background(NoctCordTheme.navigation)

            Rectangle()
                .fill(NoctCordTheme.border)
                .frame(width: 1)

            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    Image(systemName: section.symbol)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(NoctCordTheme.mutedCoral)
                        .frame(width: 38, height: 38)
                        .background(
                            NoctCordTheme.mutedCoral.opacity(0.11),
                            in: RoundedRectangle(cornerRadius: 12)
                        )
                    VStack(alignment: .leading, spacing: 2) {
                        Text(section.rawValue)
                            .font(.system(size: 18, weight: .bold, design: .rounded))
                        Text(sectionSubtitle)
                            .font(.system(size: 10.5))
                            .foregroundStyle(NoctCordTheme.secondaryText)
                    }
                    Spacer()
                    Button("Done") { dismiss() }
                        .buttonStyle(NoctCordPrimaryButtonStyle())
                }
                .padding(20)

                Rectangle()
                    .fill(NoctCordTheme.border)
                    .frame(height: 1)

                ScrollView {
                    sectionContent
                        .padding(20)
                }
            }
        }
        .foregroundStyle(NoctCordTheme.primaryText)
        .background(NoctCordTheme.canvas)
        #if os(macOS)
        .frame(width: 780, height: 620)
        #else
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        #endif
    }

    private var sectionSubtitle: String {
        switch section {
        case .overview: "Community identity, relay, and encrypted delivery context."
        case .roles: "Create a hierarchy and assign community-wide capabilities."
        case .channels: "Override role permissions for a specific channel."
        case .applications: "Manage encrypted bot principals and slash commands."
        }
    }

    @ViewBuilder
    private var sectionContent: some View {
        switch section {
        case .overview:
            CommunityOverviewSettings(model: model)
        case .roles:
            CommunityRoleSettings(model: model)
        case .channels:
            CommunityChannelAccessSettings(model: model)
        case .applications:
            CommunityApplicationSettings(model: model)
        }
    }
}

private struct CommunityOverviewSettings: View {
    @ObservedObject var model: NoctCordAppModel
    @Environment(\.dismiss) private var dismiss
    @State private var lifecycleAlert: CommunityLifecycleAlert?

    private enum CommunityLifecycleAlert: Identifiable {
        case confirmLeave
        case confirmDestroy
        case failure(String)

        var id: String {
            switch self {
            case .confirmLeave: "confirm-leave"
            case .confirmDestroy: "confirm-destroy"
            case .failure(let message): "failure-\(message)"
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let space = model.selectedSpace {
                VStack(alignment: .leading, spacing: 14) {
                    Text(space.name)
                        .font(.system(size: 22, weight: .bold, design: .rounded))
                    settingsRow(
                        symbol: "network",
                        title: "Community relay",
                        value: space.relayName
                    )
                    settingsRow(
                        symbol: "lock.shield.fill",
                        title: "Delivery",
                        value: "End-to-end encrypted"
                    )
                    settingsRow(
                        symbol: "person.crop.circle",
                        title: "Your membership",
                        value: space.identityScope == .portable
                            ? "Portable profile"
                            : "Isolated profile"
                    )
                }
                .padding(18)
                .background(NoctCordTheme.surface, in: RoundedRectangle(cornerRadius: 17))
                .overlay {
                    RoundedRectangle(cornerRadius: 17).stroke(NoctCordTheme.border)
                }
            }

            NoctCordSettingsNotice(
                symbol: "person.crop.circle.badge.checkmark",
                text: "Your display name, identity correlation, privacy protections, relays, and appearance are managed from your profile menu at the bottom of the channel sidebar.",
                color: NoctCordTheme.mutedCoral
            )

            if let space = model.selectedSpace {
                communityLifecycleCard(space)
            }
        }
        .alert(item: $lifecycleAlert) { alert in
            lifecycleAlert(for: alert)
        }
    }

    private func communityLifecycleCard(_ space: NoctCordSpaceSession) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: space.isCurrentUserOwner ? "trash.slash.fill" : "rectangle.portrait.and.arrow.right")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(NoctCordTheme.mutedCoral)
                .frame(width: 38, height: 38)
                .background(
                    NoctCordTheme.mutedCoral.opacity(0.12),
                    in: RoundedRectangle(cornerRadius: 11)
                )

            VStack(alignment: .leading, spacing: 6) {
                Text(space.isCurrentUserOwner ? "Destroy community" : "Leave community")
                    .font(.system(size: 13, weight: .bold))
                Text(space.isCurrentUserOwner
                    ? "Permanently close this encrypted community for every member. Relay-retained ciphertext remains subject to the relay operator's retention policy."
                    : "Remove this membership and stop receiving new community traffic. A new invitation is required to return."
                )
                .font(.system(size: 10.5))
                .foregroundStyle(NoctCordTheme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 12)

            if model.isSelectedCommunityLifecycleOperationInFlight {
                ProgressView()
                    .controlSize(.small)
                    .frame(width: 116, height: 34)
            } else {
                Button(role: .destructive) {
                    lifecycleAlert = space.isCurrentUserOwner
                        ? .confirmDestroy
                        : .confirmLeave
                } label: {
                    Text(space.isCurrentUserOwner ? "Destroy…" : "Leave…")
                        .font(.system(size: 11.5, weight: .bold))
                        .frame(minWidth: 86)
                }
                .buttonStyle(.borderedProminent)
                .tint(NoctCordTheme.deepWine)
            }
        }
        .padding(16)
        .background(NoctCordTheme.surface, in: RoundedRectangle(cornerRadius: 16))
        .overlay {
            RoundedRectangle(cornerRadius: 16)
                .stroke(NoctCordTheme.mutedCoral.opacity(0.42))
        }
    }

    private func lifecycleAlert(for alert: CommunityLifecycleAlert) -> Alert {
        let name = model.selectedSpace?.name ?? "this community"
        switch alert {
        case .confirmLeave:
            return Alert(
                title: Text("Leave \(name)?"),
                message: Text("Your membership credential will be removed in a signed epoch update. This device keeps a protected terminal record to reject replays, and you will need a new invitation to return."),
                primaryButton: .destructive(Text("Leave Community")) {
                    Task { await performLifecycleAction(.leave) }
                },
                secondaryButton: .cancel()
            )
        case .confirmDestroy:
            return Alert(
                title: Text("Destroy \(name) for everyone?"),
                message: Text("Only the owner can do this. A signed terminal tombstone will close the community for every current member. It cannot accept new messages or be restored."),
                primaryButton: .destructive(Text("Destroy Community")) {
                    Task { await performLifecycleAction(.destroy) }
                },
                secondaryButton: .cancel()
            )
        case .failure(let message):
            return Alert(
                title: Text("Action Couldn’t Be Completed"),
                message: Text(message),
                dismissButton: .default(Text("OK"))
            )
        }
    }

    private func performLifecycleAction(_ action: NoctCordCommunityLifecycleAction) async {
        do {
            switch action {
            case .leave:
                try await model.leaveSelectedCommunity()
            case .destroy:
                try await model.destroySelectedCommunity()
            }
            dismiss()
        } catch {
            lifecycleAlert = .failure(error.localizedDescription)
        }
    }

    private func settingsRow(symbol: String, title: String, value: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .foregroundStyle(NoctCordTheme.mutedCoral)
                .frame(width: 24)
            Text(title)
                .font(.system(size: 12, weight: .semibold))
            Spacer()
            Text(value)
                .font(.system(size: 11))
                .foregroundStyle(NoctCordTheme.secondaryText)
        }
    }
}

private struct CommunityRoleSettings: View {
    @ObservedObject var model: NoctCordAppModel
    @State private var editingRoleID: UUID?
    @State private var roleName = ""
    @State private var rolePosition = 10
    @State private var rolePermissions: Set<NoctCordPermission> = []

    private var roles: [NoctCordRole] {
        model.selectedSpace?.projection.roles.values.sorted {
            if $0.position != $1.position { return $0.position > $1.position }
            return $0.name < $1.name
        } ?? []
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if model.selectedSpace?.canManageRoles != true {
                NoctCordSettingsNotice(
                    symbol: "lock.fill",
                    text: "You can inspect roles, but only a member with Manage Roles may change them.",
                    color: NoctCordTheme.warning
                )
            }

            ForEach(roles) { role in
                roleCard(role)
            }

            NoctCordSettingsCard {
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        Label(
                            editingRoleID == nil ? "Create role" : "Edit role",
                            systemImage: "person.badge.shield.checkmark.fill"
                        )
                        .font(.system(size: 13, weight: .bold))
                        Spacer()
                        if editingRoleID != nil {
                            Button("Cancel") { resetEditor() }
                                .buttonStyle(.plain)
                                .foregroundStyle(NoctCordTheme.secondaryText)
                        }
                    }

                    TextField("Role name", text: $roleName)
                        .noctCordSettingsInput()

                    Stepper("Hierarchy position: \(rolePosition)", value: $rolePosition, in: 1...1_000)
                        .font(.system(size: 11.5, weight: .medium))

                    PermissionToggleGrid(selection: $rolePermissions)

                    HStack {
                        Spacer()
                        Button(editingRoleID == nil ? "Create role" : "Save role") {
                            model.saveRole(
                                id: editingRoleID ?? UUID(),
                                name: roleName,
                                position: UInt16(rolePosition),
                                permissions: rolePermissions
                            )
                            resetEditor()
                        }
                        .buttonStyle(NoctCordPrimaryButtonStyle())
                        .disabled(
                            model.selectedSpace?.canManageRoles != true
                                || roleName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        )
                    }
                }
            }
        }
    }

    private func roleCard(_ role: NoctCordRole) -> some View {
        NoctCordSettingsCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(role.name)
                            .font(.system(size: 13, weight: .bold))
                        Text("Position \(role.position) · \(role.permissions.count) permissions")
                            .font(.system(size: 10))
                            .foregroundStyle(NoctCordTheme.secondaryText)
                    }
                    Spacer()
                    Button("Edit") {
                        editingRoleID = role.id
                        roleName = role.name
                        rolePosition = Int(role.position)
                        rolePermissions = Set(role.permissions)
                    }
                    .buttonStyle(NoctCordSecondaryButtonStyle())
                    Button(role: .destructive) {
                        model.deleteRole(role.id)
                    } label: {
                        Image(systemName: "trash")
                            .frame(width: 34, height: 34)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(NoctCordTheme.mutedCoral)
                    .disabled(model.selectedSpace?.canManageRoles != true)
                }

                FlowLayout(spacing: 6) {
                    ForEach(role.permissions, id: \.self) { permission in
                        Text(permission.title)
                            .font(.system(size: 9.5, weight: .medium))
                            .padding(.horizontal, 8)
                            .frame(height: 23)
                            .background(NoctCordTheme.input, in: Capsule())
                    }
                }

                if let space = model.selectedSpace {
                    VStack(alignment: .leading, spacing: 7) {
                        Text("MEMBERS")
                            .font(.system(size: 9, weight: .bold))
                            .tracking(0.8)
                            .foregroundStyle(NoctCordTheme.secondaryText)
                        ForEach(space.members.filter { !$0.isBot }) { member in
                            let isAssigned = space.projection.roleAssignments[member.id, default: []]
                                .contains(role.id)
                            Toggle(isOn: Binding(
                                get: { isAssigned },
                                set: { model.setRole(role.id, for: member.id, assigned: $0) }
                            )) {
                                Text(member.displayName)
                                    .font(.system(size: 11.5, weight: .medium))
                            }
                            .disabled(
                                model.selectedSpace?.canManageRoles != true
                                    || member.id == space.projection.owner
                            )
                        }
                    }
                }
            }
        }
    }

    private func resetEditor() {
        editingRoleID = nil
        roleName = ""
        rolePosition = 10
        rolePermissions = []
    }
}

private struct CommunityChannelAccessSettings: View {
    @ObservedObject var model: NoctCordAppModel
    @State private var channelID: UUID?
    @State private var roleID: UUID?
    @State private var allow: Set<NoctCordPermission> = []
    @State private var deny: Set<NoctCordPermission> = []

    private var allChannels: [NoctCordChannel] {
        model.selectedSpace?.projection.channels.values
            .filter { !$0.isArchived }
            .sorted { $0.name < $1.name } ?? []
    }

    private var roles: [NoctCordRole] {
        model.selectedSpace?.projection.roles.values
            .sorted { $0.position > $1.position } ?? []
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            NoctCordSettingsNotice(
                symbol: "lock.open.trianglebadge.exclamationmark",
                text: "Channel visibility is an authenticated client policy inside one encrypted community. It blocks compliant clients from rendering or publishing, but it is not a separate cryptographic subgroup.",
                color: NoctCordTheme.warning
            )

            NoctCordSettingsCard {
                VStack(alignment: .leading, spacing: 14) {
                    Picker("Channel", selection: $channelID) {
                        Text("Choose a channel").tag(UUID?.none)
                        ForEach(allChannels) { channel in
                            Text("# \(channel.name)").tag(Optional(channel.id))
                        }
                    }

                    Picker("Applies to", selection: $roleID) {
                        Text("Everyone").tag(UUID?.none)
                        ForEach(roles) { role in
                            Text(role.name).tag(Optional(role.id))
                        }
                    }

                    VStack(spacing: 7) {
                        ForEach(
                            NoctCordPermission.channelScoped.sorted { $0.rawValue < $1.rawValue },
                            id: \.self
                        ) { permission in
                            PermissionDecisionRow(
                                permission: permission,
                                decision: Binding(
                                    get: { decision(for: permission) },
                                    set: { setDecision($0, for: permission) }
                                )
                            )
                        }
                    }

                    HStack {
                        Button("Clear override") {
                            guard let channelID else { return }
                            model.clearChannelPermissions(channelID: channelID, roleID: roleID)
                            allow = []
                            deny = []
                        }
                        .buttonStyle(NoctCordSecondaryButtonStyle())
                        .disabled(
                            model.selectedSpace?.canManageChannels != true
                                || currentOverride == nil
                        )
                        Spacer()
                        Button("Apply access") {
                            guard let channelID else { return }
                            model.setChannelPermissions(
                                channelID: channelID,
                                roleID: roleID,
                                allow: allow,
                                deny: deny
                            )
                        }
                        .buttonStyle(NoctCordPrimaryButtonStyle())
                        .disabled(
                            model.selectedSpace?.canManageChannels != true
                                || channelID == nil
                                || (allow.isEmpty && deny.isEmpty)
                        )
                    }
                }
            }
        }
        .onAppear {
            channelID = channelID ?? model.selectedChannelID ?? allChannels.first?.id
            loadOverride()
        }
        .onChange(of: channelID) { _, _ in loadOverride() }
        .onChange(of: roleID) { _, _ in loadOverride() }
    }

    private var currentOverride: NoctCordChannelPermissionOverride? {
        guard let channelID,
              let channel = model.selectedSpace?.projection.channels[channelID] else { return nil }
        let target: NoctCordChannelPermissionTarget = roleID.map {
            .role($0)
        } ?? .everyone
        return channel.permissionOverrides[target]
    }

    private func loadOverride() {
        allow = Set(currentOverride?.allow ?? [])
        deny = Set(currentOverride?.deny ?? [])
    }

    private func decision(for permission: NoctCordPermission) -> PermissionDecision {
        if allow.contains(permission) { return .allow }
        if deny.contains(permission) { return .deny }
        return .inherit
    }

    private func setDecision(_ decision: PermissionDecision, for permission: NoctCordPermission) {
        allow.remove(permission)
        deny.remove(permission)
        switch decision {
        case .inherit: break
        case .allow: allow.insert(permission)
        case .deny: deny.insert(permission)
        }
    }
}

private struct CommunityApplicationSettings: View {
    @ObservedObject var model: NoctCordAppModel
    @State private var name = ""
    @State private var memberRawValue = ""
    @State private var commandLines = "status: Show current status"

    private var bots: [NoctCordBotApplication] {
        model.selectedSpace?.projection.botApplications.values
            .sorted { $0.name < $1.name } ?? []
    }

    private var availableMembers: [NoctCordMemberViewState] {
        guard let space = model.selectedSpace else { return [] }
        let used = Set(space.projection.botApplications.values.map(\.memberHandle))
        return space.members.filter {
            !used.contains($0.id)
                && $0.id != space.projection.owner
                && $0.id != space.currentMember
                && space.projection.roleAssignments[$0.id, default: []].isEmpty
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            NoctCordSettingsNotice(
                symbol: "shield.lefthalf.filled",
                text: "Apps are separately operated Noctweave group members. They decrypt only what that group member can access; no bot code, token, or message plaintext executes at the relay.",
                color: NoctCordTheme.success
            )

            ForEach(bots) { bot in
                NoctCordSettingsCard {
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: "puzzlepiece.extension.fill")
                            .foregroundStyle(NoctCordTheme.mutedCoral)
                            .frame(width: 38, height: 38)
                            .background(NoctCordTheme.input, in: RoundedRectangle(cornerRadius: 11))
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(spacing: 7) {
                                Text(bot.name)
                                    .font(.system(size: 13, weight: .bold))
                                Text("APP")
                                    .font(.system(size: 7.5, weight: .bold))
                                    .foregroundStyle(NoctCordTheme.warmIvory)
                                    .padding(.horizontal, 6)
                                    .frame(height: 17)
                                    .background(NoctCordTheme.mutedCoral, in: Capsule())
                            }
                            ForEach(bot.commands, id: \.name) { command in
                                Text("/\(command.name) — \(command.summary)")
                                    .font(.system(size: 10.5))
                                    .foregroundStyle(NoctCordTheme.secondaryText)
                            }
                            Text("Group principal \(bot.memberHandle.rawValue.prefix(12))…")
                                .font(.system(size: 9))
                                .foregroundStyle(NoctCordTheme.secondaryText.opacity(0.75))
                        }
                        Spacer()
                        Button(role: .destructive) {
                            model.removeBot(bot.id)
                        } label: {
                            Image(systemName: "trash")
                                .frame(width: 34, height: 34)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(NoctCordTheme.mutedCoral)
                        .disabled(model.selectedSpace?.canManageBots != true)
                    }
                }
            }

            NoctCordSettingsCard {
                VStack(alignment: .leading, spacing: 14) {
                    Label("Install application", systemImage: "plus.app.fill")
                        .font(.system(size: 13, weight: .bold))

                    TextField("Application name", text: $name)
                        .noctCordSettingsInput()

                    Picker("Dedicated group member", selection: $memberRawValue) {
                        Text("Choose an invited member").tag("")
                        ForEach(availableMembers) { member in
                            Text(member.displayName).tag(member.id.rawValue)
                        }
                    }

                    Text("Invite and operate a purpose-created bot identity first. The owner, your current identity, and already privileged members are excluded.")
                        .font(.system(size: 9.5))
                        .foregroundStyle(NoctCordTheme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)

                    VStack(alignment: .leading, spacing: 6) {
                        Text("COMMANDS")
                            .font(.system(size: 9, weight: .bold))
                            .tracking(0.8)
                            .foregroundStyle(NoctCordTheme.secondaryText)
                        TextEditor(text: $commandLines)
                            .font(.system(size: 11, design: .monospaced))
                            .scrollContentBackground(.hidden)
                            .padding(9)
                            .frame(height: 88)
                            .background(NoctCordTheme.input, in: RoundedRectangle(cornerRadius: 11))
                            .overlay { RoundedRectangle(cornerRadius: 11).stroke(NoctCordTheme.border) }
                        Text("One command per line: name: description")
                            .font(.system(size: 9.5))
                            .foregroundStyle(NoctCordTheme.secondaryText)
                    }

                    HStack {
                        Spacer()
                        Button("Install application") {
                            guard let member = availableMembers.first(where: {
                                $0.id.rawValue == memberRawValue
                            }) else { return }
                            model.installBot(
                                name: name,
                                member: member.id,
                                commands: parsedCommands
                            )
                            name = ""
                            memberRawValue = ""
                            commandLines = "status: Show current status"
                        }
                        .buttonStyle(NoctCordPrimaryButtonStyle())
                        .disabled(
                            model.selectedSpace?.canManageBots != true
                                || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                || memberRawValue.isEmpty
                                || parsedCommands.isEmpty
                        )
                    }
                }
            }
        }
    }

    private var parsedCommands: Set<NoctCordBotCommand> {
        Set(commandLines.split(whereSeparator: \.isNewline).compactMap { line in
            let pieces = line.split(separator: ":", maxSplits: 1)
            guard pieces.count == 2 else { return nil }
            let name = pieces[0]
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            let summary = pieces[1].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, !summary.isEmpty else { return nil }
            return NoctCordBotCommand(name: name, summary: summary)
        })
    }
}

private enum PermissionDecision: String, CaseIterable, Identifiable {
    case inherit = "Inherit"
    case allow = "Allow"
    case deny = "Deny"

    var id: String { rawValue }
}

private struct PermissionDecisionRow: View {
    let permission: NoctCordPermission
    @Binding var decision: PermissionDecision

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(permission.title)
                    .font(.system(size: 11.5, weight: .semibold))
                Text(permission.summary)
                    .font(.system(size: 9.5))
                    .foregroundStyle(NoctCordTheme.secondaryText)
            }
            Spacer()
            Picker(permission.title, selection: $decision) {
                ForEach(PermissionDecision.allCases) { value in
                    Text(value.rawValue).tag(value)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .frame(width: 210)
        }
        .padding(.horizontal, 12)
        .frame(minHeight: 48)
        .background(NoctCordTheme.input.opacity(0.62), in: RoundedRectangle(cornerRadius: 11))
    }
}

private struct PermissionToggleGrid: View {
    @Binding var selection: Set<NoctCordPermission>

    var body: some View {
        VStack(spacing: 6) {
            ForEach(NoctCordPermission.allCases, id: \.self) { permission in
                Toggle(isOn: Binding(
                    get: { selection.contains(permission) },
                    set: { enabled in
                        if enabled {
                            selection.insert(permission)
                        } else {
                            selection.remove(permission)
                        }
                    }
                )) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(permission.title)
                            .font(.system(size: 11.5, weight: .semibold))
                        Text(permission.summary)
                            .font(.system(size: 9.5))
                            .foregroundStyle(NoctCordTheme.secondaryText)
                    }
                }
                .padding(.horizontal, 11)
                .frame(minHeight: 43)
                .background(NoctCordTheme.input.opacity(0.55), in: RoundedRectangle(cornerRadius: 10))
            }
        }
    }
}

private struct NoctCordSettingsCard<Content: View>: View {
    @ViewBuilder let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content
            .padding(15)
            .background(NoctCordTheme.surface, in: RoundedRectangle(cornerRadius: 16))
            .overlay { RoundedRectangle(cornerRadius: 16).stroke(NoctCordTheme.border) }
    }
}

private struct NoctCordSettingsNotice: View {
    let symbol: String
    let text: String
    let color: Color

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: symbol)
                .foregroundStyle(color)
            Text(text)
                .font(.system(size: 10.5))
                .foregroundStyle(NoctCordTheme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
        }
        .padding(12)
        .background(color.opacity(0.09), in: RoundedRectangle(cornerRadius: 13))
    }
}

private struct FlowLayout<Content: View>: View {
    let spacing: CGFloat
    @ViewBuilder let content: Content

    init(spacing: CGFloat, @ViewBuilder content: () -> Content) {
        self.spacing = spacing
        self.content = content()
    }

    var body: some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 92), spacing: spacing)],
            alignment: .leading,
            spacing: spacing
        ) {
            content
        }
    }
}

private extension View {
    func noctCordSettingsInput() -> some View {
        self
            .textFieldStyle(.plain)
            .font(.system(size: 12.5, weight: .medium))
            .padding(.horizontal, 12)
            .frame(height: 40)
            .background(NoctCordTheme.input, in: RoundedRectangle(cornerRadius: 11))
            .overlay { RoundedRectangle(cornerRadius: 11).stroke(NoctCordTheme.border) }
    }
}

private extension NoctCordPermission {
    var title: String {
        switch self {
        case .readMessages: "View channel"
        case .sendMessages: "Send messages"
        case .manageMessages: "Manage messages"
        case .manageChannels: "Manage channels"
        case .manageRoles: "Manage roles"
        case .inviteMembers: "Invite members"
        case .manageSpace: "Administrator"
        case .attachFiles: "Attach files"
        case .addReactions: "Add reactions"
        case .connectVoice: "Join voice"
        case .speakVoice: "Speak and share"
        case .useApplicationCommands: "Use app commands"
        case .manageBots: "Manage apps"
        }
    }

    var summary: String {
        switch self {
        case .readMessages: "Render this channel and its history."
        case .sendMessages: "Publish new messages in visible channels."
        case .manageMessages: "Pin, retract, or moderate member messages."
        case .manageChannels: "Create, rename, archive, and configure channels."
        case .manageRoles: "Create lower roles and assign them to members."
        case .inviteMembers: "Invite another group-scoped identity."
        case .manageSpace: "Bypass permission checks and manage the community."
        case .attachFiles: "Publish sanitized encrypted attachments."
        case .addReactions: "Add or remove reactions on messages."
        case .connectVoice: "Join encrypted-signaling voice rooms."
        case .speakVoice: "Transmit media and start screen sharing."
        case .useApplicationCommands: "Invoke slash commands from installed apps."
        case .manageBots: "Install, update, and remove app principals."
        }
    }
}
