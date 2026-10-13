import AppKit
import SwiftUI

/// Renders the split tree recursively.
struct PaneTreeView: View {
    let node: PaneNode

    var body: some View {
        switch node {
        case .leaf(let id, let sessionID):
            PaneView(leafID: id, sessionID: sessionID)
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
    let leafID: UUID
    let sessionID: UUID?

    private var isFocused: Bool { store.focusedLeafID == leafID }
    private var multiPane: Bool { store.layout.leafIDs.count > 1 }

    var body: some View {
        VStack(spacing: 0) {
            if multiPane || sessionID != nil {
                header
            }
            content
        }
        .frame(minWidth: 220, minHeight: 120)
        .overlay {
            if multiPane {
                RoundedRectangle(cornerRadius: 2)
                    .strokeBorder(isFocused ? Color.accentColor.opacity(0.7) : .clear, lineWidth: 1)
                    .allowsHitTesting(false)
            }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            if let s = store.session(sessionID) {
                StatusDot(status: s.status)
                Text(s.title).font(.system(size: 11, weight: .medium)).lineLimit(1)
                if let p = store.project(s.projectID) {
                    Text(p.name).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                }
            } else {
                Text("Empty pane").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer()
            Button { store.split(.horizontal, leaf: leafID) } label: { Image(systemName: "rectangle.split.2x1") }
                .help("Split Right")
            Button { store.split(.vertical, leaf: leafID) } label: { Image(systemName: "rectangle.split.1x2") }
                .help("Split Down")
            if multiPane {
                Button { store.closePane(leafID) } label: { Image(systemName: "xmark") }
                    .help("Close Pane")
            }
        }
        .buttonStyle(.borderless)
        .font(.system(size: 11))
        .padding(.horizontal, 10)
        .frame(height: 26)
        .background(isFocused ? Color.white.opacity(0.06) : Color.white.opacity(0.02))
        .contentShape(Rectangle())
        .onTapGesture { store.focus(leaf: leafID) }
    }

    @ViewBuilder
    private var content: some View {
        if let s = store.session(sessionID) {
            if let view = store.terminals.view(for: s.id) {
                ZStack(alignment: .bottom) {
                    TerminalContainer(terminal: view) { store.focus(leaf: leafID) }
                        .padding(.leading, 6)
                    if s.status == .exited {
                        ExitedBar(session: s)
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
        if terminal.superview !== container { attach(to: container) }
    }

    private func attach(to container: NSView) {
        terminal.removeFromSuperview()
        terminal.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(terminal)
        NSLayoutConstraint.activate([
            terminal.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            terminal.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            terminal.topAnchor.constraint(equalTo: container.topAnchor),
            terminal.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
    }
}

private struct ExitedBar: View {
    @Environment(AppStore.self) private var store
    let session: Session

    var body: some View {
        HStack {
            Image(systemName: "stop.circle")
            Text("Process exited" + (session.exitCode.map { " with code \($0)" } ?? ""))
            Spacer()
            Button("Restart") { store.restart(session.id) }
            Button("Archive") { store.archive(session.id) }
        }
        .font(.system(size: 12))
        .padding(8)
        .background(.regularMaterial)
    }
}

private struct DeadSessionView: View {
    @Environment(AppStore.self) private var store
    let session: Session

    var body: some View {
        ContentUnavailableView {
            Label(session.title, systemImage: session.symbol)
        } description: {
            Text(session.command.isEmpty ? "Shell session is not running." : "`\(session.command)` is not running.")
        } actions: {
            Button("Start") { store.restart(session.id) }
                .keyboardShortcut(.defaultAction)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct EmptyPaneView: View {
    @Environment(AppStore.self) private var store
    let leafID: UUID

    var body: some View {
        VStack(spacing: 14) {
            if let project = store.currentProject {
                Text("New session in \(project.name)")
                    .font(.headline)
                HStack {
                    ForEach(store.presets) { preset in
                        Button {
                            store.focus(leaf: leafID)
                            store.newSession(preset: preset, in: project)
                        } label: {
                            Label(preset.label, systemImage: preset.symbol)
                                .frame(minWidth: 80)
                        }
                        .controlSize(.large)
                    }
                }
                Text("⌘T new · ⌘K palette · ⌘D split").font(.caption).foregroundStyle(.tertiary)
            } else {
                Button("Add Project…") { store.addProjectWithPanel() }
                    .controlSize(.large)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .onTapGesture { store.focus(leaf: leafID) }
    }
}
