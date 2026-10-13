import AppKit
import Foundation
import Observation
import TerminalyKit

@MainActor
@Observable
final class AppStore {
    static let shared = AppStore()

    var workspaces: [Workspace] = []
    var selectedWorkspaceID: UUID?
    var projects: [Project] = []
    var sessions: [Session] = []
    var presets: [Preset] = Preset.defaults
    var layout: PaneNode = .empty()
    var focusedLeafID: UUID?
    var selectedSessionID: UUID?
    var showPalette = false
    var renamingSessionID: UUID?
    var renamingWorkspaceID: UUID?

    @ObservationIgnored let terminals = TerminalRegistry()
    @ObservationIgnored private var saveTask: Task<Void, Never>?

    private init() {
        load()
        terminals.store = self
    }

    /// Reconnects to the session host: re-attaches surviving sessions and adopts ones
    /// created elsewhere (e.g. `tly new`).
    func connectToHost(completion: (() -> Void)? = nil) {
        terminals.connect { [weak self] infos in
            guard let self else { return }
            for info in infos where info.running && self.session(info.id) == nil {
                let project = self.projects.first { $0.path == info.cwd }
                    ?? self.addProject(at: URL(fileURLWithPath: info.cwd))
                let preset = self.presets.first { $0.command == info.command }
                self.sessions.append(Session(id: info.id, projectID: project.id,
                                             title: preset?.label ?? (info.command.isEmpty ? "Shell" : info.command),
                                             command: info.command,
                                             symbol: preset?.symbol ?? "terminal",
                                             createdAt: info.createdAt))
            }
            self.scheduleSave()
            completion?()
        }
    }

    // MARK: Lookup

    func session(_ id: UUID?) -> Session? {
        guard let id else { return nil }
        return sessions.first { $0.id == id }
    }

    func project(_ id: UUID?) -> Project? {
        guard let id else { return nil }
        return projects.first { $0.id == id }
    }

    func sessions(in project: Project, archived: Bool = false) -> [Session] {
        sessions
            .filter { $0.projectID == project.id && $0.archived == archived }
            .sorted { ($0.pinned ? 0 : 1, $0.createdAt) < ($1.pinned ? 0 : 1, $1.createdAt) }
    }

    var currentWorkspace: Workspace? { workspaces.first { $0.id == selectedWorkspaceID } }

    /// Projects of the selected workspace, in sidebar order.
    var visibleProjects: [Project] { projects.filter { $0.workspaceID == selectedWorkspaceID } }

    func projects(in workspace: Workspace) -> [Project] {
        projects.filter { $0.workspaceID == workspace.id }
    }

    func workspace(of sessionID: UUID) -> Workspace? {
        guard let wid = project(session(sessionID)?.projectID)?.workspaceID else { return nil }
        return workspaces.first { $0.id == wid }
    }

    /// Sessions in a workspace waiting for the user; drives the badge on its pill.
    func attentionCount(in workspace: Workspace) -> Int {
        let ids = Set(projects(in: workspace).map(\.id))
        return sessions.filter { ids.contains($0.projectID) && !$0.archived && $0.status == .needsInput }.count
    }

    var archivedSessions: [Session] {
        let ids = Set(visibleProjects.map(\.id))
        return sessions.filter { $0.archived && ids.contains($0.projectID) }
    }

    /// Project new sessions go to by default: the focused session's project, else the first visible one.
    var currentProject: Project? {
        if let p = project(session(selectedSessionID)?.projectID), p.workspaceID == selectedWorkspaceID { return p }
        return visibleProjects.first
    }

    private func update(_ id: UUID, _ change: (inout Session) -> Void) {
        guard let i = sessions.firstIndex(where: { $0.id == id }) else { return }
        change(&sessions[i])
    }

    // MARK: Projects

    func addProjectWithPanel() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Add Project"
        guard panel.runModal() == .OK else { return }
        for url in panel.urls { addProject(at: url) }
    }

    @discardableResult
    func addProject(at url: URL) -> Project {
        if let existing = projects.first(where: { $0.path == url.path }) { return existing }
        let color = FolderColor.allCases[projects.count % FolderColor.allCases.count]
        let p = Project(name: url.lastPathComponent, path: url.path, color: color,
                        workspaceID: selectedWorkspaceID ?? workspaces.first?.id)
        projects.append(p)
        scheduleSave()
        return p
    }

    func removeProject(_ project: Project) {
        for s in sessions where s.projectID == project.id { deleteSession(s.id) }
        projects.removeAll { $0.id == project.id }
        scheduleSave()
    }

    func setColor(_ color: FolderColor, for project: Project) {
        guard let i = projects.firstIndex(where: { $0.id == project.id }) else { return }
        projects[i].color = color
        scheduleSave()
    }

    func toggleCollapsed(_ project: Project) {
        guard let i = projects.firstIndex(where: { $0.id == project.id }) else { return }
        projects[i].collapsed.toggle()
        scheduleSave()
    }

    // MARK: Sessions

    @discardableResult
    func newSession(preset: Preset, in project: Project? = nil) -> Session? {
        guard let project = project ?? currentProject else {
            addProjectWithPanel()
            guard let p = visibleProjects.first else { return nil }
            return newSession(preset: preset, in: p)
        }
        let n = sessions.filter { $0.projectID == project.id && $0.command == preset.command }.count + 1
        let s = Session(projectID: project.id,
                        title: n > 1 ? "\(preset.label) \(n)" : preset.label,
                        command: preset.command,
                        symbol: preset.symbol)
        sessions.append(s)
        terminals.start(s, cwd: project.path)
        show(s.id)
        scheduleSave()
        return s
    }

    /// Shows a session: focuses its pane if visible, otherwise puts it in the focused pane.
    func show(_ id: UUID) {
        guard let s = session(id) else { return }
        if s.archived { update(id) { $0.archived = false } }
        if let ws = workspace(of: id), ws.id != selectedWorkspaceID { selectWorkspace(ws.id) }
        if let leaf = layout.leaf(showing: id) {
            focusedLeafID = leaf
        } else {
            let target = focusedLeafID.flatMap { layout.leafIDs.contains($0) ? $0 : nil } ?? layout.leafIDs.first!
            layout = layout.mapLeaf(target) { _ in .leaf(id: target, sessionID: id) }
            focusedLeafID = target
        }
        selectedSessionID = id
        update(id) { $0.unread = false }
        terminals.focus(id)
        scheduleSave()
    }

    func restart(_ id: UUID) {
        guard let s = session(id), let p = project(s.projectID) else { return }
        terminals.stop(id)
        update(id) { $0.status = .starting; $0.exitCode = nil }
        terminals.start(s, cwd: p.path)
        show(id)
    }

    func archive(_ id: UUID) {
        terminals.stop(id)
        clearFromLayouts(id)
        update(id) { $0.archived = true; $0.status = .exited }
        if selectedSessionID == id { selectedSessionID = nil }
        scheduleSave()
    }

    func deleteSession(_ id: UUID) {
        terminals.stop(id)
        clearFromLayouts(id)
        sessions.removeAll { $0.id == id }
        if selectedSessionID == id { selectedSessionID = nil }
        scheduleSave()
    }

    func rename(_ id: UUID, to title: String) {
        let t = title.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return }
        update(id) { $0.title = t; $0.userTitled = true }
        scheduleSave()
    }

    func togglePinned(_ id: UUID) {
        update(id) { $0.pinned.toggle() }
        scheduleSave()
    }

    /// Selects the next/previous visible session in sidebar order.
    func cycleSession(by offset: Int) {
        let order = visibleProjects.flatMap { sessions(in: $0) }.map(\.id)
        guard !order.isEmpty else { return }
        let i = selectedSessionID.flatMap { order.firstIndex(of: $0) } ?? -offset
        show(order[(i + offset + order.count) % order.count])
    }

    // MARK: Panes

    func focus(leaf: UUID) {
        focusedLeafID = leaf
        if let sid = layout.sessionID(inLeaf: leaf) {
            selectedSessionID = sid
            update(sid) { $0.unread = false }
        }
    }

    func split(_ axis: SplitAxis, leaf: UUID? = nil) {
        guard let target = leaf ?? focusedLeafID ?? layout.leafIDs.first else { return }
        let newLeaf = PaneNode.empty()
        layout = layout.mapLeaf(target) { old in
            .split(id: UUID(), axis: axis, children: [old, newLeaf])
        }
        focusedLeafID = newLeaf.id
        scheduleSave()
    }

    func closePane(_ leaf: UUID? = nil) {
        guard let target = leaf ?? focusedLeafID else { return }
        layout = layout.removing(target) ?? .empty()
        focusedLeafID = layout.leafIDs.first
        if let f = focusedLeafID { focus(leaf: f) }
        scheduleSave()
    }

    // MARK: Status (called by terminals and hook server)

    func terminalTitleChanged(_ id: UUID, title: String) {
        guard let s = session(id), !s.userTitled, !title.isEmpty, s.title != title else { return }
        update(id) { $0.title = String(title.prefix(60)) }
    }

    func outputReceived(_ id: UUID) {
        guard selectedSessionID != id, let s = session(id), !s.unread else { return }
        update(id) { $0.unread = true }
    }

    /// Status reported by the session host (hooks or output activity).
    func applyStatus(_ id: UUID, status raw: String, detail: String?, notify: Bool, exitCode: Int32?) {
        guard let old = session(id), let status = SessionStatus(rawValue: raw) else { return }
        update(id) {
            $0.status = status
            if status == .exited { $0.exitCode = exitCode }
        }
        if notify && !(NSApp.isActive && selectedSessionID == id) {
            update(id) { $0.unread = true }
            Notifier.post(session: old, project: project(old.projectID), status: status, detail: detail)
        }
        Notifier.updateBadge(count: sessions.filter { $0.status == .needsInput }.count)
    }

    // MARK: Persistence

    private static var stateURL: URL {
        let dir = ProcessInfo.processInfo.environment["TERMINALY_STATE_DIR"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Terminaly", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("state.json")
    }

    private func load() {
        guard let data = try? Data(contentsOf: Self.stateURL),
              let state = try? JSONDecoder().decode(PersistedState.self, from: data) else { return }
        projects = state.projects
        workspaces = state.workspaces ?? []
        if workspaces.isEmpty {
            workspaces = [Workspace(name: "Personal", layout: state.layout)]
        }
        // Projects from older files (or pointing at a deleted workspace) go to the first workspace.
        let known = Set(workspaces.map(\.id))
        for i in projects.indices where projects[i].workspaceID.map({ !known.contains($0) }) ?? true {
            projects[i].workspaceID = workspaces[0].id
        }
        selectedWorkspaceID = state.selectedWorkspaceID.flatMap { known.contains($0) ? $0 : nil } ?? workspaces[0].id
        sessions = state.sessions.map { s in
            var s = s
            s.status = .exited  // corrected by connectToHost() for sessions still alive in the host
            return s
        }
        presets = state.presets.isEmpty ? Preset.defaults : state.presets
        layout = currentWorkspace?.layout ?? .empty()
        focusedLeafID = layout.leafIDs.first
        selectedSessionID = state.selectedSessionID
    }

    func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            self?.saveNow()
        }
    }

    func saveNow() {
        commitLayout()
        let state = PersistedState(projects: projects, sessions: sessions, presets: presets,
                                   layout: layout, selectedSessionID: selectedSessionID,
                                   workspaces: workspaces, selectedWorkspaceID: selectedWorkspaceID)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? enc.encode(state) {
            try? data.write(to: Self.stateURL, options: .atomic)
        }
    }
}

extension AppStore {
    func confirmStopAll() {
        let live = sessions.filter { terminals.isRunning($0.id) }
        guard !live.isEmpty else { return }
        let alert = NSAlert()
        alert.messageText = "Stop all sessions?"
        alert.informativeText = "\(live.count) running session\(live.count == 1 ? "" : "s") will be terminated."
        alert.addButton(withTitle: "Stop All")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        for s in live {
            terminals.stop(s.id)
            update(s.id) { $0.status = .exited }
        }
    }
}

// MARK: Workspaces

extension AppStore {
    /// Writes the live layout back into the selected workspace.
    fileprivate func commitLayout() {
        guard let i = workspaces.firstIndex(where: { $0.id == selectedWorkspaceID }) else { return }
        workspaces[i].layout = layout
    }

    fileprivate func clearFromLayouts(_ sessionID: UUID) {
        layout = layout.clearing(sessionID)
        for i in workspaces.indices { workspaces[i].layout = workspaces[i].layout.clearing(sessionID) }
    }

    func selectWorkspace(_ id: UUID) {
        guard id != selectedWorkspaceID, let ws = workspaces.first(where: { $0.id == id }) else { return }
        commitLayout()
        selectedWorkspaceID = id
        layout = ws.layout
        focusedLeafID = layout.leafIDs.first { layout.sessionID(inLeaf: $0) != nil } ?? layout.leafIDs.first
        selectedSessionID = focusedLeafID.flatMap { layout.sessionID(inLeaf: $0) }
        if let sid = selectedSessionID {
            update(sid) { $0.unread = false }
            terminals.focus(sid)
        }
        scheduleSave()
    }

    func cycleWorkspace(by offset: Int) {
        guard workspaces.count > 1, let i = workspaces.firstIndex(where: { $0.id == selectedWorkspaceID }) else { return }
        selectWorkspace(workspaces[(i + offset + workspaces.count) % workspaces.count].id)
    }

    func selectWorkspace(at index: Int) {
        guard workspaces.indices.contains(index) else { return }
        selectWorkspace(workspaces[index].id)
    }

    /// Creates a workspace, switches to it and starts renaming it.
    @discardableResult
    func addWorkspace(name: String? = nil) -> Workspace {
        let color = FolderColor.allCases[workspaces.count % FolderColor.allCases.count]
        let symbol = Workspace.symbols[workspaces.count % Workspace.symbols.count]
        let ws = Workspace(name: name ?? "Workspace \(workspaces.count + 1)", symbol: symbol, color: color)
        workspaces.append(ws)
        selectWorkspace(ws.id)
        if name == nil { renamingWorkspaceID = ws.id }
        scheduleSave()
        return ws
    }

    func renameWorkspace(_ id: UUID, to name: String) {
        let n = name.trimmingCharacters(in: .whitespaces)
        guard !n.isEmpty, let i = workspaces.firstIndex(where: { $0.id == id }) else { return }
        workspaces[i].name = String(n.prefix(40))
        scheduleSave()
    }

    func setWorkspaceStyle(_ id: UUID, symbol: String? = nil, color: FolderColor? = nil) {
        guard let i = workspaces.firstIndex(where: { $0.id == id }) else { return }
        if let symbol { workspaces[i].symbol = symbol }
        if let color { workspaces[i].color = color }
        scheduleSave()
    }

    /// Deletes a workspace; its projects (and their sessions) move to the neighbouring one.
    func deleteWorkspace(_ id: UUID) {
        guard workspaces.count > 1, let i = workspaces.firstIndex(where: { $0.id == id }) else { return }
        let heir = workspaces[i == 0 ? 1 : i - 1]
        if selectedWorkspaceID == id { selectWorkspace(heir.id) }
        for j in projects.indices where projects[j].workspaceID == id { projects[j].workspaceID = heir.id }
        workspaces.remove(at: i)
        scheduleSave()
    }

    func moveWorkspace(_ id: UUID, by offset: Int) {
        guard let i = workspaces.firstIndex(where: { $0.id == id }) else { return }
        let j = i + offset
        guard workspaces.indices.contains(j) else { return }
        workspaces.swapAt(i, j)
        scheduleSave()
    }

    /// Moves a project to another workspace; its sessions leave the old workspace's panes.
    func moveProject(_ projectID: UUID, to workspaceID: UUID) {
        guard let i = projects.firstIndex(where: { $0.id == projectID }),
              projects[i].workspaceID != workspaceID,
              workspaces.contains(where: { $0.id == workspaceID }) else { return }
        projects[i].workspaceID = workspaceID
        for s in sessions where s.projectID == projectID { clearFromLayouts(s.id) }
        if let sid = selectedSessionID, session(sid)?.projectID == projectID { selectedSessionID = nil }
        scheduleSave()
    }
}
