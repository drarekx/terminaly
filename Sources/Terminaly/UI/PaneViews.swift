import AppKit
import SwiftUI

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
    let leafID: UUID
    let sessionID: UUID?
    @State private var hovering = false

    private var isFocused: Bool { store.focusedLeafID == leafID }
    private var multiPane: Bool { store.layout.leafIDs.count > 1 }

    var body: some View {
        VStack(spacing: 0) {
            if multiPane || sessionID != nil {
                header
            }
            content
        }
        .background(Theme.pane)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(isFocused && multiPane ? Theme.ring(store.accent) : Color.white.opacity(0.06), lineWidth: 1)
                .allowsHitTesting(false)
        }
        .padding(3)
        .frame(minWidth: 220, minHeight: 120)
        .animation(.easeOut(duration: 0.15), value: isFocused)
    }

    private var header: some View {
        HStack(spacing: 8) {
            if let s = store.session(sessionID) {
                StatusDot(status: s.status)
                Text(s.title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.text.opacity(isFocused ? 1 : 0.8))
                    .lineLimit(1)
                if let p = store.project(s.projectID) {
                    Text(p.name).font(.system(size: 12)).foregroundStyle(Theme.text.opacity(0.5)).lineLimit(1)
                }
                Spacer()
                if s.status == .needsInput {
                    Text("Needs input")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(s.status.text)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(RoundedRectangle(cornerRadius: 5).fill(s.status.dot.opacity(0.14)))
                }
            } else {
                Text("Empty pane").font(.system(size: 12)).foregroundStyle(Theme.text.opacity(0.5))
                Spacer()
            }
            Group {
                Button { store.split(.horizontal, leaf: leafID) } label: { Image(systemName: "rectangle.split.2x1") }
                    .help("Split Right")
                Button { store.split(.vertical, leaf: leafID) } label: { Image(systemName: "rectangle.split.1x2") }
                    .help("Split Down")
                if multiPane {
                    Button { store.closePane(leafID) } label: { Image(systemName: "xmark") }
                        .help("Close Pane")
                }
            }
            .opacity(hovering || isFocused ? 1 : 0)
        }
        .buttonStyle(.borderless)
        .font(.system(size: 11))
        .foregroundStyle(Theme.text.opacity(0.75))
        .padding(.horizontal, 10)
        .frame(height: 32)
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
                ZStack(alignment: .bottom) {
                    TerminalContainer(terminal: view) { store.focus(leaf: leafID) }
                        .padding(.leading, 10)
                        .padding(.top, 6)
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
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.text.opacity(0.5))
            } else {
                Button("Add Project…") { store.addProjectWithPanel() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
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
                Text(preset.command.isEmpty ? "login shell" : preset.command)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Theme.text.opacity(0.5))
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
