import SwiftUI
import UniformTypeIdentifiers

struct SidebarView: View {
    @Environment(AppStore.self) private var store
    @State private var showArchived = false

    var body: some View {
        List(selection: Binding(
            get: { store.selectedSessionID },
            set: { if let id = $0 { store.show(id) } }
        )) {
            ForEach(store.projects) { project in
                Section {
                    if !project.collapsed {
                        ForEach(store.sessions(in: project)) { session in
                            SessionRow(session: session)
                                .tag(session.id)
                                .contextMenu { sessionMenu(session) }
                        }
                        if store.sessions(in: project).isEmpty {
                            Text("No sessions").font(.caption).foregroundStyle(.tertiary)
                        }
                    }
                } header: {
                    ProjectHeader(project: project)
                }
            }

            if !store.archivedSessions.isEmpty {
                Section(isExpanded: $showArchived) {
                    ForEach(store.archivedSessions) { session in
                        SessionRow(session: session)
                            .tag(session.id)
                            .contextMenu {
                                Button("Restore") { store.show(session.id) }
                                Button("Delete", role: .destructive) { store.deleteSession(session.id) }
                            }
                    }
                } header: {
                    Text("Archived (\(store.archivedSessions.count))")
                }
            }
        }
        .listStyle(.sidebar)
        .overlay {
            if store.projects.isEmpty {
                ContentUnavailableView {
                    Label("No Projects", systemImage: "folder.badge.plus")
                } description: {
                    Text("Add a folder or drop one here.")
                } actions: {
                    Button("Add Project…") { store.addProjectWithPanel() }
                }
            }
        }
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            for provider in providers {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url, url.hasDirectoryPath else { return }
                    DispatchQueue.main.async { store.addProject(at: url) }
                }
            }
            return true
        }
        .safeAreaInset(edge: .bottom) {
            HStack {
                Button { store.addProjectWithPanel() } label: {
                    Label("Add Project", systemImage: "folder.badge.plus")
                }
                .buttonStyle(.borderless)
                Spacer()
                SettingsLink { Image(systemName: "gearshape") }
                    .buttonStyle(.borderless)
            }
            .padding(10)
        }
    }

    @ViewBuilder
    private func sessionMenu(_ session: Session) -> some View {
        Button("Rename…") { store.renamingSessionID = session.id }
        Button(session.pinned ? "Unpin" : "Pin") { store.togglePinned(session.id) }
        Button("Restart") { store.restart(session.id) }
        Divider()
        Button("Split Right With This") {
            store.split(.horizontal)
            store.show(session.id)
        }
        Divider()
        Button("Archive") { store.archive(session.id) }
        Button("Delete", role: .destructive) { store.deleteSession(session.id) }
    }
}

private struct ProjectHeader: View {
    @Environment(AppStore.self) private var store
    let project: Project

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: project.collapsed ? "chevron.right" : "chevron.down")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.tertiary)
                .frame(width: 10)
            Image(systemName: "folder.fill")
                .foregroundStyle(project.color.color)
            Text(project.name)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.primary)
            Spacer()
            Menu {
                ForEach(store.presets) { preset in
                    Button(preset.label) { store.newSession(preset: preset, in: project) }
                }
            } label: {
                Image(systemName: "plus")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("New session in \(project.name)")
        }
        .contentShape(Rectangle())
        .onTapGesture { store.toggleCollapsed(project) }
        .help(project.path)
        .contextMenu {
            Menu("Color") {
                ForEach(FolderColor.allCases, id: \.self) { c in
                    Button(c.rawValue.capitalized) { store.setColor(c, for: project) }
                }
            }
            Button("Reveal in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: project.path)])
            }
            Divider()
            Button("Remove Project", role: .destructive) { store.removeProject(project) }
        }
    }
}

struct SessionRow: View {
    let session: Session

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: session.symbol)
                .frame(width: 16)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(session.title)
                    .lineLimit(1)
                    .fontWeight(session.unread ? .semibold : .regular)
                Text(session.status.label + (session.exitCode.map { " (\($0))" } ?? ""))
                    .font(.caption2)
                    .foregroundStyle(session.status == .needsInput ? .orange : .secondary)
            }
            Spacer(minLength: 4)
            if session.pinned {
                Image(systemName: "pin.fill").font(.caption2).foregroundStyle(.tertiary)
            }
            StatusDot(status: session.status)
        }
        .padding(.vertical, 2)
    }
}

struct StatusDot: View {
    let status: SessionStatus
    @State private var pulse = false

    var body: some View {
        Circle()
            .fill(status.tint)
            .frame(width: 8, height: 8)
            .opacity(status == .working ? (pulse ? 0.35 : 1) : 1)
            .animation(status == .working ? .easeInOut(duration: 0.7).repeatForever() : .default, value: pulse)
            .onAppear { pulse = status == .working }
            .onChange(of: status) { _, s in pulse = s == .working }
    }
}
