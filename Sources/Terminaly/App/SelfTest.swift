import AppKit
import TerminalyKit

/// `Terminaly --selftest` (set TERMINALY_STATE_DIR to a scratch dir). Exercises the real session host:
/// 1. a session fires the Claude hook command → status needsInput
/// 2. a session without hooks → working, then idle after output stops
/// 3. simulated app relaunch → session still alive in the host, output replayed into a fresh view
/// …and later steps for panes, permissions, worktrees, pausing and swarm workers (see the numbered prints).
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

        // 8. Pause: the whole tree (shell + busy child) stops using CPU, and continues afterwards.
        guard let busy = store.newSession(preset: Preset(label: "Busy", command: "yes > /dev/null"), in: project) else { return finish(false, "create") }
        try? await Task.sleep(for: .milliseconds(800))
        store.pause(busy.id)
        let paused = await waitUntil(3) { store.session(busy.id)?.status == .paused }
        let t0 = await cpuTime(store, busy.id)
        try? await Task.sleep(for: .milliseconds(600))
        let t1 = await cpuTime(store, busy.id)
        store.unpause(busy.id)
        let continued = await waitUntil(3) { store.session(busy.id)?.status != .paused }
        try? await Task.sleep(for: .milliseconds(600))
        let t2 = await cpuTime(store, busy.id)
        let still = t1 < t0 + 50_000_000, burning = t2 > t1 + 200_000_000
        print("8 pause: paused=\(paused) still=\(still) continued=\(continued) burning=\(burning)")
        guard paused && still && continued && burning else { return finish(false, "pause") }

        // 9. Swarm: a session started from inside another one (`tly new`) is adopted as its worker,
        // its prompt reaches the command, and a turn has a result.
        let stop = ClaudeHookInstaller.command(for: "Stop")
        let agent = "f() { echo \"{\\\"last_assistant_message\\\":\\\"A:$1\\\"}\" | ( \(stop) ); }; f"
        let created = await tly(["new", "--cwd", project.path, "--command", agent, "--prompt", "swarm", "--title", "Worker"],
                                parent: busy.id)
        let worker = UUID(uuidString: created.out)
        let adopted = await waitUntil(5) {
            guard let s = store.session(worker) else { return false }
            return s.parentID == busy.id && s.title == "Worker" && s.projectID == project.id
        }
        _ = await tly(["wait", created.out, "--timeout", "10"])
        let answer = await tly(["result", created.out]).out
        let nested = await tly(["new", "--cwd", project.path], parent: worker)
        let asked = await tly(["ask", busy.id.uuidString, "x", "--timeout", "1"])
        // The limit set in Settings applies to a host that is already running.
        let previous = DaemonConfig.load()
        try? DaemonConfig(maxWorkers: 1).save()
        let overLimit = await tly(["new", "--cwd", project.path], parent: busy.id)
        try? previous.save()
        let skills = TerminalyPaths.stateDir.appendingPathComponent("selftest-skills")
        try? SwarmSkillInstaller.install(in: skills)
        let skillOK = SwarmSkillInstaller.state(in: skills) == .current
        try? SwarmSkillInstaller.uninstall(in: skills)
        let skillGone = SwarmSkillInstaller.state(in: skills) == .missing
        try? OpenCodePluginInstaller.install(in: skills)
        let pluginOK = OpenCodePluginInstaller.state(in: skills) == .current
        try? OpenCodePluginInstaller.uninstall(in: skills)
        let pluginGone = OpenCodePluginInstaller.state(in: skills) == .missing
        print("9 swarm: adopted=\(adopted) result=\(answer == "A:swarm") noNesting=\(nested.code != 0) askTimeout=\(asked.code == 3) limit=\(overLimit.code != 0) skill=\(skillOK && skillGone) plugin=\(pluginOK && pluginGone)")
        guard adopted && answer == "A:swarm" && nested.code != 0 && asked.code == 3 && overLimit.code != 0
                && skillOK && skillGone && pluginOK && pluginGone else { return finish(false, "swarm") }

        finish(true, "")
    }

    /// Runs the `tly` CLI as a session would (`parent` = the session it runs in).
    private static func tly(_ args: [String], parent: UUID? = nil) async -> (out: String, code: Int32) {
        await withCheckedContinuation { cont in
            DispatchQueue.global().async {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: DaemonClient.tlyPath)
                p.arguments = args
                var env = ProcessInfo.processInfo.environment
                env["TERMINALY_SESSION_ID"] = parent?.uuidString
                p.environment = env
                let out = Pipe()
                p.standardOutput = out
                p.standardError = Pipe()
                guard (try? p.run()) != nil else { return cont.resume(returning: ("", -1)) }
                let data = out.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()
                cont.resume(returning: (String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines),
                                        p.terminationStatus))
            }
        }
    }

    private static func cpuTime(_ store: AppStore, _ id: UUID) async -> UInt64 {
        await withCheckedContinuation { cont in
            store.terminals.client.request(Message(type: "stats")) { reply in
                cont.resume(returning: reply.usage?.first { $0.id == id }?.usage.cpuTime ?? 0)
            }
        }
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
