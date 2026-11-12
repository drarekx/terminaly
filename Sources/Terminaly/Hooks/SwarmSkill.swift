import Foundation

/// Installs the `terminaly-swarm` skill for Claude Code (~/.claude/skills): it teaches the agent of a
/// session to split work among worker sessions with `tly`. Terminaly itself never orchestrates.
enum SwarmSkillInstaller {
    static let name = "terminaly-swarm"

    enum State { case missing, outdated, current }

    /// Claude Code keeps its files in `CLAUDE_CONFIG_DIR` when set.
    static var defaultSkillsDir: URL {
        let config = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude")
        return config.appendingPathComponent("skills")
    }

    static func fileURL(in skillsDir: URL = defaultSkillsDir) -> URL {
        skillsDir.appendingPathComponent(name).appendingPathComponent("SKILL.md")
    }

    static func state(in skillsDir: URL = defaultSkillsDir) -> State {
        guard let text = try? String(contentsOf: fileURL(in: skillsDir), encoding: .utf8) else { return .missing }
        return text == content ? .current : .outdated
    }

    static func install(in skillsDir: URL = defaultSkillsDir) throws {
        let url = fileURL(in: skillsDir)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(content.utf8).write(to: url, options: .atomic)
    }

    /// Removes our file, and the folder only if nothing else is in it.
    static func uninstall(in skillsDir: URL = defaultSkillsDir) throws {
        let fm = FileManager.default
        let url = fileURL(in: skillsDir)
        guard fm.fileExists(atPath: url.path) else { return }
        try fm.removeItem(at: url)
        let dir = url.deletingLastPathComponent()
        if (try? fm.contentsOfDirectory(atPath: dir.path))?.isEmpty == true { try? fm.removeItem(at: dir) }
    }

    static let content = #"""
    ---
    name: terminaly-swarm
    description: Split a large task among several agent sessions running in parallel in Terminaly, each in its own git worktree, then review and merge their work. Use when the user asks for a swarm, for parallel agents or workers, to "divide this among agents", or when a big task has clearly independent parts and you are running inside Terminaly (TERMINALY_SESSION_ID is set).
    ---

    # Terminaly swarm

    You are the lead. Workers are ordinary agent sessions that you start, brief and collect with the
    `tly` command. The person sees them nested under your session in Terminaly and can open any of them.

    First check that it can work:

    ```sh
    [ -n "$TERMINALY_SESSION_ID" ] && command -v tly
    ```

    If the variable is empty you are not inside Terminaly: say so and do the task yourself. If `tly`
    is not found, use `/Applications/Terminaly.app/Contents/MacOS/tly`.

    ## When it pays off

    Only for parts that are independent: different files, no shared decision still open. Each worker
    costs a full agent and its work has to be reviewed and merged. Two to four workers is the usual
    size. A small or tightly coupled task is faster done by you alone.

    ## 1. Prepare

    - Workers start from the last commit: uncommitted changes are invisible to them. Commit what
      they need first (ask the person before committing if that is not clearly wanted).
    - Decide anything shared (names, interfaces, file layout) yourself and put it in every brief.
    - Give each worker files nobody else touches.

    ## 2. Launch

    ```sh
    tly new --command claude --worktree swarm/api-client --title "API client" --prompt "…brief…"
    ```

    `--command` is the agent to run: `claude` or `opencode`. Use the one you are unless the person
    asks for another.

    It prints the worker's id. `--worktree BRANCH` creates the branch from your current commit and
    a worktree in a folder next to the repository; add `--json` to get the id and that folder (`cwd`).
    Launch all workers before waiting for any.

    A worker knows nothing of this conversation. Its brief must stand alone:

    - the goal and why, the files in scope and what is out of scope;
    - the shared decisions, and where to look for the conventions to follow;
    - how to check its work (the test or build command);
    - "Commit your work on this branch when done. Do not push, do not switch branches."
    - "End with a short report: what you changed, what you ran and its outcome, what is left open."

    That final report is what `tly result` gives you.

    Limits: a worker cannot start workers, and a session may have a limited number running at once
    (6 unless the person changed it). If the limit is hit, wait for one to finish.

    ## 3. Wait and collect

    ```sh
    tly wait ID1 ID2 ID3 --any --timeout 540    # prints "id  status" for those that stopped
    tly result ID1                              # the worker's final report
    ```

    Keep `--timeout` under your shell tool's own time limit and repeat while it times out (exit 1,
    "timeout"). After each return, wait again only for the ids still working. `tly ls` shows them all.

    Statuses:

    - `idle`: the turn finished. Read `tly result`.
    - `needsInput`: the worker shows a permission dialog or a question. Permissions belong to the
      person, who gets a notification and approves in Terminaly. Do not answer the dialog for them.
      Tell the person which worker waits, then wait again.
    - `exited`: the agent quit. `tly logs ID --lines 80` shows why.

    ## 4. Follow up

    ```sh
    tly ask ID "The tests in api/ still fail with X. Fix them and report."
    ```

    Sends the message, waits for the turn and prints the answer. Exit status 2 means it needs input,
    3 means timeout (`--timeout S`). Only ask a worker that is `idle`.

    ## 5. Review and merge

    Never trust a report unread. For each branch:

    ```sh
    git log --oneline HEAD..swarm/api-client
    git diff HEAD...swarm/api-client
    ```

    Then merge one branch at a time into the branch you are on, running the checks after each one.
    Resolve conflicts yourself or send the worker back with `tly ask`. Do not push unless asked.

    ## 6. Clean up

    When a worker's branch is merged (or discarded with the person's agreement):

    ```sh
    tly rm ID
    git worktree remove <the worker's cwd>
    ```

    `git worktree remove` refuses if there are uncommitted changes: look at them before forcing
    anything. Keep the branches unless the person wants them deleted. Finish by telling the person
    what each worker did, what was merged and what remains open.
    """#
}
