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
            // SwiftTerm pauses drawing while its window is occluded: bring it to the front.
            NSApp.activate(ignoringOtherApps: true)
            NSApp.windows.first { $0.isVisible }?.orderFrontRegardless()
            let store = AppStore.shared
            let env = ProcessInfo.processInfo.environment
            // Optional live shell so terminal colors show up in the capture.
            store.selectWorkspace(at: 0)
            if let cmd = env["TERMINALY_SNAPSHOT_SHELL"], let project = store.visibleProjects.first {
                store.closePane()
                store.newSession(preset: Preset(label: "Shell", command: cmd), in: project)
                try? await Task.sleep(for: .seconds(3))
            }
            for i in 0..<min(store.workspaces.count, 3) {
                store.selectWorkspace(at: i)
                try? await Task.sleep(for: .seconds(1.2))
                capture(to: url.appendingPathComponent("workspace-\(i).png"))
            }
            if let pt = env["TERMINALY_CLICK_AT"]?.split(separator: ",").compactMap({ Double($0) }), pt.count == 2,
               let w = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil }) {
                // Simulated click at window-top-left coordinates (points), then report what opened.
                let p = NSPoint(x: pt[0], y: w.contentLayoutRect.maxY - pt[1] + (w.frame.height - w.contentLayoutRect.maxY))
                for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                    if let e = NSEvent.mouseEvent(with: type, location: p, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                  windowNumber: w.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) {
                        w.sendEvent(e)
                    }
                }
                try? await Task.sleep(for: .seconds(1))
                let names = NSApp.windows.filter(\.isVisible).map { String(describing: type(of: $0)) }
                FileHandle.standardError.write(Data("click: windows=\(names) collapsed=\(store.projects.map { "\($0.name)=\($0.collapsed)" })\n".utf8))
                capture(to: url.appendingPathComponent("after-click.png"))
            }
            renderMenus(to: url.appendingPathComponent("menus.png"))
            if env["TERMINALY_SETTINGS_TAB"] != nil {
                // The app menu's "Settings…" (⌘,) item opens the SwiftUI Settings scene.
                if let appMenu = NSApp.mainMenu?.items.first?.submenu,
                   let item = appMenu.items.first(where: { $0.keyEquivalent == "," }),
                   let action = item.action {
                    NSApp.sendAction(action, to: item.target, from: item)
                }
                try? await Task.sleep(for: .seconds(1.5))
                if let w = NSApp.windows.first(where: { $0.isVisible && $0.title != "Terminaly" && $0.contentView != nil }),
                   let v = w.contentView?.superview ?? w.contentView,
                   let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) {
                    v.cacheDisplay(in: v.bounds, to: rep)
                    try? rep.representation(using: .png, properties: [:])?.write(to: url.appendingPathComponent("settings.png"))
                }
            }
            AppStore.shared.terminals.stopAll()
            try? await Task.sleep(for: .milliseconds(300))
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
                    MenuRow(title: "\(p.label)", icon: p.symbol, subtitle: p.command.isEmpty ? String(localized: "login shell") : p.command,
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
        // cacheDisplay skips layer-only paint (SwiftTerm draws its background as layer.backgroundColor):
        // re-composite each terminal as background fill + its own cached drawing.
        if let ctx = NSGraphicsContext(bitmapImageRep: rep) {
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = ctx
            for term in allSubviews(of: view).compactMap({ $0 as? AgentTerminalView }) {
                guard let termRep = term.bitmapImageRepForCachingDisplay(in: term.bounds) else { continue }
                term.cacheDisplay(in: term.bounds, to: termRep)
                var frame = term.convert(term.bounds, to: view)
                if view.isFlipped { frame.origin.y = view.bounds.height - frame.maxY }
                term.nativeBackgroundColor.setFill()
                frame.fill()
                termRep.draw(in: frame, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            }
            NSGraphicsContext.restoreGraphicsState()
        }
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }

    private static func allSubviews(of view: NSView) -> [NSView] {
        view.subviews + view.subviews.flatMap(allSubviews)
    }
}
