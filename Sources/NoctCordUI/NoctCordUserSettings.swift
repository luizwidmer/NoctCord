import SwiftUI
import NoctCordCore
@preconcurrency import NoctweaveCore

struct NoctCordUserSettingsSheet: View {
    @ObservedObject var model: NoctCordAppModel
    @Environment(\.dismiss) private var dismiss
    @State private var section: Section = .profile
    @State private var displayName = ""
    @State private var updateEveryCommunity = true

    private enum Section: String, CaseIterable, Identifiable {
        case profile = "Profile"
        case privacy = "Privacy"
        case relays = "Relays"
        case appearance = "Appearance"

        var id: String { rawValue }

        var symbol: String {
            switch self {
            case .profile: "person.crop.circle.fill"
            case .privacy: "hand.raised.fill"
            case .relays: "network"
            case .appearance: "paintbrush.fill"
            }
        }

        var subtitle: String {
            switch self {
            case .profile: "Your local name and this community's profile scope."
            case .privacy: "Device protections with explicit limits."
            case .relays: "Use different relays for different communities."
            case .appearance: "Choose how Noct Cord looks on this device."
            }
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Rectangle().fill(NoctCordTheme.border).frame(width: 1)
            VStack(spacing: 0) {
                header
                Rectangle().fill(NoctCordTheme.border).frame(height: 1)
                ScrollView {
                    sectionContent
                        .padding(20)
                        .frame(maxWidth: 680)
                        .frame(maxWidth: .infinity, alignment: .top)
                }
            }
        }
        .foregroundStyle(NoctCordTheme.primaryText)
        .background(NoctCordTheme.canvas)
        .onAppear {
            displayName = model.userDisplayName
        }
        #if os(macOS)
        .frame(width: 820, height: 640)
        #else
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        #endif
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 7) {
            Label("Your Noct Cord", systemImage: "person.crop.circle")
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
                }
                .buttonStyle(.plain)
                .foregroundStyle(
                    section == item
                        ? NoctCordTheme.primaryText
                        : NoctCordTheme.secondaryText
                )
            }
            Spacer()
            Text("No global Noct Cord account")
                .font(.system(size: 9.5, weight: .medium))
                .foregroundStyle(NoctCordTheme.secondaryText)
                .padding(.horizontal, 12)
        }
        .padding(14)
        .frame(width: 188)
        .background(NoctCordTheme.navigation)
    }

    private var header: some View {
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
                Text(section.subtitle)
                    .font(.system(size: 10.5))
                    .foregroundStyle(NoctCordTheme.secondaryText)
            }
            Spacer()
            Button("Done") { dismiss() }
                .buttonStyle(NoctCordPrimaryButtonStyle())
        }
        .padding(20)
    }

    @ViewBuilder
    private var sectionContent: some View {
        switch section {
        case .profile:
            profileSection
        case .privacy:
            privacySection
        case .relays:
            NoctCordRelaySettings(model: model)
        case .appearance:
            appearanceSection
        }
    }

    private var profileSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            settingsCard {
                VStack(alignment: .leading, spacing: 12) {
                    sectionLabel("DISPLAY NAME")
                    TextField("How you appear", text: $displayName)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13, weight: .medium))
                        .padding(.horizontal, 13)
                        .frame(height: 42)
                        .background(
                            NoctCordTheme.input,
                            in: RoundedRectangle(cornerRadius: 12)
                        )
                        .overlay {
                            RoundedRectangle(cornerRadius: 12).stroke(NoctCordTheme.border)
                        }

                    Toggle(
                        "Update my profile in every community on this device",
                        isOn: $updateEveryCommunity
                    )
                    .toggleStyle(.switch)
                    .font(.system(size: 11.5, weight: .medium))

                    HStack {
                        Text("The name is signed independently for each community. Matching text alone does not create a protocol account.")
                            .font(.system(size: 10.5))
                            .foregroundStyle(NoctCordTheme.secondaryText)
                        Spacer(minLength: 16)
                        Button("Save name") {
                            Task {
                                _ = await model.updateDisplayName(
                                    displayName,
                                    acrossAllCommunities: updateEveryCommunity
                                )
                            }
                        }
                        .buttonStyle(NoctCordPrimaryButtonStyle())
                        .disabled(
                            displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        )
                    }
                }
            }

            if model.selectedSpace != nil {
                VStack(alignment: .leading, spacing: 10) {
                    sectionLabel("PROFILE IN THIS COMMUNITY")
                    identityCard(
                        .isolated,
                        title: "Isolated profile",
                        description: "Use a fresh signing profile that is unique to this community.",
                        symbol: "eye.slash.fill"
                    )
                    identityCard(
                        .portable,
                        title: "Portable profile",
                        description: "Reuse one signing profile where you intentionally want memberships to be linkable.",
                        symbol: "link"
                    )
                }
            }

            if let notice = model.settingsNotice {
                NoctCordSettingsNotice(
                    symbol: "checkmark.circle.fill",
                    text: notice,
                    color: NoctCordTheme.mutedCoral
                )
            }
        }
    }

    private var privacySection: some View {
        VStack(alignment: .leading, spacing: 13) {
            NoctCordSettingsNotice(
                symbol: "hand.raised.fill",
                text: "These protections reduce accidental disclosure on this device. They cannot make a compromised operating system trustworthy or hide network metadata from a relay.",
                color: NoctCordTheme.mutedCoral
            )
            sectionLabel("ON-SCREEN CONTENT")
            privacyToggle(
                title: "Hide when unfocused",
                description: "Cover communities, identities, messages, and relay details when Noct Cord loses focus.",
                symbol: "eye.slash.fill",
                keyPath: \.hideSensitiveWhenUnfocused
            )
            #if os(macOS)
            privacyToggle(
                title: "Block window capture",
                description: "Ask WindowServer to exclude this window from standard capture APIs. Physical cameras and privileged software remain outside this boundary.",
                symbol: "rectangle.slash.fill",
                keyPath: \.macBlockWindowCapture
            )
            #endif
            sectionLabel("COMPOSER")
                .padding(.top, 4)
            privacyToggle(
                title: "Private typing assistance",
                description: "Disable autocorrection and predictive suggestions in message composers.",
                symbol: "keyboard.badge.ellipsis",
                keyPath: \.secureTypingEnabled
            )
            if let notice = model.settingsNotice {
                NoctCordSettingsNotice(
                    symbol: "info.circle.fill",
                    text: notice,
                    color: NoctCordTheme.secondaryText
                )
            }
        }
    }

    private var appearanceSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(NoctCordAppearance.allCases) { appearance in
                Button {
                    model.appearance = appearance
                } label: {
                    HStack(spacing: 13) {
                        Image(systemName: appearance.symbol)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(NoctCordTheme.mutedCoral)
                            .frame(width: 38, height: 38)
                            .background(
                                NoctCordTheme.input,
                                in: RoundedRectangle(cornerRadius: 11)
                            )
                        Text(appearance.title)
                            .font(.system(size: 13, weight: .semibold))
                        Spacer()
                        Image(systemName: model.appearance == appearance
                            ? "checkmark.circle.fill"
                            : "circle")
                            .foregroundStyle(
                                model.appearance == appearance
                                    ? NoctCordTheme.mutedCoral
                                    : NoctCordTheme.secondaryText
                            )
                    }
                    .padding(14)
                    .background(
                        model.appearance == appearance
                            ? NoctCordTheme.mutedCoral.opacity(0.10)
                            : NoctCordTheme.surface,
                        in: RoundedRectangle(cornerRadius: 15)
                    )
                    .overlay {
                        RoundedRectangle(cornerRadius: 15).stroke(NoctCordTheme.border)
                    }
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func identityCard(
        _ scope: NoctCordIdentityScope,
        title: String,
        description: String,
        symbol: String
    ) -> some View {
        let selected = model.selectedSpace?.identityScope == scope
        return Button {
            model.setIdentityScope(scope)
        } label: {
            HStack(alignment: .top, spacing: 13) {
                Image(systemName: symbol)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(selected
                        ? NoctCordTheme.mutedCoral
                        : NoctCordTheme.secondaryText)
                    .frame(width: 38, height: 38)
                    .background(NoctCordTheme.input, in: RoundedRectangle(cornerRadius: 11))
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.system(size: 13, weight: .semibold))
                    Text(description)
                        .font(.system(size: 10.5))
                        .foregroundStyle(NoctCordTheme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(selected
                        ? NoctCordTheme.mutedCoral
                        : NoctCordTheme.secondaryText)
            }
            .padding(14)
            .background(
                selected ? NoctCordTheme.mutedCoral.opacity(0.10) : NoctCordTheme.surface,
                in: RoundedRectangle(cornerRadius: 15)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 15).stroke(NoctCordTheme.border)
            }
        }
        .buttonStyle(.plain)
    }

    private func privacyToggle(
        title: String,
        description: String,
        symbol: String,
        keyPath: WritableKeyPath<PrivacySettings, Bool>
    ) -> some View {
        settingsCard {
            HStack(alignment: .top, spacing: 13) {
                Image(systemName: symbol)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(NoctCordTheme.mutedCoral)
                    .frame(width: 38, height: 38)
                    .background(NoctCordTheme.input, in: RoundedRectangle(cornerRadius: 11))
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.system(size: 13, weight: .semibold))
                    Text(description)
                        .font(.system(size: 10.5))
                        .foregroundStyle(NoctCordTheme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 16)
                Toggle("", isOn: privacyBinding(keyPath))
                    .labelsHidden()
                    .toggleStyle(.switch)
            }
        }
    }

    private func privacyBinding(
        _ keyPath: WritableKeyPath<PrivacySettings, Bool>
    ) -> Binding<Bool> {
        Binding {
            model.privacySettings[keyPath: keyPath]
        } set: { value in
            var settings = model.privacySettings
            settings[keyPath: keyPath] = value
            model.setPrivacySettings(settings)
        }
    }

    private func sectionLabel(_ value: String) -> some View {
        Text(value)
            .font(.system(size: 10, weight: .bold))
            .tracking(0.8)
            .foregroundStyle(NoctCordTheme.secondaryText)
    }

    private func settingsCard<Content: View>(
        @ViewBuilder content: () -> Content
    ) -> some View {
        content()
            .padding(15)
            .background(NoctCordTheme.surface, in: RoundedRectangle(cornerRadius: 16))
            .overlay {
                RoundedRectangle(cornerRadius: 16).stroke(NoctCordTheme.border)
            }
    }
}

private struct NoctCordRelaySettings: View {
    @ObservedObject var model: NoctCordAppModel
    @State private var name = ""
    @State private var address = ""
    @State private var accessPassword = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            NoctCordSettingsNotice(
                symbol: "network",
                text: "Each community keeps its own relay routes. Joining an invitation can add its relay without moving or disconnecting your other communities.",
                color: NoctCordTheme.mutedCoral
            )

            Text("SAVED RELAYS")
                .font(.system(size: 10, weight: .bold))
                .tracking(0.8)
                .foregroundStyle(NoctCordTheme.secondaryText)
            if model.relayProfiles.isEmpty {
                Text("No relay profiles are available yet.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(NoctCordTheme.secondaryText)
                    .padding(.vertical, 8)
            } else {
                ForEach(model.relayProfiles) { relay in
                    HStack(spacing: 12) {
                        Image(systemName: relay.endpoint.useTLS
                            ? "lock.shield.fill"
                            : "network")
                            .foregroundStyle(relay.endpoint.useTLS
                                ? NoctCordTheme.success
                                : NoctCordTheme.warning)
                            .frame(width: 34, height: 34)
                            .background(NoctCordTheme.input, in: RoundedRectangle(cornerRadius: 10))
                        VStack(alignment: .leading, spacing: 3) {
                            Text(relay.name)
                                .font(.system(size: 12.5, weight: .semibold))
                            Text(relay.address)
                                .font(.system(size: 10.5, design: .monospaced))
                                .foregroundStyle(NoctCordTheme.secondaryText)
                        }
                        Spacer()
                        if relay.hasAccessPassword {
                            Label("Protected", systemImage: "key.fill")
                                .font(.system(size: 9.5, weight: .semibold))
                                .foregroundStyle(NoctCordTheme.secondaryText)
                        }
                    }
                    .padding(13)
                    .background(NoctCordTheme.surface, in: RoundedRectangle(cornerRadius: 15))
                    .overlay {
                        RoundedRectangle(cornerRadius: 15).stroke(NoctCordTheme.border)
                    }
                }
            }

            Text("ADD A RELAY")
                .font(.system(size: 10, weight: .bold))
                .tracking(0.8)
                .foregroundStyle(NoctCordTheme.secondaryText)
                .padding(.top, 4)
            VStack(spacing: 10) {
                TextField("Name (optional)", text: $name)
                TextField("https://relay.example", text: $address)
                SecureField("Access password (optional)", text: $accessPassword)
            }
            .textFieldStyle(.plain)
            .font(.system(size: 12.5, weight: .medium))
            .padding(13)
            .background(NoctCordTheme.input, in: RoundedRectangle(cornerRadius: 14))
            .overlay {
                RoundedRectangle(cornerRadius: 14).stroke(NoctCordTheme.border)
            }
            HStack {
                Text("Remote relays require authenticated TLS. Credentials stay in encrypted local transport state.")
                    .font(.system(size: 10.5))
                    .foregroundStyle(NoctCordTheme.secondaryText)
                Spacer(minLength: 16)
                Button("Verify and add") {
                    Task {
                        if await model.addRelay(
                            address: address,
                            name: name,
                            accessPassword: accessPassword
                        ) {
                            name = ""
                            address = ""
                            accessPassword = ""
                        }
                    }
                }
                .buttonStyle(NoctCordPrimaryButtonStyle())
                .disabled(address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            if let notice = model.settingsNotice {
                NoctCordSettingsNotice(
                    symbol: "info.circle.fill",
                    text: notice,
                    color: NoctCordTheme.secondaryText
                )
            }
        }
    }
}

private struct NoctCordSettingsNotice: View {
    let symbol: String
    let text: String
    let color: Color

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(color)
            Text(text)
                .font(.system(size: 10.5))
                .foregroundStyle(NoctCordTheme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(color.opacity(0.08), in: RoundedRectangle(cornerRadius: 13))
        .overlay {
            RoundedRectangle(cornerRadius: 13).stroke(color.opacity(0.18))
        }
    }
}
