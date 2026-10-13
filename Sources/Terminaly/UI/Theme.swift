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
