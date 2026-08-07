import SwiftUI

#if os(macOS)
import AppKit
#else
import UIKit
#endif

public enum NoctCordAppearance: String, CaseIterable, Identifiable, Sendable {
    case system
    case light
    case dark

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }

    public var symbol: String {
        switch self {
        case .system: "circle.lefthalf.filled"
        case .light: "sun.max"
        case .dark: "moon"
        }
    }

    public var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

public enum NoctCordTheme {
    public static let warmIvory = Color(red: 250 / 255, green: 243 / 255, blue: 234 / 255)
    public static let paleSand = Color(red: 235 / 255, green: 199 / 255, blue: 175 / 255)
    public static let mutedCoral = Color(red: 201 / 255, green: 106 / 255, blue: 97 / 255)
    public static let deepWine = Color(red: 146 / 255, green: 45 / 255, blue: 53 / 255)
    public static let plumBlack = Color(red: 27 / 255, green: 18 / 255, blue: 23 / 255)
    public static let success = Color(red: 121 / 255, green: 198 / 255, blue: 163 / 255)
    public static let warning = Color(red: 232 / 255, green: 171 / 255, blue: 96 / 255)

    public static let canvas = adaptive(
        light: platformColor(red: 0.976, green: 0.957, blue: 0.941, alpha: 1),
        dark: platformColor(red: 0.071, green: 0.043, blue: 0.059, alpha: 1)
    )
    public static let rail = adaptive(
        light: platformColor(red: 0.945, green: 0.906, blue: 0.886, alpha: 1),
        dark: platformColor(red: 0.082, green: 0.051, blue: 0.067, alpha: 1)
    )
    public static let navigation = adaptive(
        light: platformColor(red: 0.965, green: 0.933, blue: 0.918, alpha: 0.98),
        dark: platformColor(red: 0.098, green: 0.063, blue: 0.078, alpha: 0.98)
    )
    public static let surface = adaptive(
        light: platformColor(red: 0.992, green: 0.976, blue: 0.965, alpha: 0.98),
        dark: platformColor(red: 0.133, green: 0.086, blue: 0.106, alpha: 0.98)
    )
    public static let elevated = adaptive(
        light: platformColor(red: 1, green: 0.992, blue: 0.984, alpha: 1),
        dark: platformColor(red: 0.169, green: 0.110, blue: 0.129, alpha: 1)
    )
    public static let input = adaptive(
        light: platformColor(red: 0.957, green: 0.922, blue: 0.906, alpha: 1),
        dark: platformColor(red: 0.094, green: 0.059, blue: 0.075, alpha: 1)
    )
    public static let border = adaptive(
        light: platformColor(red: 0.55, green: 0.42, blue: 0.44, alpha: 0.16),
        dark: platformColor(red: 0.90, green: 0.68, blue: 0.66, alpha: 0.12)
    )
    public static let primaryText = adaptive(
        light: platformColor(red: 0.15, green: 0.10, blue: 0.12, alpha: 1),
        dark: platformColor(red: 0.98, green: 0.95, blue: 0.92, alpha: 1)
    )
    public static let secondaryText = adaptive(
        light: platformColor(red: 0.40, green: 0.33, blue: 0.35, alpha: 1),
        dark: platformColor(red: 0.73, green: 0.65, blue: 0.67, alpha: 1)
    )
    public static let shadow = adaptive(
        light: platformColor(red: 0.24, green: 0.12, blue: 0.16, alpha: 0.14),
        dark: platformColor(red: 0, green: 0, blue: 0, alpha: 0.32)
    )

    #if os(macOS)
    private static func platformColor(
        red: CGFloat,
        green: CGFloat,
        blue: CGFloat,
        alpha: CGFloat
    ) -> NSColor {
        NSColor(srgbRed: red, green: green, blue: blue, alpha: alpha)
    }

    private static func adaptive(light: NSColor, dark: NSColor) -> Color {
        Color(
            nsColor: NSColor(name: nil) { appearance in
                appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                    ? dark
                    : light
            }
        )
    }
    #else
    private static func platformColor(
        red: CGFloat,
        green: CGFloat,
        blue: CGFloat,
        alpha: CGFloat
    ) -> UIColor {
        UIColor(red: red, green: green, blue: blue, alpha: alpha)
    }

    private static func adaptive(light: UIColor, dark: UIColor) -> Color {
        Color(uiColor: UIColor { traits in
            traits.userInterfaceStyle == .dark ? dark : light
        })
    }
    #endif
}

public struct NoctCordMark: View {
    public init() {}

    public var body: some View {
        GeometryReader { proxy in
            let side = min(proxy.size.width, proxy.size.height)
            ZStack {
                RoundedRectangle(cornerRadius: side * 0.28, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [NoctCordTheme.deepWine, NoctCordTheme.mutedCoral],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )

                ForEach(0..<3, id: \.self) { index in
                    RoundedRectangle(cornerRadius: side * 0.12, style: .continuous)
                        .stroke(
                            index == 1 ? NoctCordTheme.warmIvory : NoctCordTheme.paleSand,
                            style: StrokeStyle(
                                lineWidth: side * 0.075,
                                lineCap: .round,
                                lineJoin: .round
                            )
                        )
                        .frame(width: side * 0.49, height: side * 0.20)
                        .rotationEffect(.degrees(-18))
                        .offset(x: CGFloat(index - 1) * side * 0.105)
                }
            }
            .shadow(color: NoctCordTheme.deepWine.opacity(0.25), radius: side * 0.12, y: side * 0.06)
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityLabel("Noct Cord")
    }
}

public struct NoctCordPanelModifier: ViewModifier {
    let radius: CGFloat
    let elevated: Bool

    public func body(content: Content) -> some View {
        content
            .background(elevated ? NoctCordTheme.elevated : NoctCordTheme.surface)
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .stroke(NoctCordTheme.border, lineWidth: 1)
            }
            .shadow(
                color: elevated ? NoctCordTheme.shadow : .clear,
                radius: elevated ? 18 : 0,
                y: elevated ? 8 : 0
            )
    }
}

public extension View {
    func noctCordPanel(radius: CGFloat = 18, elevated: Bool = false) -> some View {
        modifier(NoctCordPanelModifier(radius: radius, elevated: elevated))
    }
}
