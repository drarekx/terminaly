import AppKit
import SwiftUI

/// Status bar icon: shows how many sessions need input and answers permission requests
/// without the main window.
///
/// NSStatusItem + NSPopover rather than `MenuBarExtra`: the item has to be created and removed
/// at runtime (setting toggle, never in self-test or snapshot mode) and must outlive the main
/// window, which is simpler to guarantee when AppKit owns it.
@MainActor
final class MenuBarItem: NSObject {
    static let shared = MenuBarItem()
    static let defaultsKey = "showMenuBarIcon"

    private var item: NSStatusItem?
    private var shownCount = -1
    private var defaultsObserver: NSObjectProtocol?
    private lazy var popover: NSPopover = {
        let p = NSPopover()
        p.behavior = .transient
        p.appearance = NSAppearance(named: .darkAqua)
        let host = NSHostingController(rootView: MenuBarPopoverView().environment(AppStore.shared))
        host.sizingOptions = .preferredContentSize
        p.contentViewController = host
        return p
    }()

    var isInstalled: Bool { item != nil }

    static var enabled: Bool { UserDefaults.standard.object(forKey: defaultsKey) as? Bool ?? true }

    /// Called once at launch outside self-test and snapshot mode; follows the setting live.
    func start() {
        apply()
        defaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main
        ) { _ in MainActor.assumeIsolated { MenuBarItem.shared.apply() } }
    }

    private func apply() {
        if Self.enabled { install() } else { uninstall() }
    }

    private func install() {
        guard item == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.target = self
        item.button?.action = #selector(toggle(_:))
        item.button?.imagePosition = .imageLeading
        self.item = item
        shownCount = -1
        observe()
    }

    private func uninstall() {
        guard let item else { return }
        popover.performClose(nil)
        NSStatusBar.system.removeStatusItem(item)
        self.item = nil
    }

    /// Re-arms itself after every change to the sessions while the item exists.
    private func observe() {
        guard item != nil else { return }
        withObservationTracking {
            updateButton()
        } onChange: {
            DispatchQueue.main.async { MenuBarItem.shared.observe() }
        }
    }

    private func updateButton() {
        let count = AppStore.shared.needingInput.count
        guard count != shownCount, let button = item?.button else { return }
        shownCount = count
        let image = NSImage(systemSymbolName: count > 0 ? "terminal.fill" : "terminal", accessibilityDescription: nil)
        image?.isTemplate = true
        button.image = image
        button.title = count > 0 ? " \(count)" : ""
        button.setAccessibilityLabel(count > 0
            ? String(localized: "Terminaly: \(count) sessions need input")
            : String(localized: "Terminaly"))
    }

    @objc private func toggle(_ sender: NSStatusBarButton) {
        if popover.isShown {
            popover.performClose(sender)
        } else {
            popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    func close() { popover.performClose(nil) }

}

extension AppStore {
    /// Live sessions waiting on the user, longest waiting first.
    var needingInput: [Session] {
        sessions.filter { !$0.archived && $0.status == .needsInput }.sorted { $0.statusChangedAt < $1.statusChangedAt }
    }
}

struct MenuBarPopoverView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let waiting = store.needingInput
        PopoverMenu(width: 320) {
            MenuSectionLabel(title: "Needs input")
            if waiting.isEmpty {
                Text("No session needs input")
                    .font(Theme.Font.body)
                    .foregroundStyle(Theme.secondaryText)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
            } else {
                ForEach(waiting) { s in
                    MenuBarSessionRow(session: s, project: store.project(s.projectID)?.name ?? "") { open(s.id) }
                }
            }
            MenuDivider()
            summary
            MenuDivider()
            MenuRow(title: "Open Terminaly", icon: "macwindow") { openMain() }
            MenuRow(title: "Quit Terminaly", icon: "power") { NSApp.terminate(nil) }
        }
        .environment(\.workspaceAccent, store.accent.color)
        .tint(store.accent.color)
    }

    private var summary: some View {
        let live = store.sessions.filter { !$0.archived }
        return HStack(spacing: 16) {
            ForEach([SessionStatus.working, .idle], id: \.self) { status in
                HStack(spacing: 6) {
                    Circle().fill(status.dot).frame(width: 8, height: 8)
                    Text(verbatim: "\(live.filter { $0.status == status }.count)")
                        .font(Theme.Font.bodyStrong)
                        .foregroundStyle(Theme.text)
                    Text(status.label)
                        .font(Theme.Font.body)
                        .foregroundStyle(Theme.secondaryText)
                }
            }
            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    private func openMain() {
        MenuBarItem.shared.close()
        NSApp.activate()
        // Brings the window to the front, or recreates it after it was closed.
        openWindow(id: "main")
    }

    private func open(_ id: UUID) {
        openMain()
        // Let the window come back before the store points a pane at the session.
        DispatchQueue.main.async { store.show(id) }
    }
}

private struct MenuBarSessionRow: View {
    @Environment(AppStore.self) private var store
    @Environment(\.workspaceAccent) private var accent
    let session: Session
    let project: String
    let open: () -> Void
    @State private var hovering = false

    /// Same wording as the permission bar under the terminal.
    private var detail: String? {
        guard let d = session.attentionDetail, !d.isEmpty else { return nil }
        if d.hasPrefix("Permission: ") { return String(localized: "Wants to use \(String(d.dropFirst(12)))") }
        return d
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button(action: open) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Circle().fill(session.status.dot).frame(width: 8, height: 8)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(session.title)
                                .font(Theme.Font.bodyMedium)
                                .foregroundStyle(Theme.text)
                                .lineLimit(1)
                            Spacer(minLength: 8)
                            Text(project)
                                .font(Theme.Font.caption)
                                .foregroundStyle(Theme.tertiaryText)
                                .lineLimit(1)
                        }
                        if let detail {
                            Text(detail)
                                .font(Theme.Font.caption)
                                .foregroundStyle(Theme.secondaryText)
                                .lineLimit(2)
                        }
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Open in Terminaly")
            if session.permissionPending {
                HStack(spacing: 8) {
                    Spacer()
                    Button("Deny") { store.respondToPermission(session.id, allow: false) }
                        .buttonStyle(SecondaryButtonStyle(compact: true, destructive: true))
                        .help("Sends Esc to the dialog")
                    Button("Allow") { store.respondToPermission(session.id, allow: true) }
                        .buttonStyle(PrimaryButtonStyle(compact: true))
                        .help("Sends Enter: accepts the highlighted option")
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 7).fill(hovering ? accent.opacity(0.18) : .clear))
        .onHover { hovering = $0 }
    }
}

extension MenuBarItem {
    /// Snapshot mode: the status bar can't be captured, so render the popover content with
    /// made-up statuses (runtime only, never saved) on the first sessions.
    static func renderPreview(to url: URL) {
        let store = AppStore.shared
        let live = store.sessions.indices.filter { !store.sessions[$0].archived }
        let fake: [(SessionStatus, Bool, String?)] = [
            (.needsInput, true, "Permission: Bash"), (.needsInput, false, "Claude is waiting for your input"),
            (.working, false, nil), (.working, false, nil), (.idle, false, nil),
        ]
        for (i, f) in zip(live, fake) {
            store.sessions[i].status = f.0
            store.sessions[i].permissionPending = f.1
            store.sessions[i].attentionDetail = f.2
        }
        let view = MenuBarPopoverView()
            .padding(12)
            .background(Theme.elevated)
            .environment(store)
            .environment(\.colorScheme, .dark)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        if let image = renderer.nsImage, let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) {
            try? rep.representation(using: .png, properties: [:])?.write(to: url)
        }
    }
}
