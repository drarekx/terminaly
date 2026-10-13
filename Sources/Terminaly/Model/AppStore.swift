import AppKit
import Foundation
import Observation
import TerminalyKit

@MainActor
@Observable
final class AppStore {
    static let shared = AppStore()

    var projects: [Project] = []
    var sessions: [Session] = []
    var presets: [Preset] = Preset.defaults
    var layout: PaneNode = .empty()
    var focusedLeafID: UUID?
    var selectedSessionID: UUID?
    var showPalette = false
    var renamingSessionID: UUID?

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

    var archivedSessions: [Session] { sessions.filter(\.archived) }

    /// Project new sessions go to by default: the focused session's project, else the first.
    var currentProject: Project? {
        project(session(selectedSessionID)?.projectID) ?? projects.first
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
        let p = Project(name: url.lastPathComponent, path: url.path, color: color)
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
            guard let p = projects.first else { return nil }
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
        layout = layout.clearing(id)
        update(id) { $0.archived = true; $0.status = .exited }
        if selectedSessionID == id { selectedSessionID = nil }
        scheduleSave()
    }

    func deleteSession(_ id: UUID) {
        terminals.stop(id)
        layout = layout.clearing(id)
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
        let order = projects.flatMap { sessions(in: $0) }.map(\.id)
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
        sessions = state.sessions.map { s in
            var s = s
            s.status = .exited  // corrected by connectToHost() for sessions still alive in the host
            return s
        }
        presets = state.presets.isEmpty ? Preset.defaults : state.presets
        layout = state.layout
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
        let state = PersistedState(projects: projects, sessions: sessions, presets: presets,
                                   layout: layout, selectedSessionID: selectedSessionID)
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
