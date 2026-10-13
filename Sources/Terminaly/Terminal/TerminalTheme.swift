import AppKit
import SwiftTerm
import SwiftUI

/// Terminal color scheme: background, foreground, cursor and the 16 ANSI colors.
struct TerminalTheme: Identifiable, Hashable {
    let id: String
    let name: String
    let background: UInt32
    let foreground: UInt32
    let cursor: UInt32
    /// 8 normal + 8 bright ANSI colors.
    let ansi: [UInt32]

    static let all: [TerminalTheme] = [graphite, dracula, solarizedDark, nord, tokyoNight, oneDark]

    static let graphite = TerminalTheme(
        id: "graphite", name: "Graphite", background: 0x0F1013, foreground: 0xD4D4DC, cursor: 0x2DD4BF,
        ansi: [0x1C1D22, 0xFF6B6B, 0x3DD68C, 0xFFB020, 0x4C8DFF, 0xB48CFF, 0x3CC8D8, 0xD4D4DC,
               0x5C5E66, 0xFF8787, 0x6EE7A8, 0xFFC857, 0x7AA7FF, 0xC9A7FF, 0x67E1EE, 0xF4F4F8])
    static let dracula = TerminalTheme(
        id: "dracula", name: "Dracula", background: 0x282A36, foreground: 0xF8F8F2, cursor: 0xF8F8F2,
        ansi: [0x21222C, 0xFF5555, 0x50FA7B, 0xF1FA8C, 0xBD93F9, 0xFF79C6, 0x8BE9FD, 0xF8F8F2,
               0x6272A4, 0xFF6E6E, 0x69FF94, 0xFFFFA5, 0xD6ACFF, 0xFF92DF, 0xA4FFFF, 0xFFFFFF])
    static let solarizedDark = TerminalTheme(
        id: "solarized-dark", name: "Solarized Dark", background: 0x002B36, foreground: 0x839496, cursor: 0x93A1A1,
        ansi: [0x073642, 0xDC322F, 0x859900, 0xB58900, 0x268BD2, 0xD33682, 0x2AA198, 0xEEE8D5,
               0x002B36, 0xCB4B16, 0x586E75, 0x657B83, 0x839496, 0x6C71C4, 0x93A1A1, 0xFDF6E3])
    static let nord = TerminalTheme(
        id: "nord", name: "Nord", background: 0x2E3440, foreground: 0xD8DEE9, cursor: 0xD8DEE9,
        ansi: [0x3B4252, 0xBF616A, 0xA3BE8C, 0xEBCB8B, 0x81A1C1, 0xB48EAD, 0x88C0D0, 0xE5E9F0,
               0x4C566A, 0xBF616A, 0xA3BE8C, 0xEBCB8B, 0x81A1C1, 0xB48EAD, 0x8FBCBB, 0xECEFF4])
    static let tokyoNight = TerminalTheme(
        id: "tokyo-night", name: "Tokyo Night", background: 0x1A1B26, foreground: 0xC0CAF5, cursor: 0xC0CAF5,
        ansi: [0x15161E, 0xF7768E, 0x9ECE6A, 0xE0AF68, 0x7AA2F7, 0xBB9AF7, 0x7DCFFF, 0xA9B1D6,
               0x414868, 0xF7768E, 0x9ECE6A, 0xE0AF68, 0x7AA2F7, 0xBB9AF7, 0x7DCFFF, 0xC0CAF5])
    static let oneDark = TerminalTheme(
        id: "one-dark", name: "One Dark", background: 0x282C34, foreground: 0xABB2BF, cursor: 0x528BFF,
        ansi: [0x282C34, 0xE06C75, 0x98C379, 0xE5C07B, 0x61AFEF, 0xC678DD, 0x56B6C2, 0xABB2BF,
               0x5C6370, 0xE06C75, 0x98C379, 0xE5C07B, 0x61AFEF, 0xC678DD, 0x56B6C2, 0xFFFFFF])

    static func named(_ id: String) -> TerminalTheme { all.first { $0.id == id } ?? graphite }

    static var current: TerminalTheme { named(UserDefaults.standard.string(forKey: "terminalTheme") ?? "graphite") }

    var backgroundColor: SwiftUI.Color { SwiftUI.Color(hex: background) }

    static func ns(_ hex: UInt32) -> NSColor {
        NSColor(srgbRed: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255,
                blue: CGFloat(hex & 0xff) / 255, alpha: 1)
    }

    /// Applies colors to a SwiftTerm view.
    func apply(to view: TerminalView) {
        view.installColors(ansi.map {
            SwiftTerm.Color(red8: UInt16(($0 >> 16) & 0xff), green8: UInt16(($0 >> 8) & 0xff), blue8: UInt16($0 & 0xff))
        })
        view.nativeBackgroundColor = Self.ns(background)
        view.nativeForegroundColor = Self.ns(foreground)
        view.caretColor = Self.ns(cursor)
    }
}

enum TerminalFont {
    /// Installed fixed-pitch families, for the font picker.
    static var families: [String] {
        NSFontManager.shared.availableFontFamilies.filter { family in
            NSFont(name: family, size: 13)?.isFixedPitch ?? false
                || NSFontManager.shared.font(withFamily: family, traits: [], weight: 5, size: 13)?.isFixedPitch ?? false
        }
    }

    /// "" means the system monospaced font (SF Mono).
    static func make(family: String, size: CGFloat) -> NSFont {
        if !family.isEmpty, let f = NSFontManager.shared.font(withFamily: family, traits: [], weight: 5, size: size) {
            return f
        }
        return NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
    }
}
