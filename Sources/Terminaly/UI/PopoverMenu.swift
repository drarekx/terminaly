import SwiftUI

/// Spacious replacement for native menus on the most used actions: 34 pt rows, icon,
/// 13 pt text and right-aligned shortcut. Right-click context menus stay native.
struct PopoverMenu<Content: View>: View {
    var width: CGFloat = 260
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            content()
        }
        .padding(6)
        .frame(width: width)
        .preferredColorScheme(.dark)
    }
}

/// A button that opens a `PopoverMenu` below itself.
struct PopoverMenuButton<Label: View, Content: View>: View {
    @Environment(\.workspaceAccent) private var inheritedAccent
    var arrowEdge: Edge = .bottom
    var width: CGFloat = 260
    var accent: Color? = nil
    @ViewBuilder let label: () -> Label
    @ViewBuilder let content: () -> Content
    @State private var open = false

    var body: some View {
        Button { open.toggle() } label: { label() }
            .popover(isPresented: $open, arrowEdge: arrowEdge) {
                PopoverMenu(width: width, content: content)
                    .environment(\.workspaceAccent, accent ?? inheritedAccent)
            }
    }
}

struct MenuRow: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.workspaceAccent) private var accent
    @Environment(\.isEnabled) private var enabled
    let title: String
    var icon: String? = nil
    var subtitle: String? = nil
    var shortcut: String? = nil
    var destructive = false
    var checked = false
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button {
            dismiss()
            // Let the popover close first so alerts and panels the action opens aren't nested in it.
            DispatchQueue.main.async(execute: action)
        } label: {
            HStack(spacing: 10) {
                if let icon {
                    Image(systemName: icon)
                        .font(.system(size: 13, weight: .medium))
                        .frame(width: 18)
                        .foregroundStyle(destructive ? Color(hex: 0xFF6B6B) : hovering ? Theme.text : Theme.secondaryText)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(Theme.Font.body)
                        .foregroundStyle(destructive ? Color(hex: 0xFF6B6B) : Theme.text)
                    if let subtitle {
                        Text(subtitle).font(Theme.Font.mono).foregroundStyle(Theme.tertiaryText).lineLimit(1)
                    }
                }
                Spacer(minLength: 12)
                if checked {
                    Image(systemName: "checkmark").font(.system(size: 12, weight: .bold)).foregroundStyle(accent)
                }
                if let shortcut {
                    Text(shortcut).font(Theme.Font.caption).foregroundStyle(Theme.tertiaryText)
                }
            }
            .padding(.horizontal, 10)
            .frame(minHeight: subtitle == nil ? 34 : 44)
            .background(RoundedRectangle(cornerRadius: 7)
                .fill(hovering && enabled ? (destructive ? Color(hex: 0xFF6B6B, opacity: 0.16) : accent.opacity(0.28)) : .clear))
            .contentShape(RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
        .opacity(enabled ? 1 : 0.4)
        .onHover { hovering = $0 }
    }
}

struct MenuDivider: View {
    var body: some View {
        Rectangle().fill(Theme.hairline).frame(height: 1).padding(.vertical, 5).padding(.horizontal, 6)
    }
}

struct MenuSectionLabel: View {
    let title: String
    var body: some View {
        Text(title.uppercased())
            .font(.system(size: 11, weight: .semibold))
            .tracking(0.5)
            .foregroundStyle(Theme.tertiaryText)
            .padding(.horizontal, 10)
            .padding(.top, 6)
            .padding(.bottom, 2)
    }
}

/// Row of color swatches inside a popover menu.
struct ColorSwatchRow: View {
    let selected: FolderColor
    let pick: (FolderColor) -> Void

    var body: some View {
        HStack(spacing: 8) {
            ForEach(FolderColor.allCases, id: \.self) { c in
                Button { pick(c) } label: {
                    Circle().fill(c.color)
                        .frame(width: 22, height: 22)
                        .overlay(Circle().strokeBorder(.white, lineWidth: c == selected ? 2 : 0))
                        .padding(2)
                }
                .buttonStyle(.plain)
                .help(c.rawValue.capitalized)
                .accessibilityLabel(c.rawValue.capitalized)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }
}

/// Grid of SF Symbols inside a popover menu.
struct SymbolGrid: View {
    @Environment(\.workspaceAccent) private var accent
    let symbols: [String]
    let selected: String
    let pick: (String) -> Void

    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.fixed(32), spacing: 6), count: 6), spacing: 6) {
            ForEach(symbols, id: \.self) { s in
                Button { pick(s) } label: {
                    Image(systemName: s)
                        .font(.system(size: 13, weight: .semibold))
                        .frame(width: 32, height: 32)
                        .background(RoundedRectangle(cornerRadius: 7)
                            .fill(s == selected ? accent.opacity(0.4) : Color.white.opacity(0.06)))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(s)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }
}
