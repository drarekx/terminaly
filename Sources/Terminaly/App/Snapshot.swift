import AppKit
import SwiftUI

/// Debug aid: `TERMINALY_SNAPSHOT_DIR=/tmp/x Terminaly` renders the main window into PNGs
/// (one per workspace, max 3) and quits. The app draws its own window, so no screen-recording
/// permission is needed.
@MainActor
enum Snapshot {
    static func runIfRequested() {
        guard let dir = ProcessInfo.processInfo.environment["TERMINALY_SNAPSHOT_DIR"] else { return }
        let url = URL(fileURLWithPath: dir)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        Task {
            try? await Task.sleep(for: .seconds(2.5))
            let store = AppStore.shared
            for i in 0..<min(store.workspaces.count, 3) {
                store.selectWorkspace(at: i)
                try? await Task.sleep(for: .seconds(1.2))
                capture(to: url.appendingPathComponent("workspace-\(i).png"))
            }
            renderMenus(to: url.appendingPathComponent("menus.png"))
            exit(0)
        }
    }

    /// Popovers live in their own windows, so render their content directly.
    private static func renderMenus(to url: URL) {
        let store = AppStore.shared
        guard let ws = store.currentWorkspace else { return }
        let view = HStack(alignment: .top, spacing: 24) {
            PopoverMenu(width: 280) {
                MenuSectionLabel(title: "New session in project")
                ForEach(Array(store.presets.enumerated()), id: \.element.id) { i, p in
                    MenuRow(title: p.label, icon: p.symbol, subtitle: p.command.isEmpty ? "login shell" : p.command,
                            shortcut: i == 0 ? "⌘T" : nil) {}
                }
            }
            PopoverMenu(width: 260) {
                MenuRow(title: "Rename…", icon: "pencil") {}
                MenuDivider()
                MenuSectionLabel(title: "Icon")
                SymbolGrid(symbols: Workspace.symbols, selected: ws.symbol) { _ in }
                MenuSectionLabel(title: "Color")
                ColorSwatchRow(selected: ws.color) { _ in }
                MenuDivider()
                MenuRow(title: "New Workspace", icon: "plus.rectangle.on.rectangle", shortcut: "⇧⌘N") {}
                MenuRow(title: "Delete Workspace", icon: "trash", destructive: true) {}
            }
        }
        .padding(24)
        .background(Theme.elevated)
        .environment(store)
        .environment(\.workspaceAccent, store.accent.color)
        .tint(store.accent.color)
        .environment(\.colorScheme, .dark)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        if let image = renderer.nsImage, let tiff = image.tiffRepresentation,
           let rep = NSBitmapImageRep(data: tiff) {
            try? rep.representation(using: .png, properties: [:])?.write(to: url)
        }
    }

    private static func capture(to url: URL) {
        guard let window = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil }),
              let view = window.contentView?.superview ?? window.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }
}
