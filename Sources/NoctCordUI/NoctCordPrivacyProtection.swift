import SwiftUI

#if os(macOS)
import AppKit

struct NoctCordWindowCaptureProtection: NSViewRepresentable {
    let blocked: Bool

    func makeNSView(context: Context) -> CaptureProtectionView {
        let view = CaptureProtectionView()
        view.blocked = blocked
        return view
    }

    func updateNSView(_ nsView: CaptureProtectionView, context: Context) {
        nsView.blocked = blocked
        nsView.applyProtection()
    }

    final class CaptureProtectionView: NSView {
        var blocked = false

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            applyProtection()
        }

        func applyProtection() {
            window?.sharingType = blocked ? .none : .readOnly
        }
    }
}
#else
struct NoctCordWindowCaptureProtection: View {
    let blocked: Bool

    var body: some View {
        EmptyView()
    }
}
#endif

struct NoctCordPrivacyShield: View {
    var body: some View {
        ZStack {
            NoctCordTheme.canvas
                .ignoresSafeArea()

            VStack(spacing: 14) {
                Image(systemName: "lock.shield.fill")
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundStyle(NoctCordTheme.mutedCoral)
                    .frame(width: 62, height: 62)
                    .background(
                        NoctCordTheme.mutedCoral.opacity(0.12),
                        in: RoundedRectangle(cornerRadius: 20, style: .continuous)
                    )
                Text("Noct Cord is hidden")
                    .font(.system(size: 20, weight: .bold, design: .rounded))
                Text("Return to the app to reveal encrypted content.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(NoctCordTheme.secondaryText)
                    .multilineTextAlignment(.center)
            }
            .padding(30)
            .background(
                NoctCordTheme.surface,
                in: RoundedRectangle(cornerRadius: 24, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .stroke(NoctCordTheme.border)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Noct Cord content hidden while the app is unfocused")
    }
}
