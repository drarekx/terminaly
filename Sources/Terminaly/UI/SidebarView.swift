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
                .frame(width: geo.size.width)
                .ignoresSafeArea(edges: .vertical)

                // Pinned to the column width: a wider footer used to widen the whole sidebar and
                // push every row's trailing "+" out of view.
                SidebarFooter()
                    .frame(width: geo.size.width)
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
                                Text("No sessions")
                                    .font(Theme.Font.caption)
                                    .foregroundStyle(Theme.tertiaryText)
                                    .listRowBackground(Color.clear)
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
                            .font(Theme.Font.label)
                            .foregroundStyle(Theme.secondaryText)
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
                            .buttonStyle(PrimaryButtonStyle())
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
        SidebarSessionRow(session: session, workspace: workspace)
            .listRowInsets(EdgeInsets(top: 1, leading: 4, bottom: 1, trailing: 4))
            .listRowBackground(Color.clear)
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
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: project.collapsed ? "chevron.right" : "chevron.down")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(Theme.tertiaryText)
                .frame(width: 12)
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
                .font(.system(size: 12, weight: .semibold))
                .tracking(0.5)
                .foregroundStyle(Theme.secondaryText)
                .lineLimit(1)
            Spacer()
            let count = store.sessions(in: project).count
            if count > 0 && !hovering {
                Text("\(count)")
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.tertiaryText)
            }
            if hovering {
                PopoverMenuButton(width: 270) {
                    Image(systemName: "ellipsis")
                } content: {
                    ProjectMenu(project: project)
                }
                .buttonStyle(IconButtonStyle(size: 24))
                .help("Project options")
            }
            PopoverMenuButton(width: 280) {
                Image(systemName: "plus")
            } content: {
                MenuSectionLabel(title: "New session in \(project.name)")
                ForEach(store.presets) { preset in
                    MenuRow(title: "\(preset.label)", icon: preset.symbol,
                            subtitle: preset.command.isEmpty ? String(localized: "login shell") : preset.command) {
                        store.newSession(preset: preset, in: project)
                    }
                }
                if store.gitProjects.contains(project.id) {
                    MenuDivider()
                    MenuRow(title: "New Session in Worktree…", icon: "arrow.triangle.branch") {
                        store.worktreeRequestProjectID = project.id
                    }
                }
            }
            .buttonStyle(IconButtonStyle(size: 24))
            .help("New session in \(project.name)")
        }
        .frame(minHeight: 28)
        .padding(.trailing, 10)
        .onHover { hovering = $0 }
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

/// Clickable sidebar row: custom selection (white 10 % + workspace ring) and a hover "…" menu.
private struct SidebarSessionRow: View {
    @Environment(AppStore.self) private var store
    let session: Session
    let workspace: Workspace
    @State private var hovering = false

    private var selected: Bool { store.selectedSessionID == session.id }

    var body: some View {
        SessionRow(session: session)
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .overlay(alignment: .trailing) {
                if hovering {
                    PopoverMenuButton(width: 250) {
                        Image(systemName: "ellipsis")
                    } content: {
                        SessionMenu(session: session)
                    }
                    .buttonStyle(IconButtonStyle(size: 26, filled: true))
                    .help("Session options")
                    .padding(.trailing, 6)
                }
            }
            .background(RoundedRectangle(cornerRadius: 9)
                .fill(Color.white.opacity(selected ? 0.10 : hovering ? 0.05 : 0)))
            .overlay(RoundedRectangle(cornerRadius: 9)
                .strokeBorder(selected ? Theme.ring(workspace.color) : .clear, lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: 9))
            .onHover { hovering = $0 }
            .onTapGesture { store.show(session.id) }
            .draggable("session:\(session.id.uuidString)") {
                Label(session.title, systemImage: session.symbol)
                    .font(Theme.Font.bodyMedium)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Theme.elevated))
            }
            .accessibilityAddTraits(.isButton)
            .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// Session actions for the hover popover.
private struct SessionMenu: View {
    @Environment(AppStore.self) private var store
    let session: Session

    var body: some View {
        if session.archived {
            MenuRow(title: "Restore", icon: "arrow.uturn.backward") { store.show(session.id) }
        } else {
            MenuRow(title: "Rename…", icon: "pencil") { store.renamingSessionID = session.id }
            MenuRow(title: session.pinned ? "Unpin" : "Pin", icon: session.pinned ? "pin.slash" : "pin") {
                store.togglePinned(session.id)
            }
            MenuRow(title: "Restart", icon: "arrow.clockwise") { store.restart(session.id) }
            if session.resumeCommand != nil && !store.terminals.isRunning(session.id) {
                MenuRow(title: "Resume Conversation", icon: "arrow.uturn.forward") { store.resume(session.id) }
            }
            MenuRow(title: "Open in Split", icon: "rectangle.split.2x1") {
                store.split(.horizontal)
                store.show(session.id)
            }
            MenuDivider()
            MenuRow(title: "Archive", icon: "archivebox", shortcut: "⇧⌘⌫") { store.archive(session.id) }
            if session.worktreePath != nil {
                MenuRow(title: "Remove Worktree…", icon: "arrow.triangle.branch", destructive: true) {
                    confirmRemoveWorktree()
                }
            }
        }
        MenuRow(title: "Delete", icon: "trash", destructive: true) { store.deleteSession(session.id) }
    }
}

extension SessionMenu {
    fileprivate func confirmRemoveWorktree() {
        guard let path = session.worktreePath else { return }
        let alert = NSAlert()
        alert.messageText = String(localized: "Remove worktree “\(session.branch ?? "")”?")
        alert.informativeText = String(localized: "Stops the session and deletes \(path). The branch is kept. Uncommitted changes block the removal.")
        alert.addButton(withTitle: String(localized: "Remove"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let id = session.id
        Task { @MainActor in
            do {
                try await store.removeWorktree(of: id)
            } catch {
                let fail = NSAlert()
                fail.messageText = String(localized: "Could not remove the worktree")
                fail.informativeText = error.localizedDescription
                fail.runModal()
            }
        }
    }
}

/// Project actions for the hover popover.
private struct ProjectMenu: View {
    @Environment(AppStore.self) private var store
    let project: Project

    var body: some View {
        let others = store.workspaces.filter { $0.id != project.workspaceID }
        if !others.isEmpty {
            MenuSectionLabel(title: "Move to workspace")
            ForEach(others) { ws in
                MenuRow(title: "\(ws.name)", icon: ws.symbol) { store.moveProject(project.id, to: ws.id) }
            }
            MenuDivider()
        }
        MenuSectionLabel(title: "Color")
        ColorSwatchRow(selected: project.color) { store.setColor($0, for: project) }
        MenuDivider()
        MenuRow(title: "Reveal in Finder", icon: "folder") {
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: project.path)])
        }
        MenuRow(title: "Remove Project", icon: "minus.circle", destructive: true) { store.removeProject(project) }
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
                if let branch = session.branch {
                    Label(branch, systemImage: "arrow.triangle.branch")
                        .labelStyle(BranchLabelStyle())
                        .font(Theme.Font.caption)
                        .foregroundStyle(Theme.secondaryText)
                        .lineLimit(1)
                }
                TimelineView(.periodic(from: .now, by: 30)) { _ in
                    Text(statusLine)
                        .font(Theme.Font.caption)
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
        switch session.status {
        case .exited:
            if let code = session.exitCode { return String(localized: "Exited (\(code))") }
            return session.status.label
        case .starting:
            return String(localized: "Starting…")
        default:
            return "\(session.status.label) · \(Self.age(session.statusChangedAt))"
        }
    }

    /// "now", "4 min", "2 h"… in the app's language (not the system's, which may differ).
    static func age(_ date: Date) -> String {
        let seconds = max(0, Date().timeIntervalSince(date))
        if seconds < 60 { return String(localized: "now") }
        let formatter = DateComponentsFormatter()
        formatter.unitsStyle = .abbreviated
        formatter.maximumUnitCount = 1
        formatter.allowedUnits = [.minute, .hour, .day]
        var calendar = Calendar.current
        calendar.locale = AppLanguage.locale
        formatter.calendar = calendar
        return formatter.string(from: seconds) ?? ""
    }
}

/// Tight icon + text for branch names.
struct BranchLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 3) {
            configuration.icon.font(.system(size: 10, weight: .semibold))
            configuration.title
        }
    }
}

/// The pulse runs as a Core Animation layer animation: a SwiftUI `repeatForever` re-lays out
/// the whole window every frame and pins the main thread at ~100% CPU.
struct StatusDot: View {
    let status: SessionStatus

    var body: some View {
        PulsingDot(color: NSColor(status.tint), pulsing: status == .working)
            .frame(width: 8, height: 8)
    }
}

private struct PulsingDot: NSViewRepresentable {
    let color: NSColor
    let pulsing: Bool

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.wantsLayer = true
        view.layer?.cornerRadius = 4
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        guard let layer = view.layer else { return }
        layer.backgroundColor = color.cgColor
        let running = layer.animation(forKey: "pulse") != nil
        if pulsing && !running {
            let pulse = CABasicAnimation(keyPath: "opacity")
            pulse.fromValue = 1
            pulse.toValue = 0.35
            pulse.duration = 0.7
            pulse.autoreverses = true
            pulse.repeatCount = .infinity
            pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            pulse.isRemovedOnCompletion = false
            layer.add(pulse, forKey: "pulse")
        } else if !pulsing && running {
            layer.removeAnimation(forKey: "pulse")
        }
    }
}
