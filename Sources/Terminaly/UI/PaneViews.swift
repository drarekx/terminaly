import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Renders the split tree recursively.
struct PaneTreeView: View {
    let node: PaneNode

    var body: some View {
        switch node {
        case .leaf(let id, let sessionID):
            PaneView(leafID: id, sessionID: sessionID)
                .background(Theme.ground)
        case .split(_, let axis, let children):
            if axis == .horizontal {
                HSplitView {
                    ForEach(children) { PaneTreeView(node: $0) }
                }
            } else {
                VSplitView {
                    ForEach(children) { PaneTreeView(node: $0) }
                }
            }
        }
    }
}

struct PaneView: View {
    @Environment(AppStore.self) private var store
    @AppStorage("terminalTheme") private var themeID = "graphite"
    let leafID: UUID
    let sessionID: UUID?
    @State private var hovering = false

    @State private var dropEdge: Edge?? = nil   // nil: not targeted; .some(nil): center
    @State private var size: CGSize = .zero

    private var isFocused: Bool { store.focusedLeafID == leafID }
    private var multiPane: Bool { store.layout.leafIDs.count > 1 }
    private var zoomed: Bool { store.zoomedLeafID == leafID }

    var body: some View {
        VStack(spacing: 0) {
            if multiPane || zoomed || sessionID != nil {
                header
            }
            content
        }
        .background(TerminalTheme.named(themeID).backgroundColor)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(isFocused && multiPane ? Theme.ring(store.accent) : Color.white.opacity(0.06), lineWidth: 1)
                .allowsHitTesting(false)
        }
        .overlay { DropZoneHighlight(edge: dropEdge, accent: store.accent.color) }
        .padding(3)
        .frame(minWidth: 220, minHeight: 120)
        .background(GeometryReader { g in Color.clear.onAppear { size = g.size }.onChange(of: g.size) { _, s in size = s } })
        .onDrop(of: [.utf8PlainText], delegate: SessionDropDelegate(leafID: leafID, size: { size }, edge: $dropEdge, store: store))
        .animation(.easeOut(duration: 0.15), value: isFocused)
        .animation(.easeOut(duration: 0.12), value: dropEdge)
    }

    private var header: some View {
        HStack(spacing: 8) {
            if let s = store.session(sessionID) {
                StatusDot(status: s.status)
                Text(s.title)
                    .font(Theme.Font.bodyStrong)
                    .foregroundStyle(Theme.text.opacity(isFocused ? 1 : 0.82))
                    .lineLimit(1)
                if let p = store.project(s.projectID) {
                    Text(p.name).font(Theme.Font.body).foregroundStyle(Theme.tertiaryText).lineLimit(1)
                }
                if let branch = s.branch {
                    Label(branch, systemImage: "arrow.triangle.branch")
                        .labelStyle(BranchLabelStyle())
                        .font(Theme.Font.caption)
                        .foregroundStyle(Theme.secondaryText)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(RoundedRectangle(cornerRadius: 5).fill(Color.white.opacity(0.06)))
                        .lineLimit(1)
                }
                Spacer()
                if s.status == .needsInput {
                    Text("Needs input")
                        .font(Theme.Font.label)
                        .foregroundStyle(s.status.text)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(RoundedRectangle(cornerRadius: 5).fill(s.status.dot.opacity(0.14)))
                }
            } else {
                Text("Empty pane").font(Theme.Font.body).foregroundStyle(Theme.tertiaryText)
                Spacer()
            }
            Group {
                Button { store.split(.horizontal, leaf: leafID) } label: { Image(systemName: "rectangle.split.2x1") }
                    .help("Split Right")
                    .accessibilityLabel("Split Right")
                Button { store.split(.vertical, leaf: leafID) } label: { Image(systemName: "rectangle.split.1x2") }
                    .help("Split Down")
                    .accessibilityLabel("Split Down")
                if multiPane || zoomed {
                    Button { store.toggleZoom(leafID) } label: {
                        Image(systemName: zoomed ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                    }
                    .help(zoomed ? LocalizedStringKey("Unzoom (⌘↩)") : LocalizedStringKey("Zoom Pane (⌘↩)"))
                    .accessibilityLabel(zoomed ? LocalizedStringKey("Unzoom") : LocalizedStringKey("Zoom Pane"))
                }
                if multiPane {
                    Button { store.closePane(leafID) } label: { Image(systemName: "xmark") }
                        .help("Close Pane (⌘W)")
                        .accessibilityLabel("Close Pane")
                }
            }
            .buttonStyle(IconButtonStyle(size: 26))
            .opacity(hovering || isFocused ? 1 : 0)
        }
        .padding(.leading, 12)
        .padding(.trailing, 4)
        .frame(height: 36)
        .background(Color.white.opacity(isFocused ? 0.035 : 0.02))
        .overlay(alignment: .bottom) { Rectangle().fill(Color.white.opacity(0.05)).frame(height: 1) }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { store.focus(leaf: leafID) }
    }

    @ViewBuilder
    private var content: some View {
        if let s = store.session(sessionID) {
            if let view = store.terminals.view(for: s.id) {
                // Bars sit below the terminal, never over it: the agent's own dialog is on its last lines.
                VStack(spacing: 0) {
                    TerminalContainer(terminal: view) { store.focus(leaf: leafID) }
                        .id(s.id)  // a new container per session, never a reused one
                        .padding(.leading, 10)
                        .padding(.top, 6)
                    if s.status == .exited {
                        ExitedBar(session: s)
                    } else if s.status == .paused {
                        PausedBar(session: s)
                    } else if s.permissionPending {
                        PermissionBar(session: s)
                    }
                }
            } else {
                DeadSessionView(session: s)
            }
        } else {
            EmptyPaneView(leafID: leafID)
        }
    }
}

/// Hosts a long-lived terminal NSView. Reparents it so the process survives SwiftUI view churn.
struct TerminalContainer: NSViewRepresentable {
    let terminal: AgentTerminalView
    let onClick: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onClick: onClick) }

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        // Observes clicks without swallowing them, so clicking a terminal focuses its pane.
        let click = NSClickGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.clicked))
        click.delaysPrimaryMouseButtonEvents = false
        container.addGestureRecognizer(click)
        attach(to: container)
        return container
    }

    final class Coordinator: NSObject {
        var onClick: () -> Void
        init(onClick: @escaping () -> Void) { self.onClick = onClick }
        @objc func clicked() { onClick() }
    }

    func updateNSView(_ container: NSView, context: Context) {
        context.coordinator.onClick = onClick
        if terminal.superview !== container || container.subviews.count != 1 { attach(to: container) }
    }

    /// Makes `terminal` the container's only subview. A reused container could otherwise keep a
    /// previous session's terminal stacked on top, so switching back showed the wrong one.
    private func attach(to container: NSView) {
        for other in container.subviews where other !== terminal { other.removeFromSuperview() }
        terminal.removeFromSuperview()
        terminal.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(terminal)
        NSLayoutConstraint.activate([
            terminal.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            terminal.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            terminal.topAnchor.constraint(equalTo: container.topAnchor),
            terminal.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        terminal.needsDisplay = true
    }
}

private struct ExitedBar: View {
    @Environment(AppStore.self) private var store
    let session: Session

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "stop.circle").foregroundStyle(Theme.secondaryText)
            Group {
                if let code = session.exitCode {
                    Text("Process exited with code \(code)")
                } else {
                    Text("Process exited")
                }
            }
                .font(Theme.Font.body)
                .foregroundStyle(Theme.text)
            Spacer()
            Button("Archive") { store.archive(session.id) }
                .buttonStyle(SecondaryButtonStyle(compact: true))
            if session.resumeCommand != nil {
                Button("Restart") { store.restart(session.id) }
                    .buttonStyle(SecondaryButtonStyle(compact: true))
                Button("Resume Conversation") { store.resume(session.id) }
                    .buttonStyle(PrimaryButtonStyle(compact: true))
            } else {
                Button("Restart") { store.restart(session.id) }
                    .buttonStyle(PrimaryButtonStyle(compact: true))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Theme.elevated)
        .overlay(alignment: .top) { Rectangle().fill(Theme.hairline).frame(height: 1) }
    }
}

/// Shown while the session's processes are stopped. Keystrokes typed meanwhile wait in the terminal.
private struct PausedBar: View {
    @Environment(AppStore.self) private var store
    let session: Session

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "pause.circle.fill").foregroundStyle(SessionStatus.paused.dot)
            Text("Paused: not using CPU")
                .font(Theme.Font.bodyMedium)
                .foregroundStyle(Theme.text)
                .lineLimit(1)
            Spacer()
            Button("Stop") { store.stop(session.id) }
                .buttonStyle(SecondaryButtonStyle(compact: true))
                .help("Ends the process and frees its memory")
            Button("Continue") { store.unpause(session.id) }
                .buttonStyle(PrimaryButtonStyle(compact: true))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Theme.elevated)
        .overlay(alignment: .top) { Rectangle().fill(SessionStatus.paused.dot.opacity(0.5)).frame(height: 1) }
    }
}

/// Shown while the agent waits on a permission dialog: answer it without going to the terminal.
private struct PermissionBar: View {
    @Environment(AppStore.self) private var store
    let session: Session

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "hand.raised.fill").foregroundStyle(SessionStatus.needsInput.dot)
            Text(label)
                .font(Theme.Font.bodyMedium)
                .foregroundStyle(Theme.text)
                .lineLimit(1)
            Spacer()
            Button("Deny") { store.respondToPermission(session.id, allow: false) }
                .buttonStyle(SecondaryButtonStyle(compact: true, destructive: true))
                .help("Sends Esc to the dialog")
            Button("Allow") { store.respondToPermission(session.id, allow: true) }
                .buttonStyle(PrimaryButtonStyle(compact: true))
                .help("Sends Enter: accepts the highlighted option")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color(hex: 0x2A2112))
        .overlay(alignment: .top) { Rectangle().fill(SessionStatus.needsInput.dot.opacity(0.5)).frame(height: 1) }
    }

    /// The host reports "Permission: <tool>"; Claude's own notification text is shown as is.
    private var label: String {
        guard let detail = session.attentionDetail else { return String(localized: "Needs your permission") }
        if detail.hasPrefix("Permission: ") { return String(localized: "Wants to use \(String(detail.dropFirst(12)))") }
        return detail
    }
}

private struct DeadSessionView: View {
    @Environment(AppStore.self) private var store
    let session: Session

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: session.symbol)
                .font(.system(size: 28, weight: .medium))
                .foregroundStyle(Theme.tertiaryText)
            Text(session.title).font(Theme.Font.title).foregroundStyle(Theme.text)
            Group {
                if session.command.isEmpty {
                    Text("Shell session is not running.")
                } else {
                    Text("\(session.command) is not running.")
                }
            }
                .font(Theme.Font.body)
                .foregroundStyle(Theme.secondaryText)
            HStack(spacing: 10) {
                if session.resumeCommand != nil {
                    Button { store.restart(session.id) } label: {
                        Label("New Conversation", systemImage: "plus")
                    }
                    .buttonStyle(SecondaryButtonStyle())
                    Button { store.resume(session.id) } label: {
                        Label("Resume Conversation", systemImage: "arrow.uturn.forward")
                    }
                    .buttonStyle(PrimaryButtonStyle())
                    .keyboardShortcut(.defaultAction)
                } else {
                    Button { store.restart(session.id) } label: {
                        Label("Start", systemImage: "play.fill")
                    }
                    .buttonStyle(PrimaryButtonStyle())
                    .keyboardShortcut(.defaultAction)
                }
            }
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct EmptyPaneView: View {
    @Environment(AppStore.self) private var store
    let leafID: UUID

    var body: some View {
        VStack(spacing: 16) {
            if let project = store.currentProject {
                Text("New session in \(project.name)")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.text)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 120, maximum: 170), spacing: 10)], spacing: 10) {
                    ForEach(store.presets) { preset in
                        PresetCard(preset: preset) {
                            store.focus(leaf: leafID)
                            store.newSession(preset: preset, in: project)
                        }
                    }
                }
                .frame(maxWidth: 540)
                Text("⌘T new · ⌘K palette · ⌘D split")
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.tertiaryText)
            } else {
                Button("Add Project…") { store.addProjectWithPanel() }
                    .buttonStyle(PrimaryButtonStyle())
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .onTapGesture { store.focus(leaf: leafID) }
    }
}

private struct PresetCard: View {
    @Environment(AppStore.self) private var store
    let preset: Preset
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                Image(systemName: preset.symbol)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(store.accent.color)
                    .frame(height: 20)
                Text(preset.label)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.text)
                Text(preset.command.isEmpty ? String(localized: "login shell") : preset.command)
                    .font(Theme.Font.mono)
                    .foregroundStyle(Theme.tertiaryText)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(hovering ? 0.08 : 0.04)))
            .overlay(RoundedRectangle(cornerRadius: 10)
                .strokeBorder(hovering ? Theme.ring(store.accent) : Color.white.opacity(0.08), lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
    }
}

/// Where a dragged session would land: center replaces, an edge splits that way.
private struct SessionDropDelegate: DropDelegate {
    let leafID: UUID
    let size: () -> CGSize
    @Binding var edge: Edge??
    let store: AppStore

    static func zone(_ p: CGPoint, in size: CGSize) -> Edge? {
        guard size.width > 0, size.height > 0 else { return nil }
        let x = p.x / size.width, y = p.y / size.height
        let margins: [(Edge, CGFloat)] = [(.leading, x), (.trailing, 1 - x), (.top, y), (.bottom, 1 - y)]
        guard let nearest = margins.min(by: { $0.1 < $1.1 }), nearest.1 < 0.25 else { return nil }
        return nearest.0
    }

    func validateDrop(info: DropInfo) -> Bool { info.hasItemsConforming(to: [.utf8PlainText]) }

    func dropEntered(info: DropInfo) { edge = .some(Self.zone(info.location, in: size())) }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        edge = .some(Self.zone(info.location, in: size()))
        return DropProposal(operation: .move)
    }

    func dropExited(info: DropInfo) { edge = nil }

    func performDrop(info: DropInfo) -> Bool {
        let target = Self.zone(info.location, in: size())
        edge = nil
        guard let provider = info.itemProviders(for: [.utf8PlainText]).first else { return false }
        let leaf = leafID
        _ = provider.loadObject(ofClass: String.self) { value, _ in
            guard let value, value.hasPrefix("session:"), let id = UUID(uuidString: String(value.dropFirst(8))) else { return }
            DispatchQueue.main.async {
                MainActor.assumeIsolated { store.place(id, in: leaf, edge: target) }
            }
        }
        return true
    }
}

/// Accent-colored preview of the drop target: the whole pane or the half it would split into.
private struct DropZoneHighlight: View {
    let edge: Edge??
    let accent: Color

    var body: some View {
        GeometryReader { g in
            if let target = edge {
                let rect = Self.rect(for: target, in: g.size)
                RoundedRectangle(cornerRadius: 10)
                    .fill(accent.opacity(0.18))
                    .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(accent, lineWidth: 2))
                    .frame(width: rect.width, height: rect.height)
                    .offset(x: rect.minX, y: rect.minY)
            }
        }
        .allowsHitTesting(false)
    }

    static func rect(for edge: Edge?, in s: CGSize) -> CGRect {
        switch edge {
        case nil: CGRect(origin: .zero, size: s)
        case .leading: CGRect(x: 0, y: 0, width: s.width / 2, height: s.height)
        case .trailing: CGRect(x: s.width / 2, y: 0, width: s.width / 2, height: s.height)
        case .top: CGRect(x: 0, y: 0, width: s.width, height: s.height / 2)
        case .bottom: CGRect(x: 0, y: s.height / 2, width: s.width, height: s.height / 2)
        }
    }
}
