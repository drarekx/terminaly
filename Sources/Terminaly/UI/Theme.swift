import AppKit
import SwiftUI

/// "Graphite" design tokens. The app is always dark; the workspace color tints the sidebar
/// and marks focus/selection, while status colors are reserved for agents.
enum Theme {
    static let ground = Color(hex: 0x0B0C0E)        // window / content background
    static let pane = Color(hex: 0x0F1013)          // terminal card
    static let paneNS = NSColor(srgbRed: 15 / 255, green: 16 / 255, blue: 19 / 255, alpha: 1)
    static let elevated = Color(hex: 0x1A1B20)      // palette, popovers
    static let text = Color(hex: 0xECECF1)
    static let textNS = NSColor(srgbRed: 212 / 255, green: 212 / 255, blue: 220 / 255, alpha: 1)
    static let hairline = Color.white.opacity(0.07)

    /// Sidebar ground: 20 % of the workspace color over graphite (18, 18, 22).
    static func sidebar(_ color: FolderColor) -> Color {
        let (r, g, b) = color.rgb
        func mix(_ c: Double, _ base: Double) -> Double { (base + (c - base) * 0.2) / 255 }
        return Color(.sRGB, red: mix(r, 18), green: mix(g, 18), blue: mix(b, 22))
    }

    /// Focus ring / selection outline in the workspace color.
    static func ring(_ color: FolderColor) -> Color { color.color.opacity(0.55) }
}

extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xff) / 255,
                  green: Double((hex >> 8) & 0xff) / 255,
                  blue: Double(hex & 0xff) / 255,
                  opacity: opacity)
    }
}

extension FolderColor {
    var displayName: String {
        switch self {
        case .blue: String(localized: "Blue")
        case .purple: String(localized: "Purple")
        case .pink: String(localized: "Pink")
        case .red: String(localized: "Red")
        case .orange: String(localized: "Orange")
        case .yellow: String(localized: "Yellow")
        case .green: String(localized: "Green")
        case .gray: String(localized: "Gray")
        }
    }

    var rgb: (Double, Double, Double) {
        switch self {
        case .blue: (59, 130, 246)
        case .purple: (139, 92, 246)
        case .pink: (236, 72, 153)
        case .red: (239, 68, 68)
        case .orange: (249, 115, 22)
        case .yellow: (234, 179, 8)
        case .green: (34, 197, 94)
        case .gray: (142, 142, 147)
        }
    }
}

extension SessionStatus {
    /// Dot / icon color.
    var dot: Color {
        switch self {
        case .working: Color(hex: 0x4C8DFF)
        case .idle: Color(hex: 0x3DD68C)
        case .needsInput: Color(hex: 0xFFB020)
        case .starting: Color(hex: 0xECECF1, opacity: 0.6)
        case .exited: Color(hex: 0xECECF1, opacity: 0.4)
        }
    }

    /// Readable text color for the status line.
    var text: Color {
        switch self {
        case .working: Color(hex: 0x7AA7FF)
        case .idle: Color(hex: 0x3DD68C)
        case .needsInput: Color(hex: 0xFFB020)
        case .starting: Color(hex: 0xECECF1, opacity: 0.6)
        case .exited: Color(hex: 0xECECF1, opacity: 0.5)
        }
    }

    /// Background of the session's icon tile.
    var tile: Color {
        switch self {
        case .working: Color(hex: 0x4C8DFF, opacity: 0.16)
        case .idle: Color(hex: 0x3DD68C, opacity: 0.16)
        case .needsInput: Color(hex: 0xFFB020, opacity: 0.18)
        case .starting, .exited: Color.white.opacity(0.06)
        }
    }
}

// MARK: Type scale & text levels

extension Theme {
    /// The only sizes the UI uses. 12 pt is the floor for anything people need to read.
    enum Font {
        static let title = SwiftUI.Font.system(size: 17, weight: .bold)
        static let body = SwiftUI.Font.system(size: 13)
        static let bodyMedium = SwiftUI.Font.system(size: 13, weight: .medium)
        static let bodyStrong = SwiftUI.Font.system(size: 13, weight: .semibold)
        static let label = SwiftUI.Font.system(size: 12, weight: .medium)
        static let caption = SwiftUI.Font.system(size: 12)
        static let mono = SwiftUI.Font.system(size: 12, design: .monospaced)
    }

    static let secondaryText = text.opacity(0.72)   // ≥ 7:1 on graphite
    static let tertiaryText = text.opacity(0.56)    // ≥ 4.5:1 on graphite and tinted sidebars
}

// MARK: Workspace accent

extension EnvironmentValues {
    /// Selected workspace color. `Color.accentColor` ignores `.tint`, so styles read this instead.
    @Entry var workspaceAccent: Color = FolderColor.blue.color
}

// MARK: Buttons

/// Filled with the workspace color: the one main action in a place.
struct PrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    @Environment(\.workspaceAccent) private var accent
    var compact = false

    func makeBody(configuration: Configuration) -> some View {
        Hover { hovering in
            configuration.label
                .font(Theme.Font.bodyStrong)
                .foregroundStyle(.white)
                .padding(.horizontal, compact ? 10 : 14)
                .frame(minHeight: compact ? 28 : 32)
                .background(RoundedRectangle(cornerRadius: 8).fill(accent))
                .overlay(RoundedRectangle(cornerRadius: 8).fill(.white.opacity(configuration.isPressed ? 0.0 : hovering ? 0.12 : 0)))
                .overlay(RoundedRectangle(cornerRadius: 8).fill(.black.opacity(configuration.isPressed ? 0.15 : 0)))
                .opacity(enabled ? 1 : 0.45)
                .scaleEffect(configuration.isPressed ? 0.97 : 1)
                .animation(.easeOut(duration: 0.12), value: hovering)
                .animation(.easeOut(duration: 0.08), value: configuration.isPressed)
        }
    }
}

/// Quiet bordered button for secondary actions.
struct SecondaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    var compact = false
    var destructive = false

    func makeBody(configuration: Configuration) -> some View {
        Hover { hovering in
            configuration.label
                .font(Theme.Font.bodyMedium)
                .foregroundStyle(destructive ? Color(hex: 0xFF6B6B) : Theme.text)
                .padding(.horizontal, compact ? 10 : 14)
                .frame(minHeight: compact ? 28 : 32)
                .background(RoundedRectangle(cornerRadius: 8)
                    .fill(Color.white.opacity(configuration.isPressed ? 0.16 : hovering ? 0.12 : 0.07)))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.white.opacity(0.10), lineWidth: 1))
                .opacity(enabled ? 1 : 0.45)
                .scaleEffect(configuration.isPressed ? 0.97 : 1)
                .animation(.easeOut(duration: 0.12), value: hovering)
                .animation(.easeOut(duration: 0.08), value: configuration.isPressed)
        }
    }
}

/// Square icon button with a visible hover plate. Pair with `.help()` for its name.
struct IconButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    var size: CGFloat = 30
    var filled = false

    func makeBody(configuration: Configuration) -> some View {
        Hover { hovering in
            configuration.label
                .font(.system(size: size >= 30 ? 14 : 13, weight: .semibold))
                .foregroundStyle(Theme.text.opacity(hovering || configuration.isPressed ? 1 : 0.8))
                .frame(width: size, height: size)
                .background(RoundedRectangle(cornerRadius: size * 0.26)
                    .fill(Color.white.opacity(configuration.isPressed ? 0.16 : hovering ? 0.10 : filled ? 0.06 : 0)))
                .contentShape(RoundedRectangle(cornerRadius: size * 0.26))
                .opacity(enabled ? 1 : 0.4)
                .animation(.easeOut(duration: 0.12), value: hovering)
        }
    }
}

/// Tracks hover for button styles (ButtonStyle has no hover state of its own).
struct Hover<Content: View>: View {
    @State private var hovering = false
    @ViewBuilder let content: (Bool) -> Content

    var body: some View {
        content(hovering).onHover { hovering = $0 }
    }
}
