import AppKit
import TerminalyKit

/// `Terminaly --selftest` (set TERMINALY_STATE_DIR to a scratch dir). Exercises the real session host:
/// 1. a session fires the Claude hook command → status needsInput
/// 2. a session without hooks → working, then idle after output stops
/// 3. simulated app relaunch → session still alive in the host, output replayed into a fresh view
@MainActor
enum SelfTest {
    static func run() {
        let store = AppStore.shared
        store.connectToHost {
            Task { await steps(store) }
        }
    }

    private static func waitUntil(_ seconds: Double, _ cond: () -> Bool) async -> Bool {
        for _ in 0..<Int(seconds * 10) {
            if cond() { return true }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return cond()
    }

    private static func steps(_ store: AppStore) async {
        // 0. Workspaces: legacy migration (when seeded), per-workspace layouts, moving projects.
        if !workspaceChecks(store) { return }

        let project = store.addProject(at: URL(fileURLWithPath: FileManager.default.currentDirectoryPath))
        if let ws = store.selectedWorkspaceID { store.moveProject(project.id, to: ws) }

        // 1. Hook path
        let hook = ClaudeHookInstaller.command(for: "Notification")
        let cmd = "echo '{\"message\":\"selftest ping\"}' | ( \(hook) ); echo SELFTEST_DONE"
        guard let a = store.newSession(preset: Preset(label: "Hook", command: cmd), in: project) else { return finish(false, "create") }
        let hookOK = await waitUntil(5) {
            store.session(a.id)?.status == .needsInput &&
            (store.terminals.view(for: a.id)?.screenText().contains("SELFTEST_DONE") ?? false)
        }
        print("1 hook: status=\(store.session(a.id)?.status.rawValue ?? "nil") ok=\(hookOK)")
        guard hookOK else { return finish(false, "hook path") }

        // 2. Output heuristic
        guard let b = store.newSession(preset: Preset(label: "Loop", command: "for i in 1 2 3 4 5 6; do echo tick $i; sleep 0.3; done"), in: project) else { return finish(false, "create") }
        let sawWorking = await waitUntil(5) { store.session(b.id)?.status == .working }
        let becameIdle = await waitUntil(6) { store.session(b.id)?.status == .idle }
        print("2 heuristic: sawWorking=\(sawWorking) becameIdle=\(becameIdle)")
        guard sawWorking && becameIdle else { return finish(false, "heuristic") }

        // 3. Relaunch survival
        let marker = "PERSIST_\(Int.random(in: 1000...9999))"
        store.terminals.client.sendInput(b.id, Array("echo \(marker)\r".utf8)[...])
        try? await Task.sleep(for: .milliseconds(500))
        var listed: [SessionInfo] = []
        store.terminals.simulateRelaunch { listed = $0 }
        let reattached = await waitUntil(5) {
            store.terminals.view(for: b.id)?.screenText().contains(marker) ?? false
        }
        let alive = listed.first { $0.id == b.id }?.running ?? false
        print("3 relaunch: alive=\(alive) replayed=\(reattached)")
        guard alive && reattached else { return finish(false, "relaunch") }

        // 4. Drag-to-pane placement and zoom
        _ = store.addWorkspace(name: "Panes")
        let root = store.layout.leafIDs[0]
        store.place(b.id, in: root, edge: nil)                 // center: show b
        let centered = store.layout.sessionIDs == [b.id]
        store.place(a.id, in: root, edge: .trailing)           // edge: split, a on the right
        let split = store.layout.leafIDs.count == 2 && store.layout.sessionIDs == [b.id, a.id]
        store.toggleZoom()
        let zoomedOK = store.zoomedLeafID == store.focusedLeafID && store.zoomedLeafID != nil
        store.toggleZoom()
        let right = store.layout.leafIDs[1]
        store.place(b.id, in: right, edge: nil)                // move b: leaves its old pane
        let moved = store.layout.sessionIDs == [b.id] && store.layout.leafIDs.count == 2
        print("4 panes: centered=\(centered) split=\(split) zoom=\(zoomedOK) moved=\(moved)")
        guard centered && split && zoomedOK && moved else { return finish(false, "panes") }

        // 5. Permission dialog answered from the app, and resume command
        let permHook = ClaudeHookInstaller.command(for: "PermissionRequest")
        let permCmd = "echo '{\"session_id\":\"abc-123\",\"tool_name\":\"Bash\"}' | ( \(permHook) ); read -r answer; echo GOT-$answer-END"
        guard let c = store.newSession(preset: Preset(label: "Perm", command: permCmd), in: project) else { return finish(false, "create") }
        let pending = await waitUntil(5) {
            store.session(c.id)?.permissionPending == true && store.session(c.id)?.agentSessionID == "abc-123"
        }
        store.respondToPermission(c.id, allow: true)
        let answered = await waitUntil(5) {
            store.terminals.view(for: c.id)?.screenText().contains("GOT--END") ?? false
        }
        var claude = Session(projectID: project.id, title: "Claude", command: "claude", symbol: "sparkles")
        claude.agentSessionID = "abc-123"
        let resumeOK = claude.resumeCommand == "claude --resume abc-123"
        claude.agentSessionID = "x; rm -rf ~"
        let sanitized = claude.resumeCommand == "claude --resume xrm-rf"
        print("5 permission: pending=\(pending) answered=\(answered) resume=\(resumeOK) sanitized=\(sanitized)")
        guard pending && answered && resumeOK && sanitized else { return finish(false, "permission") }

        // 6. Switching sessions in one pane shows exactly the selected terminal, on top
        _ = store.addWorkspace(name: "Switch")
        store.show(a.id)
        try? await Task.sleep(for: .milliseconds(400))
        store.show(b.id)
        try? await Task.sleep(for: .milliseconds(400))
        store.show(a.id)
        try? await Task.sleep(for: .milliseconds(600))
        let visible = visibleTerminals()
        let switched = visible.map(\.sessionID) == [a.id]
        print("6 switch: visible=\(visible.map { $0.sessionID == a.id ? "a" : $0.sessionID == b.id ? "b" : "?" }) ok=\(switched)")
        guard switched else { return finish(false, "switch") }

        // 7. Worktree session: own folder and branch; removal keeps the branch
        let repo = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("tly-repo-\(Int.random(in: 1000...9999))")
        try? FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        try? "hi\n".write(to: repo.appendingPathComponent("README"), atomically: true, encoding: .utf8)
        _ = try? await Git.run(["init", "-q", "-b", "main"], in: repo.path)
        _ = try? await Git.run(["add", "."], in: repo.path)
        _ = try? await Git.run(["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "-m", "init"], in: repo.path)
        let repoProject = store.addProject(at: repo)
        var wtOK = false, rejectedEmpty = false, removed = false, branchKept = false
        do {
            let s = try await store.newWorktreeSession(preset: Preset(label: "WT", command: "pwd; git branch --show-current"),
                                                         in: repoProject, branch: "feat/self test")
            let expected = Git.worktreePath(repo: repo.path, branch: "feat/self-test")
            wtOK = await waitUntil(5) {
                let text = store.terminals.view(for: s!.id)?.screenText() ?? ""
                return text.contains("feat/self-test") && text.contains(URL(fileURLWithPath: expected).lastPathComponent)
            } && s?.branch == "feat/self-test"
            do { _ = try await store.newWorktreeSession(preset: Preset(label: "WT", command: ""), in: repoProject, branch: " ") }
            catch { rejectedEmpty = true }
            try await store.removeWorktree(of: s!.id)
            removed = !FileManager.default.fileExists(atPath: expected) && store.session(s!.id) == nil
            branchKept = (try? await Git.run(["show-ref", "--verify", "refs/heads/feat/self-test"], in: repo.path)) != nil
        } catch {
            print("7 worktree error: \(error.localizedDescription)")
        }
        try? FileManager.default.removeItem(at: repo)
        try? FileManager.default.removeItem(at: repo.deletingLastPathComponent().appendingPathComponent(repo.lastPathComponent + ".worktrees"))
        print("7 worktree: started=\(wtOK) rejectEmpty=\(rejectedEmpty) removed=\(removed) branchKept=\(branchKept)")
        guard wtOK && rejectedEmpty && removed && branchKept else { return finish(false, "worktree") }

        finish(true, "")
    }

    private static func workspaceChecks(_ store: AppStore) -> Bool {
        if let legacy = ProcessInfo.processInfo.environment["SELFTEST_EXPECT_LEGACY_PROJECTS"] {
            let migrated = store.workspaces.count == 1 && store.workspaces[0].name == "Personal"
                && store.projects.count == Int(legacy)
                && store.projects.allSatisfy { $0.workspaceID == store.workspaces[0].id }
            print("0 migration: workspaces=\(store.workspaces.map(\.name)) projects=\(store.projects.count) ok=\(migrated)")
            guard migrated else { finish(false, "migration"); return false }
        }
        let home = store.selectedWorkspaceID!
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
        let p = store.addProject(at: tmp)
        store.split(.horizontal)                      // home layout: 2 panes
        let homeLeaves = store.layout.leafIDs.count
        let work = store.addWorkspace(name: "Work")    // switches; fresh layout
        let freshLayout = store.layout.leafIDs.count == 1
        store.moveProject(p.id, to: work.id)
        let moved = store.visibleProjects.contains { $0.id == p.id }
        store.selectWorkspace(home)
        let restored = store.layout.leafIDs.count == homeLeaves && homeLeaves == 2
        let gone = !store.visibleProjects.contains { $0.id == p.id }
        store.renameWorkspace(work.id, to: "  Trabajo  ")
        let renamed = store.workspaces.first { $0.id == work.id }?.name == "Trabajo"
        store.closePane()
        store.deleteWorkspace(work.id)
        let heir = store.project(p.id)?.workspaceID == home && store.workspaces.count >= 1
        let ok = freshLayout && moved && restored && gone && renamed && heir
        print("0 workspaces: fresh=\(freshLayout) moved=\(moved) restored=\(restored) hidden=\(gone) renamed=\(renamed) heir=\(heir)")
        store.removeProject(store.project(p.id)!)
        if !ok { finish(false, "workspaces") }
        return ok
    }

    /// Terminal views actually in the window, topmost per container (what the user sees).
    private static func visibleTerminals() -> [AgentTerminalView] {
        guard let root = NSApp.windows.first(where: { $0.isVisible })?.contentView else { return [] }
        var result: [AgentTerminalView] = []
        func walk(_ v: NSView) {
            let terms = v.subviews.compactMap { $0 as? AgentTerminalView }
            if let top = terms.last, !top.isHiddenOrHasHiddenAncestor { result.append(top) }
            if terms.count > 1 { result.append(contentsOf: terms.dropLast()) }  // stacked = bug
            v.subviews.filter { !($0 is AgentTerminalView) }.forEach(walk)
        }
        walk(root)
        return result
    }

    private static func finish(_ ok: Bool, _ msg: String) {
        print(ok ? "SELFTEST PASS" : "SELFTEST FAIL \(msg)")
        AppStore.shared.terminals.stopAll()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { exit(ok ? 0 : 1) }
    }
}
