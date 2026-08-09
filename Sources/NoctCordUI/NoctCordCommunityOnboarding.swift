import SwiftUI
import NoctCordCore
@preconcurrency import NoctweaveCore
#if os(macOS)
import AppKit
#elseif os(iOS)
import UIKit
#endif

struct NoctCordJoinSpaceSheet: View {
    @ObservedObject var model: NoctCordAppModel
    @Environment(\.dismiss) private var dismiss
    @State private var invitationCode = ""
    @State private var invitation: NoctCordCommunityInvitationV1?
    @State private var identityScope: NoctCordIdentityScope = .isolated
    @State private var requestCode = ""
    @State private var responseCode = ""
    @State private var isWorking = false
    @State private var errorMessage: String?

    var body: some View {
        NoctCordOnboardingShell(
            symbol: "person.crop.circle.badge.plus",
            title: "Join a community",
            subtitle: subtitle,
            step: currentStep,
            stepCount: 3,
            close: { dismiss() }
        ) {
            Group {
                if requestCode.isEmpty {
                    invitationStep
                } else {
                    acceptanceStep
                }
            }
            .animation(.easeInOut(duration: 0.18), value: requestCode.isEmpty)
        }
        .onAppear {
            guard invitationCode.isEmpty, !model.stagedInvitationCode.isEmpty else { return }
            invitationCode = model.stagedInvitationCode
            reviewInvitation()
            model.stagedInvitationCode = ""
        }
    }

    private var currentStep: Int {
        if requestCode.isEmpty { return invitation == nil ? 1 : 2 }
        return 3
    }

    private var subtitle: String {
        switch currentStep {
        case 1: "Open the bounded invitation supplied by a community member."
        case 2: "Choose what this community can correlate about your profile."
        default: "Return the request, then verify the signed acceptance."
        }
    }

    @ViewBuilder
    private var invitationStep: some View {
        if let invitation {
            invitationPreview(invitation)
        } else {
            VStack(alignment: .leading, spacing: 16) {
                NoctCordNoticeCard(
                    symbol: "lock.shield.fill",
                    title: "Authenticate the sender",
                    text: "Invitation codes are bounded and tamper-evident, but they are not a public identity directory. Obtain this code from a person or channel you already trust."
                )
                NoctCordCodeEditor(
                    title: "INVITATION CODE",
                    prompt: "Paste noctcord-community-invite-v1:…",
                    text: $invitationCode,
                    minimumHeight: 132
                )
                errorView
                HStack {
                    Button("Cancel") { dismiss() }
                        .buttonStyle(NoctCordSecondaryButtonStyle())
                    Spacer()
                    Button("Review invitation") { reviewInvitation() }
                        .buttonStyle(NoctCordPrimaryButtonStyle())
                        .disabled(invitationCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }

    private func invitationPreview(
        _ invitation: NoctCordCommunityInvitationV1
    ) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 13) {
                    Text(String(invitation.spaceName.prefix(2)).uppercased())
                        .font(.system(size: 17, weight: .bold, design: .rounded))
                        .frame(width: 48, height: 48)
                        .background(
                            LinearGradient(
                                colors: [NoctCordTheme.mutedCoral, NoctCordTheme.deepWine],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            in: RoundedRectangle(cornerRadius: 16, style: .continuous)
                        )
                    VStack(alignment: .leading, spacing: 4) {
                        Text(invitation.spaceName)
                            .font(.system(size: 19, weight: .bold, design: .rounded))
                        Text(relayLabel(invitation.relay))
                            .font(.system(size: 11.5, weight: .medium))
                            .foregroundStyle(NoctCordTheme.secondaryText)
                    }
                    Spacer()
                    Label("Expires \(invitation.expiresAt, style: .relative)", systemImage: "clock")
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(NoctCordTheme.secondaryText)
                }
            }
            .padding(16)
            .background(NoctCordTheme.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(NoctCordTheme.border)
            }

            VStack(alignment: .leading, spacing: 10) {
                Text("IDENTITY IN THIS COMMUNITY")
                    .font(.system(size: 10, weight: .bold))
                    .tracking(0.8)
                    .foregroundStyle(NoctCordTheme.secondaryText)
                identityOption(
                    .isolated,
                    title: "Join privately",
                    detail: "Create fresh profile and transport credentials used only here.",
                    symbol: "eye.slash.fill",
                    recommended: true
                )
                identityOption(
                    .portable,
                    title: "Use a portable profile",
                    detail: "Disclose a profile that members may correlate with other communities.",
                    symbol: "link",
                    recommended: false
                )
            }

            NoctCordNoticeCard(
                symbol: "arrow.left.arrow.right.circle.fill",
                title: "One private round trip",
                text: "Noct Cord creates a fresh post-quantum group credential and a request code. Return it to the inviter, then paste their signed acceptance below."
            )
            errorView
            HStack {
                Button("Back") {
                    self.invitation = nil
                    errorMessage = nil
                }
                .buttonStyle(NoctCordSecondaryButtonStyle())
                Spacer()
                Button(isWorking ? "Preparing…" : "Create join request") {
                    prepareRequest(invitation)
                }
                .buttonStyle(NoctCordPrimaryButtonStyle())
                .disabled(isWorking)
            }
        }
    }

    private var acceptanceStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            NoctCordCodeOutput(
                title: "YOUR JOIN REQUEST",
                value: requestCode,
                actionTitle: "Copy request"
            )
            NoctCordNoticeCard(
                symbol: "paperplane.fill",
                title: "Send this back to the inviter",
                text: "The request contains a fresh community-only public credential and receive route. It contains no portable private key or relay password."
            )
            NoctCordCodeEditor(
                title: "SIGNED ACCEPTANCE",
                prompt: "Paste noctweave-group-welcome-v1:…",
                text: $responseCode,
                minimumHeight: 126
            )
            errorView
            HStack {
                Button("Finish later") { dismiss() }
                    .buttonStyle(NoctCordSecondaryButtonStyle())
                Spacer()
                Button(isWorking ? "Verifying…" : "Verify and join") {
                    acceptResponse()
                }
                .buttonStyle(NoctCordPrimaryButtonStyle())
                .disabled(
                    isWorking
                        || responseCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                )
            }
        }
    }

    private func identityOption(
        _ scope: NoctCordIdentityScope,
        title: String,
        detail: String,
        symbol: String,
        recommended: Bool
    ) -> some View {
        Button {
            identityScope = scope
        } label: {
            HStack(spacing: 13) {
                Image(systemName: symbol)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(
                        identityScope == scope
                            ? NoctCordTheme.mutedCoral
                            : NoctCordTheme.secondaryText
                    )
                    .frame(width: 38, height: 38)
                    .background(NoctCordTheme.input, in: RoundedRectangle(cornerRadius: 12))
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 7) {
                        Text(title).font(.system(size: 12.5, weight: .semibold))
                        if recommended {
                            Text("Recommended")
                                .font(.system(size: 8.5, weight: .bold))
                                .padding(.horizontal, 7)
                                .frame(height: 18)
                                .background(NoctCordTheme.mutedCoral.opacity(0.13), in: Capsule())
                        }
                    }
                    Text(detail)
                        .font(.system(size: 10.5))
                        .foregroundStyle(NoctCordTheme.secondaryText)
                }
                Spacer()
                Image(systemName: identityScope == scope ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(
                        identityScope == scope
                            ? NoctCordTheme.mutedCoral
                            : NoctCordTheme.secondaryText
                    )
            }
            .foregroundStyle(NoctCordTheme.primaryText)
            .padding(13)
            .background(
                identityScope == scope
                    ? NoctCordTheme.mutedCoral.opacity(0.09)
                    : NoctCordTheme.surface,
                in: RoundedRectangle(cornerRadius: 17, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 17, style: .continuous)
                    .stroke(
                        identityScope == scope
                            ? NoctCordTheme.mutedCoral.opacity(0.48)
                            : NoctCordTheme.border
                    )
            }
            .contentShape(RoundedRectangle(cornerRadius: 17, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var errorView: some View {
        if let errorMessage {
            Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(NoctCordTheme.warning)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func reviewInvitation() {
        do {
            invitation = try NoctCordCommunityInvitationV1.decode(invitationCode)
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func prepareRequest(_ invitation: NoctCordCommunityInvitationV1) {
        isWorking = true
        errorMessage = nil
        Task {
            do {
                let prepared = try await model.prepareCommunityAdmission(
                    invitationCode: try invitation.encoded(),
                    identityScope: identityScope
                )
                requestCode = prepared.requestCode
                NoctCordClipboard.copy(prepared.requestCode)
            } catch {
                errorMessage = error.localizedDescription
            }
            isWorking = false
        }
    }

    private func acceptResponse() {
        isWorking = true
        errorMessage = nil
        Task {
            do {
                _ = try await model.acceptCommunityAdmissionResponse(responseCode)
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
                isWorking = false
            }
        }
    }

    private func relayLabel(_ endpoint: RelayEndpoint) -> String {
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
}

struct NoctCordInvitationExchangeSheet: View {
    @ObservedObject var model: NoctCordAppModel
    @Environment(\.dismiss) private var dismiss
    @State private var invitationCode = ""
    @State private var requestCode = ""
    @State private var responseCode = ""
    @State private var lifetime: Double = 60
    @State private var isWorking = false
    @State private var errorMessage: String?

    var body: some View {
        NoctCordOnboardingShell(
            symbol: "person.2.badge.plus",
            title: "Invite a member",
            subtitle: "Issue one bounded invitation and approve its matching request.",
            step: responseCode.isEmpty ? 1 : 2,
            stepCount: 2,
            close: { dismiss() }
        ) {
            VStack(alignment: .leading, spacing: 16) {
                if invitationCode.isEmpty {
                    invitationCreation
                } else {
                    NoctCordCodeOutput(
                        title: "COMMUNITY INVITATION",
                        value: invitationCode,
                        actionTitle: "Copy invitation"
                    )
                    NoctCordNoticeCard(
                        symbol: "person.crop.circle.badge.checkmark",
                        title: "Approve exactly one request",
                        text: "Ask the recipient to return the join request generated from this invitation. Review it here; importing the request alone never adds a member."
                    )
                    NoctCordCodeEditor(
                        title: "JOIN REQUEST",
                        prompt: "Paste noctweave-group-admission-v1:…",
                        text: $requestCode,
                        minimumHeight: 120
                    )
                    if !responseCode.isEmpty {
                        NoctCordCodeOutput(
                            title: "SIGNED ACCEPTANCE",
                            value: responseCode,
                            actionTitle: "Copy acceptance"
                        )
                    }
                    errorView
                    HStack {
                        Button("Done") { dismiss() }
                            .buttonStyle(NoctCordSecondaryButtonStyle())
                        Spacer()
                        if responseCode.isEmpty {
                            Button(isWorking ? "Approving…" : "Approve member") {
                                approveRequest()
                            }
                            .buttonStyle(NoctCordPrimaryButtonStyle())
                            .disabled(
                                isWorking
                                    || requestCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            )
                        }
                    }
                }
            }
        }
    }

    private var invitationCreation: some View {
        VStack(alignment: .leading, spacing: 16) {
            NoctCordNoticeCard(
                symbol: "hourglass.circle.fill",
                title: "Short-lived by default",
                text: "The invitation identifies this encrypted group and its relay, but contains no relay password or membership key. Share it privately."
            )
            VStack(alignment: .leading, spacing: 9) {
                HStack {
                    Text("INVITATION LIFETIME")
                        .font(.system(size: 10, weight: .bold))
                        .tracking(0.8)
                    Spacer()
                    Text("\(Int(lifetime)) min")
                        .font(.system(size: 11, weight: .semibold))
                }
                .foregroundStyle(NoctCordTheme.secondaryText)
                Slider(value: $lifetime, in: 10...360, step: 10)
            }
            .padding(15)
            .background(NoctCordTheme.surface, in: RoundedRectangle(cornerRadius: 17))
            .overlay { RoundedRectangle(cornerRadius: 17).stroke(NoctCordTheme.border) }
            errorView
            HStack {
                Button("Cancel") { dismiss() }
                    .buttonStyle(NoctCordSecondaryButtonStyle())
                Spacer()
                Button(isWorking ? "Creating…" : "Create invitation") {
                    createInvitation()
                }
                .buttonStyle(NoctCordPrimaryButtonStyle())
                .disabled(isWorking)
            }
        }
    }

    @ViewBuilder
    private var errorView: some View {
        if let errorMessage {
            Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(NoctCordTheme.warning)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func createInvitation() {
        isWorking = true
        errorMessage = nil
        Task {
            do {
                invitationCode = try await model.makeCommunityInvitation(
                    lifetime: lifetime * 60
                )
                NoctCordClipboard.copy(invitationCode)
            } catch {
                errorMessage = error.localizedDescription
            }
            isWorking = false
        }
    }

    private func approveRequest() {
        isWorking = true
        errorMessage = nil
        Task {
            do {
                responseCode = try await model.approveCommunityAdmissionRequest(requestCode)
                NoctCordClipboard.copy(responseCode)
            } catch {
                errorMessage = error.localizedDescription
            }
            isWorking = false
        }
    }
}

private struct NoctCordOnboardingShell<Content: View>: View {
    let symbol: String
    let title: String
    let subtitle: String
    let step: Int
    let stepCount: Int
    let close: () -> Void
    @ViewBuilder let content: Content

    init(
        symbol: String,
        title: String,
        subtitle: String,
        step: Int,
        stepCount: Int,
        close: @escaping () -> Void,
        @ViewBuilder content: () -> Content
    ) {
        self.symbol = symbol
        self.title = title
        self.subtitle = subtitle
        self.step = step
        self.stepCount = stepCount
        self.close = close
        self.content = content()
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 13) {
                Image(systemName: symbol)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(NoctCordTheme.mutedCoral)
                    .frame(width: 42, height: 42)
                    .background(
                        NoctCordTheme.mutedCoral.opacity(0.12),
                        in: RoundedRectangle(cornerRadius: 14, style: .continuous)
                    )
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.system(size: 20, weight: .bold, design: .rounded))
                    Text(subtitle)
                        .font(.system(size: 10.5))
                        .foregroundStyle(NoctCordTheme.secondaryText)
                }
                Spacer()
                HStack(spacing: 6) {
                    ForEach(1...stepCount, id: \.self) { index in
                        Capsule()
                            .fill(
                                index <= step
                                    ? NoctCordTheme.mutedCoral
                                    : NoctCordTheme.secondaryText.opacity(0.22)
                            )
                            .frame(width: index == step ? 22 : 7, height: 7)
                    }
                }
                Button(action: close) {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .bold))
                        .frame(width: 32, height: 32)
                        .background(NoctCordTheme.surface, in: Circle())
                }
                .buttonStyle(.plain)
            }
            .padding(22)

            Rectangle().fill(NoctCordTheme.border).frame(height: 1)

            ScrollView {
                content
                    .padding(22)
            }
        }
        .foregroundStyle(NoctCordTheme.primaryText)
        .background(
            LinearGradient(
                colors: [NoctCordTheme.canvas, NoctCordTheme.mutedCoral.opacity(0.045)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
        #if os(macOS)
        .frame(width: 650, height: 720)
        #else
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        #endif
    }
}

private struct NoctCordNoticeCard: View {
    let symbol: String
    let title: String
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(NoctCordTheme.mutedCoral)
                .frame(width: 34, height: 34)
                .background(NoctCordTheme.mutedCoral.opacity(0.10), in: Circle())
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 12, weight: .semibold))
                Text(text)
                    .font(.system(size: 10.5))
                    .foregroundStyle(NoctCordTheme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(NoctCordTheme.surface, in: RoundedRectangle(cornerRadius: 17))
        .overlay { RoundedRectangle(cornerRadius: 17).stroke(NoctCordTheme.border) }
    }
}

private struct NoctCordCodeEditor: View {
    let title: String
    let prompt: String
    @Binding var text: String
    let minimumHeight: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title)
                    .font(.system(size: 10, weight: .bold))
                    .tracking(0.8)
                    .foregroundStyle(NoctCordTheme.secondaryText)
                Spacer()
                Button("Paste") {
                    if let value = NoctCordClipboard.read() { text = value }
                }
                .buttonStyle(.plain)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(NoctCordTheme.mutedCoral)
            }
            ZStack(alignment: .topLeading) {
                if text.isEmpty {
                    Text(prompt)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(NoctCordTheme.secondaryText.opacity(0.66))
                        .padding(.horizontal, 13)
                        .padding(.vertical, 12)
                        .allowsHitTesting(false)
                }
                TextEditor(text: $text)
                    .font(.system(size: 10.5, design: .monospaced))
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .frame(minHeight: minimumHeight)
            }
            .background(NoctCordTheme.input, in: RoundedRectangle(cornerRadius: 15))
            .overlay { RoundedRectangle(cornerRadius: 15).stroke(NoctCordTheme.border) }
        }
    }
}

private struct NoctCordCodeOutput: View {
    let title: String
    let value: String
    let actionTitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(title)
                    .font(.system(size: 10, weight: .bold))
                    .tracking(0.8)
                    .foregroundStyle(NoctCordTheme.secondaryText)
                Spacer()
                Text("\(value.count) characters")
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundStyle(NoctCordTheme.secondaryText)
            }
            Text(value)
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundStyle(NoctCordTheme.secondaryText)
                .lineLimit(4)
                .textSelection(.enabled)
                .padding(13)
                .frame(maxWidth: .infinity, minHeight: 82, alignment: .topLeading)
                .background(NoctCordTheme.input, in: RoundedRectangle(cornerRadius: 15))
                .overlay { RoundedRectangle(cornerRadius: 15).stroke(NoctCordTheme.border) }
            HStack(spacing: 10) {
                Button(actionTitle) { NoctCordClipboard.copy(value) }
                    .buttonStyle(NoctCordPrimaryButtonStyle())
                ShareLink(item: value) {
                    Label("Share", systemImage: "square.and.arrow.up")
                }
                .buttonStyle(NoctCordSecondaryButtonStyle())
            }
        }
    }
}

private enum NoctCordClipboard {
    static func copy(_ value: String) {
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
        #elseif os(iOS)
        UIPasteboard.general.string = value
        #endif
    }

    static func read() -> String? {
        #if os(macOS)
        NSPasteboard.general.string(forType: .string)
        #elseif os(iOS)
        UIPasteboard.general.string
        #else
        nil
        #endif
    }
}
