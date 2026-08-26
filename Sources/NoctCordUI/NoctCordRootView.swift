import SwiftUI
import NoctCordCore
import NoctCordMedia
@preconcurrency import NoctweaveCore
import UniformTypeIdentifiers

public struct NoctCordRootView: View {
    @StateObject private var model: NoctCordAppModel
    @Environment(\.scenePhase) private var scenePhase

    public init(
        seedPreviewData: Bool = false,
        liveUITestConfiguration: NoctCordTransportConfiguration? = nil
    ) {
        _model = StateObject(
            wrappedValue: NoctCordAppModel(
                seedPreviewData: seedPreviewData,
                liveUITestConfiguration: liveUITestConfiguration
            )
        )
    }

    public var body: some View {
        Group {
            if shouldShowSetup {
                NoctCordSetupView(model: model)
            } else {
                GeometryReader { proxy in
                    let compact = proxy.size.width < 1_120
                    HStack(spacing: 0) {
                        NoctCordSpaceRail(model: model)
                        NoctCordChannelSidebar(model: model)

                        if model.selectedSpace != nil, model.selectedChannel != nil {
                            VStack(spacing: 0) {
                                NoctCordConversationHeader(model: model, compact: compact)
                                if model.callSnapshot?.remoteVideoTracks.isEmpty == false {
                                    NoctCordRemoteScreenShareStage(model: model)
                                }
                                NoctCordMessageTimeline(model: model)
                                NoctCordComposer(model: model)
                            }
                            .frame(maxWidth: .infinity, maxHeight: .infinity)

                            if model.showsMemberInspector && !compact {
                                NoctCordMemberInspector(model: model)
                                    .transition(.move(edge: .trailing).combined(with: .opacity))
                            }
                        } else {
                            NoctCordEmptyState(model: model)
                        }
                    }
                    .frame(width: proxy.size.width, height: proxy.size.height)
                }
            }
        }
        .background(NoctCordTheme.canvas)
        .ignoresSafeArea(.container, edges: .top)
        .foregroundStyle(NoctCordTheme.primaryText)
        .preferredColorScheme(model.appearance.colorScheme)
        .tint(NoctCordTheme.mutedCoral)
        .sheet(isPresented: $model.showsCreateSpace) {
            CreateSpaceSheet(model: model)
        }
        .sheet(isPresented: $model.showsJoinSpace) {
            NoctCordJoinSpaceSheet(model: model)
        }
        .sheet(isPresented: $model.showsInvitationExchange) {
            NoctCordInvitationExchangeSheet(model: model)
        }
        .sheet(isPresented: $model.showsCreateChannel) {
            CreateChannelSheet(model: model)
        }
        .sheet(isPresented: $model.showsCreateVoiceRoom) {
            CreateVoiceRoomSheet(model: model)
        }
        .sheet(isPresented: $model.showsCommunitySettings) {
            NoctCordCommunitySettingsSheet(model: model)
        }
        .sheet(isPresented: $model.showsUserSettings) {
            NoctCordUserSettingsSheet(model: model)
        }
        .sheet(
            isPresented: Binding(
                get: { model.selectedAttachmentID != nil },
                set: { if !$0 { model.selectedAttachmentID = nil } }
            )
        ) {
            if let id = model.selectedAttachmentID {
                NoctCordAttachmentViewer(
                    attachment: model.cachedAttachments[id],
                    onClose: { model.selectedAttachmentID = nil }
                )
            }
        }
        .fileImporter(
            isPresented: $model.showsAttachmentImporter,
            allowedContentTypes: [.image, .movie, .audio, .pdf, .plainText, .json],
            allowsMultipleSelection: false
        ) { result in
            if case .success(let urls) = result, let url = urls.first {
                model.sendAttachment(at: url)
            }
        }
        .overlay(alignment: .topTrailing) {
            if let activity = model.activityMessage, !shouldShowSetup {
                Label(activity, systemImage: "arrow.triangle.2.circlepath")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(NoctCordTheme.primaryText)
                    .padding(.horizontal, 13)
                    .frame(height: 34)
                    .background(NoctCordTheme.elevated, in: Capsule())
                    .overlay { Capsule().stroke(NoctCordTheme.border) }
                    .padding(16)
            }
        }
        .background {
            NoctCordWindowCaptureProtection(
                blocked: model.privacySettings.macBlockWindowCapture
            )
            .frame(width: 0, height: 0)
        }
        .overlay {
            if model.privacySettings.hideSensitiveWhenUnfocused,
               scenePhase != .active,
               !shouldShowSetup {
                NoctCordPrivacyShield()
            }
        }
    }

    private var shouldShowSetup: Bool {
        switch model.connectionState {
        case .needsSetup, .connecting:
            return model.spaces.isEmpty
        case .failed:
            return model.spaces.isEmpty
        case .preview, .ready:
            return false
        }
    }
}

private struct NoctCordSetupView: View {
    private enum Stage: Int, CaseIterable {
        case welcome
        case profile
        case relay
    }

    @ObservedObject var model: NoctCordAppModel
    @AppStorage("NoctCord.displayName") private var savedDisplayName = ""
    @AppStorage("NoctCord.relayAddress") private var savedRelayAddress = ""
    @AppStorage("NoctCord.stunURL") private var savedSTUNURL = ""
    @AppStorage("NoctCord.turnURL") private var savedTURNURL = ""
    @AppStorage("NoctCord.turnUsername") private var savedTURNUsername = ""
    @State private var stage: Stage = .welcome
    @State private var displayName = ""
    @State private var relayAddress = ""
    @State private var accessPassword = ""
    @State private var invitationCode = ""
    @State private var showsInvitationInput = false
    @State private var showsRelayAccessOptions = false
    @State private var showsCallConnectivity = false
    @State private var stunURL = ""
    @State private var turnURL = ""
    @State private var turnUsername = ""
    @State private var turnCredential = ""
    @State private var validationError: String?
    @State private var showsLocalStateResetConfirmation = false

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    NoctCordTheme.canvas,
                    NoctCordTheme.mutedCoral.opacity(0.11),
                    NoctCordTheme.canvas,
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            GeometryReader { proxy in
                ScrollView {
                    VStack(spacing: 0) {
                        Spacer(minLength: 38)
                        VStack(spacing: 22) {
                            NoctCordMark()
                                .frame(width: 76, height: 76)

                            VStack(spacing: 7) {
                                Text(stageTitle)
                                    .font(.system(size: 28, weight: .bold, design: .rounded))
                                Text(stageSubtitle)
                                    .font(.system(size: 12.5))
                                    .foregroundStyle(NoctCordTheme.secondaryText)
                                    .multilineTextAlignment(.center)
                                    .frame(maxWidth: 480)
                            }

                            HStack(spacing: 7) {
                                ForEach(Stage.allCases, id: \.rawValue) { item in
                                    Capsule()
                                        .fill(
                                            item.rawValue <= stage.rawValue
                                                ? NoctCordTheme.mutedCoral
                                                : NoctCordTheme.secondaryText.opacity(0.20)
                                        )
                                        .frame(
                                            width: item == stage ? 28 : 8,
                                            height: 8
                                        )
                                }
                            }

                            stageContent
                                .padding(23)
                                .frame(maxWidth: 540)
                                .noctCordPanel(radius: 28, elevated: true)

                            Label(
                                "Encrypted locally · relay-blind content · no central Noct Cord account",
                                systemImage: "lock.shield.fill"
                            )
                            .font(.system(size: 10.5, weight: .medium))
                            .foregroundStyle(NoctCordTheme.secondaryText)
                            .multilineTextAlignment(.center)
                        }
                        .padding(.horizontal, 28)
                        Spacer(minLength: 38)
                    }
                    .frame(maxWidth: .infinity, minHeight: proxy.size.height)
                }
                .id(stage.rawValue)
            }
        }
        .onAppear {
            if displayName.isEmpty { displayName = savedDisplayName }
            if relayAddress.isEmpty { relayAddress = savedRelayAddress }
            if stunURL.isEmpty { stunURL = savedSTUNURL }
            if turnURL.isEmpty { turnURL = savedTURNURL }
            if turnUsername.isEmpty { turnUsername = savedTURNUsername }
            if !savedDisplayName.isEmpty,
               !savedRelayAddress.isEmpty,
               savedTURNURL.isEmpty,
               model.connectionState == .needsSetup {
                stage = .relay
                connect()
            }
        }
        .alert(
            "Reset local transport state?",
            isPresented: $showsLocalStateResetConfirmation
        ) {
            Button("Cancel", role: .cancel) {}
            Button("Reset and reconnect", role: .destructive) {
                connect(resetLocalState: true)
            }
        } message: {
            Text("This permanently removes Noct Cord's local encrypted community transport state from this app container. A rollback-protected tombstone is kept so old state cannot be replayed.")
        }
    }

    private var stageTitle: String {
        switch stage {
        case .welcome: "Welcome to Noct Cord"
        case .profile: "Your local profile"
        case .relay: "Connect a relay"
        }
    }

    private var stageSubtitle: String {
        switch stage {
        case .welcome:
            "Encrypted communities and realtime collaboration over the Noctweave transport."
        case .profile:
            "Name this installation. Each community still receives fresh group-only credentials."
        case .relay:
            "Enter one address. Noct Cord verifies the relay and discovers call connectivity automatically."
        }
    }

    @ViewBuilder
    private var stageContent: some View {
        switch stage {
        case .welcome:
            welcomeStage
        case .profile:
            profileStage
        case .relay:
            relayStage
        }
    }

    private var welcomeStage: some View {
        VStack(alignment: .leading, spacing: 16) {
            setupFeature(
                "rectangle.3.group.bubble.left.fill",
                title: "Communities without central accounts",
                text: "Channels, roles, attachments, and calls are encrypted application state."
            )
            setupFeature(
                "person.crop.circle.badge.checkmark",
                title: "A different credential in every community",
                text: "Portable profiles are optional; group transport keys are never reused."
            )
            setupFeature(
                "server.rack",
                title: "Choose your community network",
                text: "Use an invitation's relay or one you trust. Noct Cord never silently enrolls you in a service."
            )

            DisclosureGroup(isExpanded: $showsInvitationInput) {
                VStack(alignment: .leading, spacing: 10) {
                    TextEditor(text: $invitationCode)
                        .font(.system(size: 10.5, design: .monospaced))
                        .scrollContentBackground(.hidden)
                        .padding(8)
                        .frame(minHeight: 94)
                        .background(NoctCordTheme.input, in: RoundedRectangle(cornerRadius: 15))
                        .overlay { RoundedRectangle(cornerRadius: 15).stroke(NoctCordTheme.border) }
                    Button("Use invitation relay") { useInvitation() }
                        .buttonStyle(NoctCordSecondaryButtonStyle())
                }
                .padding(.top, 11)
            } label: {
                Label("Join with a community invitation", systemImage: "link.badge.plus")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(NoctCordTheme.secondaryText)
            }

            validationView

            Button("Continue without an invitation") {
                validationError = nil
                stage = .profile
            }
            .buttonStyle(NoctCordPrimaryButtonStyle())
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }

    private var profileStage: some View {
        VStack(alignment: .leading, spacing: 16) {
            setupField("DISPLAY NAME", placeholder: "How you appear", text: $displayName)
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "eye.slash.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(NoctCordTheme.mutedCoral)
                    .frame(width: 38, height: 38)
                    .background(NoctCordTheme.mutedCoral.opacity(0.10), in: Circle())
                VStack(alignment: .leading, spacing: 5) {
                    Text("Private by default")
                        .font(.system(size: 12.5, weight: .semibold))
                    Text("When joining or creating a community, Noct Cord recommends an isolated profile. You can deliberately disclose a portable profile per community instead.")
                        .font(.system(size: 10.5))
                        .foregroundStyle(NoctCordTheme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(15)
            .background(NoctCordTheme.surface, in: RoundedRectangle(cornerRadius: 18))
            .overlay { RoundedRectangle(cornerRadius: 18).stroke(NoctCordTheme.border) }
            validationView
            HStack {
                Button("Back") { stage = .welcome }
                    .buttonStyle(NoctCordSecondaryButtonStyle())
                Spacer()
                Button("Continue") {
                    let clean = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !clean.isEmpty, clean.utf8.count <= 128 else {
                        validationError = "Enter a display name of 128 bytes or fewer."
                        return
                    }
                    validationError = nil
                    stage = .relay
                }
                .buttonStyle(NoctCordPrimaryButtonStyle())
            }
        }
    }

    private var relayStage: some View {
        VStack(alignment: .leading, spacing: 13) {
            setupField("RELAY", placeholder: "https://relay.example", text: $relayAddress)
            DisclosureGroup(isExpanded: $showsRelayAccessOptions) {
                setupField(
                    "RELAY PASSWORD",
                    placeholder: "Only if required by the operator",
                    text: $accessPassword,
                    secure: true
                )
                .padding(.top, 11)
            } label: {
                Label("Advanced relay access", systemImage: "key.fill")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(NoctCordTheme.secondaryText)
            }
            DisclosureGroup(isExpanded: $showsCallConnectivity) {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Noct Cord automatically uses the STUN/TURN service advertised by this relay. Add values here only to override the operator's service for this app session.")
                        .font(.system(size: 10.5))
                        .foregroundStyle(NoctCordTheme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                    setupField(
                        "STUN URL · OPTIONAL",
                        placeholder: "stun:stun.example.org:3478",
                        text: $stunURL
                    )
                    setupField(
                        "TURN URL · OPTIONAL",
                        placeholder: "turns:turn.example.org:5349?transport=tcp",
                        text: $turnURL
                    )
                    if !turnURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        setupField(
                            "TURN USERNAME",
                            placeholder: "Short-lived username",
                            text: $turnUsername
                        )
                        setupField(
                            "TURN CREDENTIAL",
                            placeholder: "Kept only for this app session",
                            text: $turnCredential,
                            secure: true
                        )
                    }
                }
                .padding(.top, 11)
            } label: {
                Label("Advanced call network override", systemImage: "antenna.radiowaves.left.and.right")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(NoctCordTheme.secondaryText)
            }
            validationView
            if case .failed(let message) = model.connectionState {
                VStack(alignment: .leading, spacing: 10) {
                    Label(message, systemImage: "network.slash")
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(NoctCordTheme.mutedCoral)
                        .fixedSize(horizontal: false, vertical: true)
                    if model.permitsLocalStateReset {
                        Button("Reset local transport state…") {
                            showsLocalStateResetConfirmation = true
                        }
                        .buttonStyle(NoctCordSecondaryButtonStyle())
                    }
                }
            }
            HStack {
                Button("Back") { stage = .profile }
                    .buttonStyle(NoctCordSecondaryButtonStyle())
                Spacer()
                Button {
                    connect()
                } label: {
                    HStack(spacing: 8) {
                        if model.connectionState == .connecting {
                            ProgressView().controlSize(.small)
                        }
                        Text(
                            model.connectionState == .connecting
                                ? "Connecting…"
                                : "Connect Securely"
                        )
                    }
                }
                .buttonStyle(NoctCordPrimaryButtonStyle())
                .disabled(model.connectionState == .connecting)
            }
        }
    }

    @ViewBuilder
    private var validationView: some View {
        if let validationError {
            Label(validationError, systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(NoctCordTheme.warning)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func setupFeature(_ symbol: String, title: String, text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(NoctCordTheme.mutedCoral)
                .frame(width: 38, height: 38)
                .background(NoctCordTheme.mutedCoral.opacity(0.10), in: Circle())
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 12.5, weight: .semibold))
                Text(text)
                    .font(.system(size: 10.5))
                    .foregroundStyle(NoctCordTheme.secondaryText)
            }
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private func setupField(
        _ title: String,
        placeholder: String,
        text: Binding<String>,
        secure: Bool = false
    ) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title)
                .font(.system(size: 9.5, weight: .bold))
                .tracking(0.8)
                .foregroundStyle(NoctCordTheme.secondaryText)
            Group {
                if secure {
                    SecureField(placeholder, text: text)
                } else {
                    TextField(placeholder, text: text)
                }
            }
            .textFieldStyle(.plain)
            .font(.system(size: 13, weight: .medium))
            .padding(.horizontal, 13)
            .frame(height: 42)
            .background(NoctCordTheme.input, in: RoundedRectangle(cornerRadius: 12))
            .overlay { RoundedRectangle(cornerRadius: 12).stroke(NoctCordTheme.border) }
        }
    }

    private func connect(resetLocalState: Bool = false) {
        validationError = nil
        let cleanName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanName.isEmpty, cleanName.utf8.count <= 128 else {
            validationError = "Enter a display name of 128 bytes or fewer."
            return
        }
        let endpoint: RelayEndpoint
        do {
            endpoint = try RelayEndpointParser.parse(relayAddress)
        } catch {
            validationError = error.localizedDescription
            return
        }
        var iceServers: [NoctCordMediaICEServer] = []
        do {
            let cleanSTUN = stunURL.trimmingCharacters(in: .whitespacesAndNewlines)
            if !cleanSTUN.isEmpty {
                iceServers.append(try NoctCordMediaICEServer(url: cleanSTUN))
            }
            let cleanTURN = turnURL.trimmingCharacters(in: .whitespacesAndNewlines)
            if !cleanTURN.isEmpty {
                let username = turnUsername.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !username.isEmpty, !turnCredential.isEmpty else {
                    validationError = "TURN requires both a username and credential. The credential is kept only for this app session."
                    return
                }
                iceServers.append(try NoctCordMediaICEServer(
                    url: cleanTURN,
                    username: username,
                    credential: turnCredential
                ))
            }
        } catch {
            validationError = error.localizedDescription
            return
        }
        do {
            let root = try Self.stateDirectory()
            let configuration = NoctCordTransportConfiguration(
                stateURL: root.appendingPathComponent("client-state.noctcord"),
                displayName: cleanName,
                relay: endpoint,
                relayName: endpoint.host,
                relayAccessPassword: accessPassword.isEmpty ? nil : accessPassword
            )
            let relayAddressToSave = relayAddress.trimmingCharacters(in: .whitespacesAndNewlines)
            let stunURLToSave = stunURL.trimmingCharacters(in: .whitespacesAndNewlines)
            let turnURLToSave = turnURL.trimmingCharacters(in: .whitespacesAndNewlines)
            let turnUsernameToSave = turnUsername.trimmingCharacters(in: .whitespacesAndNewlines)
            Task {
                if resetLocalState {
                    await model.resetLocalStateAndConnect(
                        configuration: configuration,
                        iceServers: iceServers
                    )
                } else {
                    await model.connect(
                        configuration: configuration,
                        iceServers: iceServers
                    )
                }
                if model.connectionState == .ready {
                    savedDisplayName = cleanName
                    savedRelayAddress = relayAddressToSave
                    savedSTUNURL = stunURLToSave
                    savedTURNURL = turnURLToSave
                    savedTURNUsername = turnUsernameToSave
                    if !model.stagedInvitationCode.isEmpty {
                        model.showsJoinSpace = true
                    }
                }
            }
        } catch {
            validationError = error.localizedDescription
        }
    }

    private func useInvitation() {
        do {
            let invitation = try NoctCordCommunityInvitationV1.decode(invitationCode)
            relayAddress = endpointString(invitation.relay)
            model.stagedInvitationCode = invitationCode
            validationError = nil
            stage = .profile
        } catch {
            validationError = error.localizedDescription
        }
    }

    private func endpointString(_ endpoint: RelayEndpoint) -> String {
        let scheme: String
        switch (endpoint.transport, endpoint.useTLS) {
        case (.http, true): scheme = "https"
        case (.http, false): scheme = "http"
        case (.websocket, true): scheme = "wss"
        case (.websocket, false): scheme = "ws"
        case (.tcp, true): scheme = "tls"
        case (.tcp, false): scheme = "tcp"
        }
        return "\(scheme)://\(endpoint.host):\(endpoint.port)"
    }

    private static func stateDirectory() throws -> URL {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let directory = base.appendingPathComponent("NoctCord", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        return directory
    }

}

private struct NoctCordEmptyState: View {
    @ObservedObject var model: NoctCordAppModel

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [NoctCordTheme.canvas, NoctCordTheme.mutedCoral.opacity(0.06)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            VStack(spacing: 17) {
                NoctCordMark()
                    .frame(width: 72, height: 72)
                VStack(spacing: 7) {
                    Text("Create your first space")
                        .font(.system(size: 24, weight: .bold, design: .rounded))
                    Text("Channels, roles, and community history stay encrypted above Noctweave.")
                        .font(.system(size: 13))
                        .foregroundStyle(NoctCordTheme.secondaryText)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 420)
                }
                HStack(spacing: 11) {
                    Button("Create a community") {
                        model.showsCreateSpace = true
                    }
                    .buttonStyle(NoctCordPrimaryButtonStyle())
                    Button("Join with invitation") {
                        model.showsJoinSpace = true
                    }
                    .buttonStyle(NoctCordSecondaryButtonStyle())
                }
            }
            .padding(36)
            .noctCordPanel(radius: 26, elevated: true)
        }
    }
}

private struct CreateSpaceSheet: View {
    @ObservedObject var model: NoctCordAppModel
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var scope: NoctCordIdentityScope = .isolated
    @State private var relayPreferenceID: UUID?

    var body: some View {
        NoctCordSheetShell(
            symbol: "rectangle.3.group.bubble.left.fill",
            title: "Create a space",
            subtitle: "Start with one encrypted channel and choose how this membership is presented."
        ) {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("SPACE NAME")
                        .font(.system(size: 10, weight: .bold))
                        .tracking(0.8)
                        .foregroundStyle(NoctCordTheme.secondaryText)
                    TextField("Night Shift", text: $name)
                        .textFieldStyle(.plain)
                        .font(.system(size: 14, weight: .medium))
                        .padding(.horizontal, 14)
                        .frame(height: 42)
                        .background(NoctCordTheme.input, in: RoundedRectangle(cornerRadius: 12))
                        .overlay {
                            RoundedRectangle(cornerRadius: 12)
                                .stroke(NoctCordTheme.border, lineWidth: 1)
                        }
                }

                VStack(alignment: .leading, spacing: 9) {
                    Text("IDENTITY FOR THIS SPACE")
                        .font(.system(size: 10, weight: .bold))
                        .tracking(0.8)
                        .foregroundStyle(NoctCordTheme.secondaryText)
                    identityOption(
                        .isolated,
                        title: "Use an isolated identity",
                        detail: "Fresh profile key with no cross-community proof.",
                        symbol: "eye.slash.fill"
                    )
                    identityOption(
                        .portable,
                        title: "Use my portable identity",
                        detail: "Members can correlate this profile across communities.",
                        symbol: "link"
                    )
                }

                if !model.relayProfiles.isEmpty {
                    VStack(alignment: .leading, spacing: 9) {
                        Text("RELAY FOR THIS COMMUNITY")
                            .font(.system(size: 10, weight: .bold))
                            .tracking(0.8)
                            .foregroundStyle(NoctCordTheme.secondaryText)
                        ForEach(model.relayProfiles) { relay in
                            relayOption(relay)
                        }
                        Text("This choice applies only to the new community. Your other communities keep their own relay routes.")
                            .font(.system(size: 10.5))
                            .foregroundStyle(NoctCordTheme.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                HStack {
                    Button("Cancel") { dismiss() }
                        .buttonStyle(NoctCordSecondaryButtonStyle())
                    Spacer()
                    Button("Create space") {
                        model.createSpace(
                            name: name,
                            identityScope: scope,
                            relayPreferenceID: relayPreferenceID
                        )
                        dismiss()
                    }
                    .buttonStyle(NoctCordPrimaryButtonStyle())
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .onAppear {
            if relayPreferenceID == nil {
                relayPreferenceID = model.relayProfiles.first?.id
            }
        }
    }

    private func relayOption(_ relay: NoctCordRelayProfile) -> some View {
        let selected = relayPreferenceID == relay.id
        return Button {
            relayPreferenceID = relay.id
        } label: {
            HStack(spacing: 12) {
                Image(systemName: relay.endpoint.useTLS ? "lock.shield.fill" : "network")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(selected ? NoctCordTheme.mutedCoral : NoctCordTheme.secondaryText)
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
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(selected ? NoctCordTheme.mutedCoral : NoctCordTheme.secondaryText)
            }
            .padding(12)
            .background(
                selected ? NoctCordTheme.mutedCoral.opacity(0.10) : NoctCordTheme.surface,
                in: RoundedRectangle(cornerRadius: 14)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 14).stroke(NoctCordTheme.border)
            }
        }
        .buttonStyle(.plain)
    }

    private func identityOption(
        _ value: NoctCordIdentityScope,
        title: String,
        detail: String,
        symbol: String
    ) -> some View {
        Button {
            scope = value
        } label: {
            HStack(spacing: 12) {
                Image(systemName: symbol)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(scope == value ? NoctCordTheme.mutedCoral : NoctCordTheme.secondaryText)
                    .frame(width: 34, height: 34)
                    .background(NoctCordTheme.input, in: RoundedRectangle(cornerRadius: 10))
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.system(size: 12.5, weight: .semibold))
                    Text(detail)
                        .font(.system(size: 10.5))
                        .foregroundStyle(NoctCordTheme.secondaryText)
                }
                Spacer()
                Image(systemName: scope == value ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(scope == value ? NoctCordTheme.mutedCoral : NoctCordTheme.secondaryText)
            }
            .foregroundStyle(NoctCordTheme.primaryText)
            .padding(12)
            .background(
                scope == value ? NoctCordTheme.mutedCoral.opacity(0.10) : NoctCordTheme.surface,
                in: RoundedRectangle(cornerRadius: 14)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 14)
                    .stroke(
                        scope == value ? NoctCordTheme.mutedCoral.opacity(0.45) : NoctCordTheme.border,
                        lineWidth: 1
                    )
            }
            .contentShape(RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
    }
}

private struct CreateChannelSheet: View {
    @ObservedObject var model: NoctCordAppModel
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""

    var body: some View {
        NoctCordSheetShell(
            symbol: "number",
            title: "New text channel",
            subtitle: "Channel names and messages are encrypted application state."
        ) {
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 9) {
                    Image(systemName: "number")
                        .foregroundStyle(NoctCordTheme.secondaryText)
                    TextField("channel-name", text: $name)
                        .textFieldStyle(.plain)
                        .font(.system(size: 14, weight: .medium))
                }
                .padding(.horizontal, 14)
                .frame(height: 44)
                .background(NoctCordTheme.input, in: RoundedRectangle(cornerRadius: 12))
                .overlay {
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(NoctCordTheme.border, lineWidth: 1)
                }

                HStack {
                    Button("Cancel") { dismiss() }
                        .buttonStyle(NoctCordSecondaryButtonStyle())
                    Spacer()
                    Button("Create channel") {
                        model.createChannel(name: name)
                        dismiss()
                    }
                    .buttonStyle(NoctCordPrimaryButtonStyle())
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }
}

private struct CreateVoiceRoomSheet: View {
    @ObservedObject var model: NoctCordAppModel
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var capacity = 8.0

    var body: some View {
        NoctCordSheetShell(
            symbol: "waveform",
            title: "New voice room",
            subtitle: "Any active member of this encrypted space can join. Audio and screen-share media travel peer to peer; the relay carries encrypted signaling only."
        ) {
            VStack(alignment: .leading, spacing: 18) {
                TextField("Room name", text: $name)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14, weight: .medium))
                    .padding(.horizontal, 14)
                    .frame(height: 44)
                    .background(NoctCordTheme.input, in: RoundedRectangle(cornerRadius: 12))
                    .overlay { RoundedRectangle(cornerRadius: 12).stroke(NoctCordTheme.border) }

                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("PARTICIPANT LIMIT")
                            .font(.system(size: 10, weight: .bold))
                            .tracking(0.8)
                            .foregroundStyle(NoctCordTheme.secondaryText)
                        Spacer()
                        Text("\(Int(capacity))")
                            .font(.system(size: 11, weight: .semibold))
                    }
                    Slider(value: $capacity, in: 2...8, step: 1)
                    Text("Peer-to-peer mesh rooms are capped at 8 members to keep CPU and uplink use predictable. Larger rooms require an authenticated media forwarder, which is not enabled in this build.")
                        .font(.system(size: 10.5))
                        .foregroundStyle(NoctCordTheme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Label(
                    model.callConnectivityDescription,
                    systemImage: "network"
                )
                .font(.system(size: 10.5))
                .foregroundStyle(NoctCordTheme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)

                HStack {
                    Button("Cancel") { dismiss() }
                        .buttonStyle(NoctCordSecondaryButtonStyle())
                    Spacer()
                    Button("Create room") {
                        model.createVoiceRoom(
                            name: name,
                            maxParticipants: UInt16(capacity)
                        )
                        dismiss()
                    }
                    .buttonStyle(NoctCordPrimaryButtonStyle())
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }
}

private struct NoctCordSheetShell<Content: View>: View {
    let symbol: String
    let title: String
    let subtitle: String
    @ViewBuilder let content: Content

    init(
        symbol: String,
        title: String,
        subtitle: String,
        @ViewBuilder content: () -> Content
    ) {
        self.symbol = symbol
        self.title = title
        self.subtitle = subtitle
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(alignment: .top, spacing: 13) {
                Image(systemName: symbol)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(NoctCordTheme.mutedCoral)
                    .frame(width: 44, height: 44)
                    .background(NoctCordTheme.mutedCoral.opacity(0.11), in: RoundedRectangle(cornerRadius: 13))
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.system(size: 20, weight: .bold, design: .rounded))
                        .foregroundStyle(NoctCordTheme.primaryText)
                    Text(subtitle)
                        .font(.system(size: 11.5))
                        .foregroundStyle(NoctCordTheme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            content
        }
        .padding(24)
        .frame(width: 470)
        .background(NoctCordTheme.canvas)
    }
}

struct NoctCordPrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 16)
            .frame(height: 36)
            .background(
                configuration.isPressed
                    ? NoctCordTheme.deepWine
                    : NoctCordTheme.mutedCoral,
                in: Capsule()
            )
            .opacity(configuration.isPressed ? 0.88 : 1)
    }
}

struct NoctCordSecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(NoctCordTheme.primaryText)
            .padding(.horizontal, 15)
            .frame(height: 36)
            .background(NoctCordTheme.input, in: Capsule())
            .overlay { Capsule().stroke(NoctCordTheme.border, lineWidth: 1) }
            .opacity(configuration.isPressed ? 0.72 : 1)
    }
}
