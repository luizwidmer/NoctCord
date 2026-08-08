import SwiftUI
import NoctCordCore

public struct NoctCordRootView: View {
    @StateObject private var model: NoctCordAppModel

    public init(seedPreviewData: Bool = true) {
        _model = StateObject(
            wrappedValue: NoctCordAppModel(seedPreviewData: seedPreviewData)
        )
    }

    public var body: some View {
        GeometryReader { proxy in
            let compact = proxy.size.width < 1_120
            HStack(spacing: 0) {
                NoctCordSpaceRail(model: model)
                NoctCordChannelSidebar(model: model)

                if model.selectedSpace != nil, model.selectedChannel != nil {
                    VStack(spacing: 0) {
                        NoctCordConversationHeader(model: model, compact: compact)
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
        .sheet(isPresented: $model.showsIdentity) {
            IdentitySettingsSheet(model: model)
        }
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
