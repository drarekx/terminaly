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

            // Selection is drawn by SessionRow itself (design: white 10 % + workspace ring),
            // so the native, inactive-window-black highlight is not used.
            List {
                ForEach(projects) { project in
                    Section {
                        if !project.collapsed {
                            ForEach(store.sessions(in: project)) { session in
                                selectableRow(session)
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
                            selectableRow(session)
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
        .background { Theme.sidebar(workspace.color) }
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

    private func selectableRow(_ session: Session) -> some View {
        let selected = store.selectedSessionID == session.id
        return SessionRow(session: session)
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 9).fill(Color.white.opacity(selected ? 0.10 : 0)))
            .overlay(RoundedRectangle(cornerRadius: 9)
                .strokeBorder(selected ? Theme.ring(workspace.color) : .clear, lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: 9))
            .onTapGesture { store.show(session.id) }
            .listRowInsets(EdgeInsets(top: 1, leading: 4, bottom: 1, trailing: 4))
            .listRowBackground(Color.clear)
            .accessibilityAddTraits(.isButton)
            .accessibilityAddTraits(selected ? .isSelected : [])
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
            // Colored letter badge: plain symbol tints get overridden in sidebar section headers.
            RoundedRectangle(cornerRadius: 5)
                .fill(project.color.color)
                .frame(width: 18, height: 18)
                .overlay {
                    Text(project.name.prefix(1).uppercased())
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white)
                }
            Text(project.name.uppercased())
                .font(.system(size: 11, weight: .semibold))
                .tracking(0.6)
                .foregroundStyle(Theme.text.opacity(0.72))
                .lineLimit(1)
            Spacer()
            let count = store.sessions(in: project).count
            if count > 0 {
                Text("\(count)")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.text.opacity(0.45))
            }
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

/// Session row: status-tinted icon tile, title, status line with age, unread/attention dot.
struct SessionRow: View {
    let session: Session

    private var dimmed: Bool { session.status == .exited }

    var body: some View {
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 8)
                .fill(session.status.tile)
                .frame(width: 28, height: 28)
                .overlay {
                    Image(systemName: session.symbol)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(session.status.dot)
                }
            VStack(alignment: .leading, spacing: 2) {
                Text(session.title)
                    .font(.system(size: 13, weight: session.unread || session.status == .needsInput ? .semibold : .medium))
                    .foregroundStyle(Theme.text.opacity(dimmed ? 0.7 : 1))
                    .lineLimit(1)
                TimelineView(.periodic(from: .now, by: 30)) { _ in
                    Text(statusLine)
                        .font(.system(size: 11))
                        .foregroundStyle(session.status.text)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            if session.pinned {
                Image(systemName: "pin.fill").font(.system(size: 9)).foregroundStyle(Theme.text.opacity(0.4))
            }
            if session.status == .needsInput {
                Circle().fill(session.status.dot)
                    .frame(width: 8, height: 8)
                    .background(Circle().fill(session.status.dot.opacity(0.18)).frame(width: 14, height: 14))
            } else if session.status == .working {
                StatusDot(status: .working)
            } else if session.unread {
                Circle().fill(Theme.text).frame(width: 7, height: 7)
            }
        }
        .padding(.vertical, 3)
    }

    private var statusLine: String {
        if session.status == .exited {
            return "Exited" + (session.exitCode.map { " (\($0))" } ?? "")
        }
        let age = session.statusChangedAt.formatted(.relative(presentation: .numeric, unitsStyle: .abbreviated))
        return session.status == .starting ? "Starting…" : "\(session.status.label) · \(age)"
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
