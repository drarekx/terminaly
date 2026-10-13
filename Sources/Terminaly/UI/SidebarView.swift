import SwiftUI
import UniformTypeIdentifiers

/// Sidebar = horizontal pager with one page per workspace (swipe with two fingers),
/// each tinted with its workspace color, plus a footer with workspace icon dots.
struct SidebarView: View {
    @Environment(AppStore.self) private var store
    @State private var scrolledID: UUID?

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .bottom) {
                ScrollView(.horizontal) {
                    HStack(spacing: 0) {
                        ForEach(store.workspaces) { ws in
                            WorkspacePage(workspace: ws, topInset: geo.safeAreaInsets.top)
                                .containerRelativeFrame(.horizontal)
                                .id(ws.id)
                        }
                    }
                    .scrollTargetLayout()
                }
                .scrollTargetBehavior(.paging)
                .scrollPosition(id: $scrolledID)
                .scrollIndicators(.never)
                .ignoresSafeArea(edges: .vertical)

                SidebarFooter()
            }
        }
        .onAppear {
            scrolledID = store.selectedWorkspaceID
            // The pager may not be laid out yet on first appearance.
            DispatchQueue.main.async { scrolledID = store.selectedWorkspaceID }
        }
        // Swipe settled on another page → switch workspace.
        .onChange(of: scrolledID) { _, id in
            if let id, id != store.selectedWorkspaceID { store.selectWorkspace(id) }
        }
        // Switched elsewhere (dots, keyboard, palette) → glide the pager there.
        .onChange(of: store.selectedWorkspaceID) { _, id in
            guard scrolledID != id else { return }
            withAnimation(.smooth(duration: 0.35)) { scrolledID = id }
        }
        .onChange(of: store.workspaces.count) { _, _ in
            withAnimation(.smooth(duration: 0.35)) { scrolledID = store.selectedWorkspaceID }
        }
    }
}

/// One workspace: tinted background, title, project list.
private struct WorkspacePage: View {
    @Environment(AppStore.self) private var store
    let workspace: Workspace
    let topInset: CGFloat
    @State private var showArchived = false

    private var projects: [Project] { store.projects(in: workspace) }
    private var archived: [Session] {
        let ids = Set(projects.map(\.id))
        return store.sessions.filter { $0.archived && ids.contains($0.projectID) }
    }

    var body: some View {
        VStack(spacing: 0) {
            WorkspaceTitle(workspace: workspace)
                .padding(.top, topInset + 6)
                .padding(.horizontal, 14)
                .padding(.bottom, 4)

            List(selection: Binding(
                get: { store.selectedSessionID },
                set: { if let id = $0 { store.show(id) } }
            )) {
                ForEach(projects) { project in
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

                if !archived.isEmpty {
                    Section(isExpanded: $showArchived) {
                        ForEach(archived) { session in
                            SessionRow(session: session)
                                .tag(session.id)
                                .contextMenu {
                                    Button("Restore") { store.show(session.id) }
                                    Button("Delete", role: .destructive) { store.deleteSession(session.id) }
                                }
                        }
                    } header: {
                        Text("Archived (\(archived.count))")
                    }
                }
                // Room so the last rows can scroll above the footer.
                Color.clear.frame(height: 56).listRowSeparator(.hidden)
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
            .tint(workspace.color.color)
            .overlay {
                if projects.isEmpty {
                    ContentUnavailableView {
                        Label("No Projects", systemImage: "folder.badge.plus")
                    } description: {
                        Text("Add a folder or drop one here. Drag a project onto a workspace icon below to move it.")
                    } actions: {
                        Button("Add Project…") { store.addProjectWithPanel() }
                    }
                    .padding(.bottom, 56)
                }
            }
        }
        .background { WorkspaceTint(color: workspace.color.color) }
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            for provider in providers {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url, url.hasDirectoryPath else { return }
                    DispatchQueue.main.async {
                        let p = store.addProject(at: url)
                        store.moveProject(p.id, to: workspace.id)
                    }
                }
            }
            return true
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

/// Workspace color wash over the sidebar material: strong at the top, fading down.
struct WorkspaceTint: View {
    let color: Color

    var body: some View {
        LinearGradient(colors: [color.opacity(0.42), color.opacity(0.22), color.opacity(0.14)],
                       startPoint: .top, endPoint: .bottom)
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
            // Colored badge: plain symbol tints get overridden in sidebar section headers.
            RoundedRectangle(cornerRadius: 4)
                .fill(project.color.color.gradient)
                .frame(width: 16, height: 16)
                .overlay {
                    Image(systemName: "folder.fill")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.white)
                }
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
        .draggable("project:\(project.id.uuidString)") {
            Label(project.name, systemImage: "folder.fill")
                .padding(6)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
        }
        .contextMenu {
            if store.workspaces.count > 1 {
                Menu("Move to Workspace") {
                    ForEach(store.workspaces.filter { $0.id != project.workspaceID }) { ws in
                        Button { store.moveProject(project.id, to: ws.id) } label: {
                            Label(ws.name, systemImage: ws.symbol)
                        }
                    }
                }
            }
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
