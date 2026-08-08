import SwiftUI
import NoctCordCore
import NoctCordMedia
@preconcurrency import NoctweaveCore
import UniformTypeIdentifiers

public struct NoctCordRootView: View {
    @StateObject private var model: NoctCordAppModel

    public init(seedPreviewData: Bool = false) {
        _model = StateObject(
            wrappedValue: NoctCordAppModel(seedPreviewData: seedPreviewData)
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
        .sheet(isPresented: $model.showsCreateChannel) {
            CreateChannelSheet(model: model)
        }
        .sheet(isPresented: $model.showsCreateVoiceRoom) {
            CreateVoiceRoomSheet(model: model)
        }
        .sheet(isPresented: $model.showsIdentity) {
            IdentitySettingsSheet(model: model)
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
    @ObservedObject var model: NoctCordAppModel
    @AppStorage("NoctCord.displayName") private var savedDisplayName = ""
    @AppStorage("NoctCord.relayAddress") private var savedRelayAddress = ""
    @AppStorage("NoctCord.stunURL") private var savedSTUNURL = ""
    @AppStorage("NoctCord.turnURL") private var savedTURNURL = ""
    @AppStorage("NoctCord.turnUsername") private var savedTURNUsername = ""
    @State private var displayName = ""
    @State private var relayAddress = ""
    @State private var accessPassword = ""
    @State private var showsCallConnectivity = false
    @State private var stunURL = ""
    @State private var turnURL = ""
    @State private var turnUsername = ""
    @State private var turnCredential = ""
    @State private var validationError: String?

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    NoctCordTheme.canvas,
                    NoctCordTheme.mutedCoral.opacity(0.10),
                    NoctCordTheme.canvas,
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            VStack(spacing: 22) {
                NoctCordMark()
                    .frame(width: 76, height: 76)
                VStack(spacing: 7) {
                    Text("Welcome to Noct Cord")
                        .font(.system(size: 27, weight: .bold, design: .rounded))
                    Text("Choose a Noctweave relay and create the local identity used for your encrypted communities.")
                        .font(.system(size: 12.5))
                        .foregroundStyle(NoctCordTheme.secondaryText)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 460)
                }

                VStack(alignment: .leading, spacing: 13) {
                    setupField("DISPLAY NAME", placeholder: "Your display name", text: $displayName)
                    setupField("RELAY", placeholder: "https://relay.example", text: $relayAddress)
                    setupField(
                        "RELAY PASSWORD · OPTIONAL",
                        placeholder: "Not stored",
                        text: $accessPassword,
                        secure: true
                    )
                    DisclosureGroup(isExpanded: $showsCallConnectivity) {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("No third-party call service is selected automatically. Leave these blank for LAN-only calls, add STUN for NAT discovery, or add TURN when peers need a media relay.")
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
                                    placeholder: "Not stored on disk",
                                    text: $turnCredential,
                                    secure: true
                                )
                            }
                        }
                        .padding(.top, 11)
                    } label: {
                        Label("Advanced call connectivity", systemImage: "antenna.radiowaves.left.and.right")
                            .font(.system(size: 11.5, weight: .semibold))
                            .foregroundStyle(NoctCordTheme.secondaryText)
                    }
                    if let validationError {
                        Label(validationError, systemImage: "exclamationmark.triangle.fill")
                            .font(.system(size: 10.5, weight: .medium))
                            .foregroundStyle(NoctCordTheme.warning)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if case .failed(let message) = model.connectionState {
                        Label(message, systemImage: "network.slash")
                            .font(.system(size: 10.5, weight: .medium))
                            .foregroundStyle(NoctCordTheme.mutedCoral)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Button {
                        connect()
                    } label: {
                        HStack(spacing: 8) {
                            if model.connectionState == .connecting {
                                ProgressView().controlSize(.small)
                            }
                            Text(model.connectionState == .connecting ? "Connecting…" : "Test relay and continue")
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(NoctCordPrimaryButtonStyle())
                    .disabled(model.connectionState == .connecting)
                }
                .padding(22)
                .frame(maxWidth: 500)
                .noctCordPanel(radius: 22, elevated: true)

                Text("Your identity state is encrypted locally. The relay stores opaque encrypted records and never receives channel plaintext.")
                    .font(.system(size: 10.5))
                    .foregroundStyle(NoctCordTheme.secondaryText)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 480)
            }
            .padding(38)
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
                connect()
            }
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

    private func connect() {
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
            savedDisplayName = cleanName
            savedRelayAddress = relayAddress.trimmingCharacters(in: .whitespacesAndNewlines)
            savedSTUNURL = stunURL.trimmingCharacters(in: .whitespacesAndNewlines)
            savedTURNURL = turnURL.trimmingCharacters(in: .whitespacesAndNewlines)
            savedTURNUsername = turnUsername.trimmingCharacters(in: .whitespacesAndNewlines)
            Task {
                await model.connect(
                    configuration: configuration,
                    iceServers: iceServers
                )
            }
        } catch {
            validationError = error.localizedDescription
        }
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
                Button("Create a space") {
                    model.showsCreateSpace = true
                }
                .buttonStyle(NoctCordPrimaryButtonStyle())
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

                HStack {
                    Button("Cancel") { dismiss() }
                        .buttonStyle(NoctCordSecondaryButtonStyle())
                    Spacer()
                    Button("Create space") {
                        model.createSpace(name: name, identityScope: scope)
                        dismiss()
                    }
                    .buttonStyle(NoctCordPrimaryButtonStyle())
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
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

private struct IdentitySettingsSheet: View {
    @ObservedObject var model: NoctCordAppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NoctCordSheetShell(
            symbol: "person.text.rectangle.fill",
            title: "Community identity",
            subtitle: "Transport credentials remain fresh either way. This controls what other members can correlate."
        ) {
            VStack(spacing: 10) {
                identityCard(
                    .portable,
                    title: "Portable identity",
                    description: "Present the same ML-DSA profile in multiple spaces. This is convenient and intentionally linkable.",
                    symbol: "link"
                )
                identityCard(
                    .isolated,
                    title: "Isolated identity",
                    description: "Use a profile unique to this space. No portable identity proof is published.",
                    symbol: "eye.slash.fill"
                )

                HStack(alignment: .top, spacing: 9) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(NoctCordTheme.warning)
                    Text("Changing to isolated mode cannot erase portable bindings that community members have already observed.")
                        .font(.system(size: 10.5))
                        .foregroundStyle(NoctCordTheme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                }
                .padding(12)
                .background(NoctCordTheme.warning.opacity(0.09), in: RoundedRectangle(cornerRadius: 13))

                HStack {
                    Spacer()
                    Button("Done") { dismiss() }
                        .buttonStyle(NoctCordPrimaryButtonStyle())
                }
                .padding(.top, 7)
            }
        }
    }

    private func identityCard(
        _ scope: NoctCordIdentityScope,
        title: String,
        description: String,
        symbol: String
    ) -> some View {
        let isSelected = model.selectedSpace?.identityScope == scope
        return Button {
            model.setIdentityScope(scope)
        } label: {
            HStack(alignment: .top, spacing: 13) {
                Image(systemName: symbol)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(isSelected ? NoctCordTheme.mutedCoral : NoctCordTheme.secondaryText)
                    .frame(width: 38, height: 38)
                    .background(NoctCordTheme.input, in: RoundedRectangle(cornerRadius: 11))
                VStack(alignment: .leading, spacing: 5) {
                    Text(title)
                        .font(.system(size: 13, weight: .semibold))
                    Text(description)
                        .font(.system(size: 10.5))
                        .foregroundStyle(NoctCordTheme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isSelected ? NoctCordTheme.mutedCoral : NoctCordTheme.secondaryText)
            }
            .foregroundStyle(NoctCordTheme.primaryText)
            .padding(14)
            .background(
                isSelected ? NoctCordTheme.mutedCoral.opacity(0.10) : NoctCordTheme.surface,
                in: RoundedRectangle(cornerRadius: 15)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 15)
                    .stroke(isSelected ? NoctCordTheme.mutedCoral.opacity(0.45) : NoctCordTheme.border)
            }
            .contentShape(RoundedRectangle(cornerRadius: 15))
        }
        .buttonStyle(.plain)
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
