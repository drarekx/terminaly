import AppKit
import Foundation
import Observation
import SwiftUI
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
    /// Pane shown alone (⌘↩); runtime only.
    var zoomedLeafID: UUID?
    /// Projects that are git repositories (worktree sessions are offered for these).
    var gitProjects: Set<UUID> = []
    /// Project whose "New Session in Worktree" sheet is open.
    var worktreeRequestProjectID: UUID?

    @ObservationIgnored let terminals = TerminalRegistry()
    @ObservationIgnored let resources = ResourceMonitor()
    @ObservationIgnored private var saveTask: Task<Void, Never>?

    private init() {
        load()
        if workspaces.isEmpty {  // fresh install: no state file yet
            let ws = Workspace(name: "Personal", symbol: "house.fill")
            workspaces = [ws]
            selectedWorkspaceID = ws.id
        }
        terminals.store = self
        resources.client = terminals.client
        refreshGitProjects()
    }

    func refreshGitProjects() {
        let candidates = projects.map { ($0.id, $0.path) }
        Task {
            var found: Set<UUID> = []
            for (id, path) in candidates where await Git.isRepository(path) { found.insert(id) }
            self.gitProjects = found
        }
    }

    /// Where a session's shell starts: its worktree, else its project folder.
    func workingDirectory(for s: Session) -> String? {
        s.worktreePath ?? project(s.projectID)?.path
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

    /// Color of the selected workspace; drives focus rings, selection and primary buttons.
    var accent: FolderColor { currentWorkspace?.color ?? .blue }

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
        panel.canCreateDirectories = true
        panel.prompt = String(localized: "Add Project")
        guard panel.runModal() == .OK else { return }
        for url in panel.urls { addProject(at: url) }
    }

    /// Asks for a name and location, creates the folder and adds it as a project.
    func newProjectWithPanel() {
        let panel = NSSavePanel()
        panel.title = String(localized: "New Project")
        panel.prompt = String(localized: "Create")
        panel.nameFieldLabel = String(localized: "Folder Name:")
        panel.nameFieldStringValue = String(localized: "New Project")
        panel.canCreateDirectories = true
        panel.directoryURL = projects.last.map { URL(fileURLWithPath: $0.path).deletingLastPathComponent() }
        let gitKey = "newProjectGitInit"
        let gitBox = NSButton(checkboxWithTitle: String(localized: "Initialize Git repository"), target: nil, action: nil)
        gitBox.state = UserDefaults.standard.object(forKey: gitKey) as? Bool ?? true ? .on : .off
        let accessory = NSView(frame: NSRect(x: 0, y: 0, width: gitBox.fittingSize.width + 40, height: gitBox.fittingSize.height + 16))
        gitBox.frame.origin = NSPoint(x: 20, y: 8)
        accessory.addSubview(gitBox)
        panel.accessoryView = accessory
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let gitInit = gitBox.state == .on
        UserDefaults.standard.set(gitInit, forKey: gitKey)
        do {
            // The save panel already confirmed replacing an existing item; an existing folder is just reused.
            var isDir: ObjCBool = false
            if !FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) || !isDir.boolValue {
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            }
            addProject(at: url)
            guard gitInit else { return }
            Task {
                guard await !Git.isRepository(url.path) else { return }
                do {
                    _ = try await Git.run(["init"], in: url.path)
                    refreshGitProjects()
                } catch {
                    NSAlert(error: error).runModal()
                }
            }
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    @discardableResult
    func addProject(at url: URL) -> Project {
        if let existing = projects.first(where: { $0.path == url.path }) { return existing }
        let color = FolderColor.allCases[projects.count % FolderColor.allCases.count]
        let p = Project(name: url.lastPathComponent, path: url.path, color: color,
                        workspaceID: selectedWorkspaceID ?? workspaces.first?.id)
        projects.append(p)
        scheduleSave()
        refreshGitProjects()
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
    func newSession(preset: Preset, in project: Project? = nil, worktreePath: String? = nil, branch: String? = nil) -> Session? {
        guard let project = project ?? currentProject else {
            addProjectWithPanel()
            guard let p = visibleProjects.first else { return nil }
            return newSession(preset: preset, in: p)
        }
        let n = sessions.filter { $0.projectID == project.id && $0.command == preset.command }.count + 1
        var s = Session(projectID: project.id,
                        title: n > 1 ? "\(preset.label) \(n)" : preset.label,
                        command: preset.command,
                        symbol: preset.symbol)
        s.worktreePath = worktreePath
        s.branch = branch
        sessions.append(s)
        terminals.start(s, cwd: worktreePath ?? project.path)
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
        guard let s = session(id), let cwd = workingDirectory(for: s) else { return }
        terminals.stop(id)
        update(id) { $0.status = .starting; $0.exitCode = nil; $0.permissionPending = false }
        terminals.start(s, cwd: cwd)
        show(id)
    }

    /// Restarts the session continuing the agent's previous conversation (`claude --resume <id>`).
    func resume(_ id: UUID) {
        guard let s = session(id), let cwd = workingDirectory(for: s), let command = s.resumeCommand else { return }
        terminals.stop(id)
        update(id) { $0.status = .starting; $0.exitCode = nil; $0.permissionPending = false }
        terminals.start(s, cwd: cwd, command: command)
        show(id)
    }

    /// Stops the session's processes without killing them: no CPU until `unpause`.
    func pause(_ id: UUID) {
        guard let s = session(id), s.status != .paused else { return }
        terminals.setPaused(id, true)
    }

    func unpause(_ id: UUID) {
        guard session(id)?.status == .paused else { return }
        terminals.setPaused(id, false)
    }

    /// Ends the process (frees its memory) but keeps the session, so it can be restarted or resumed.
    func stop(_ id: UUID) {
        terminals.stop(id)
        update(id) { $0.status = .exited; $0.permissionPending = false }
    }

    /// Answers the agent's permission dialog: Enter accepts the highlighted "Yes", Esc declines.
    func respondToPermission(_ id: UUID, allow: Bool) {
        guard let s = session(id), s.permissionPending, terminals.isRunning(id) else { return }
        terminals.client.sendInput(id, Array((allow ? "\r" : "\u{1b}").utf8)[...])
        update(id) {
            $0.permissionPending = false
            $0.attentionDetail = nil
            $0.status = allow ? .working : .idle
            $0.statusChangedAt = Date()
        }
        Notifier.clear(sessionID: id)
        Notifier.updateBadge(count: sessions.filter { $0.status == .needsInput }.count)
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

    func toggleZoom(_ leaf: UUID? = nil) {
        if zoomedLeafID != nil {
            zoomedLeafID = nil
        } else if layout.leafIDs.count > 1, let target = leaf ?? focusedLeafID {
            zoomedLeafID = target
            focus(leaf: target)
        }
    }

    /// Drops a session onto a pane: `edge` nil replaces the pane's session, otherwise the pane
    /// splits and the session opens on that side.
    func place(_ sessionID: UUID, in leaf: UUID, edge: Edge?) {
        guard session(sessionID) != nil, layout.leafIDs.contains(leaf) else { return }
        if edge == nil && layout.sessionID(inLeaf: leaf) == sessionID { return }
        layout = layout.clearing(sessionID)
        zoomedLeafID = nil
        if let edge {
            let fresh = PaneNode.leaf(id: UUID(), sessionID: sessionID)
            let axis: SplitAxis = (edge == .leading || edge == .trailing) ? .horizontal : .vertical
            let first = edge == .leading || edge == .top
            layout = layout.mapLeaf(leaf) { old in
                .split(id: UUID(), axis: axis, children: first ? [fresh, old] : [old, fresh])
            }
            focusedLeafID = fresh.id
        } else {
            layout = layout.mapLeaf(leaf) { _ in .leaf(id: leaf, sessionID: sessionID) }
            focusedLeafID = leaf
        }
        selectedSessionID = sessionID
        update(sessionID) { $0.unread = false }
        terminals.focus(sessionID)
        scheduleSave()
    }

    func closePane(_ leaf: UUID? = nil) {
        guard let target = leaf ?? focusedLeafID else { return }
        layout = layout.removing(target) ?? .empty()
        if zoomedLeafID == target || layout.leafIDs.count < 2 { zoomedLeafID = nil }
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
    func applyStatus(_ id: UUID, status raw: String, detail: String?, notify: Bool, exitCode: Int32?,
                     permission: Bool = false, agentSessionID: String? = nil) {
        guard let old = session(id), let status = SessionStatus(rawValue: raw) else { return }
        update(id) {
            if $0.status != status { $0.statusChangedAt = Date() }
            $0.status = status
            if status == .exited { $0.exitCode = exitCode }
            $0.permissionPending = status == .needsInput && permission
            $0.attentionDetail = status == .needsInput ? detail : nil
            if let agentSessionID { $0.agentSessionID = agentSessionID }
        }
        if agentSessionID != nil && agentSessionID != old.agentSessionID { scheduleSave() }
        if notify && !(NSApp.isActive && selectedSessionID == id) {
            update(id) { $0.unread = true }
            Notifier.post(session: old, project: project(old.projectID), status: status, detail: detail,
                          permission: status == .needsInput && permission)
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
        alert.messageText = String(localized: "Stop all sessions?")
        alert.informativeText = String(localized: "Running sessions that will be terminated: \(live.count).")
        alert.addButton(withTitle: String(localized: "Stop All"))
        alert.addButton(withTitle: String(localized: "Cancel"))
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
        zoomedLeafID = nil
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
        let ws = Workspace(name: name ?? String(localized: "Workspace \(workspaces.count + 1)"), symbol: symbol, color: color)
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

// MARK: Worktrees

extension AppStore {
    /// Creates `<repo>.worktrees/<branch>` and starts the preset there.
    @discardableResult
    func newWorktreeSession(preset: Preset, in project: Project, branch rawBranch: String) async throws -> Session? {
        let branch = Git.sanitizeBranch(rawBranch)
        guard !branch.isEmpty else { throw Git.Failure(message: String(localized: "Enter a branch name.")) }
        let path = try await Git.addWorktree(repo: project.path, branch: branch)
        return newSession(preset: preset, in: project, worktreePath: path, branch: branch)
    }

    /// Removes the session's worktree (refuses if it has uncommitted changes) and the session.
    func removeWorktree(of id: UUID) async throws {
        guard let s = session(id), let path = s.worktreePath, let p = project(s.projectID) else { return }
        terminals.stop(id)
        try await Git.removeWorktree(repo: p.path, path: path)
        deleteSession(id)
    }
}
