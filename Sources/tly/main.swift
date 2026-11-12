import Darwin
import Foundation
import TerminalyKit

let usage = """
tly — Terminaly session host

  tly daemon                         run the session host (started automatically)
  tly web                            serve the browser UI on the local network (enable it in Terminaly settings)
  tly ls [--json]                    list sessions
  tly new [--cwd DIR] [--command CMD] [--json]
          [--title NAME]             name shown in Terminaly
          [--prompt TEXT]            first prompt, passed to CMD as its argument
          [--worktree BRANCH]        run in a git worktree of the repository in DIR, on BRANCH
          [--no-parent]              don't make it a worker of the session this runs in
  tly send <id> <text...> [--enter]  type text into a session
  tly ask <id> <text...> [--timeout S] [--json]
                                     send a prompt, wait for the turn to finish and print the answer
  tly result <id> [--json]           the answer of the last finished turn
  tly logs <id> [--lines N]          recent output (raw)
  tly attach <id>                    attach this terminal (detach: Ctrl-\\)
  tly wait <id>... [--any] [--timeout S] [--json]
                                     block until the sessions (or any of them) are idle or need input
  tly pause <id>                     stop a session's processes (SIGSTOP) until resumed
  tly resume <id>                    continue a paused session
  tly kill <id> [--tree]             hang up a session (and its workers)
  tly rm <id> [--tree]               kill and forget a session (and its workers)
  tly shutdown                       stop the host and all sessions

<id> may be any unique prefix of the session UUID.
A session started from inside another one (TERMINALY_SESSION_ID) becomes its worker.
Exit status of ask: 0 answered, 2 the session needs input, 3 timeout, 1 anything else.
"""

func fail(_ s: String) -> Never {
    FileHandle.standardError.write(Data("tly: \(s)\n".utf8))
    exit(1)
}

var args = Array(CommandLine.arguments.dropFirst())

func flag(_ name: String) -> Bool {
    guard let i = args.firstIndex(of: name) else { return false }
    args.remove(at: i)
    return true
}

func option(_ name: String) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    let v = args[i + 1]
    args.removeSubrange(i...(i + 1))
    return v
}

var selfPath: String {
    var size: UInt32 = 4096
    var buf = [CChar](repeating: 0, count: Int(size))
    _ = _NSGetExecutablePath(&buf, &size)
    return URL(fileURLWithPath: String(cString: buf)).resolvingSymlinksInPath().path
}

func connection() -> SyncConnection {
    do {
        return SyncConnection(fd: try DaemonLauncher.connect(tlyPath: selfPath))
    } catch {
        fail("cannot reach daemon: \(error)")
    }
}

func call(_ conn: SyncConnection, _ msg: Message) -> Message {
    do {
        let r = try conn.request(msg)
        if let e = r.error { fail(e) }
        return r
    } catch {
        fail("\(error)")
    }
}

func resolve(_ conn: SyncConnection, _ prefix: String?) -> SessionInfo {
    guard let prefix = prefix?.lowercased() else { fail("missing session id") }
    let all = call(conn, Message(type: "list")).sessions ?? []
    let matches = all.filter { $0.id.uuidString.lowercased().hasPrefix(prefix) }
    guard matches.count == 1 else { fail(matches.isEmpty ? "no session \(prefix)" : "ambiguous id \(prefix)") }
    return matches[0]
}

func short(_ id: UUID) -> String { String(id.uuidString.prefix(8)).lowercased() }

let finished: Set<String> = ["idle", "needsInput", "exited"]

/// Prints the answer of the last turn; a session that has none (no hooks, no output) prints nothing.
func printResult(_ conn: SyncConnection, _ s: SessionInfo, json: Bool) {
    let r = call(conn, Message(type: "result", id: s.id))
    if json {
        struct Out: Encodable { let id: UUID; let status: String?; let turns: Int?; let result: String? }
        printJSON(Out(id: s.id, status: r.status, turns: r.turns, result: r.text))
    } else if let text = r.text {
        print(text)
    }
}

func printJSON(_ value: some Encodable) {
    let enc = JSONEncoder()
    enc.outputFormatting = [.prettyPrinted, .sortedKeys]
    enc.dateEncodingStrategy = .iso8601
    print(String(decoding: try! enc.encode(value), as: UTF8.self))
}

guard let cmd = args.first else {
    print(usage)
    exit(0)
}
args.removeFirst()

switch cmd {
case "daemon":
    Daemon().run()

case "web":
    guard let config = WebConfig.load(), config.enabled else { fail("web access is off; turn it on in Terminaly → Settings → Web") }
    guard let root = WebServer.findWebRoot() else { fail("web files not found (Resources/web)") }
    WebServer(config: config, webRoot: root).run()

case "ls":
    let json = flag("--json")
    let conn = connection()
    let all = call(conn, Message(type: "list")).sessions ?? []
    if json { printJSON(all) ; break }
    if all.isEmpty { print("no sessions") }
    // Workers right under the session that started them.
    let known = Set(all.map(\.id))
    let roots = all.filter { $0.parent == nil || !known.contains($0.parent!) }
    let list = roots.flatMap { root in [root] + all.filter { $0.parent == root.id } }
    for s in list {
        let cmd = s.command.isEmpty ? "(shell)" : s.command
        let cwd = (s.cwd as NSString).abbreviatingWithTildeInPath
        let name = s.title.map { "  [\($0)]" } ?? ""
        let indent = s.parent == nil ? "" : "  └ "
        print("\(indent)\(short(s.id))  \(s.status.padding(toLength: 10, withPad: " ", startingAt: 0))  \(cmd)  \(cwd)\(name)")
    }

case "new":
    let cwd = option("--cwd") ?? FileManager.default.currentDirectoryPath
    let command = option("--command") ?? ""
    let json = flag("--json")
    let prompt = option("--prompt")
    let worktree = option("--worktree")
    let noParent = flag("--no-parent")
    var m = Message(type: "create")
    m.cwd = (cwd as NSString).expandingTildeInPath
    m.command = command
    m.title = option("--title")
    m.prompt = prompt
    if !noParent { m.parent = ProcessInfo.processInfo.environment["TERMINALY_SESSION_ID"].flatMap(UUID.init(uuidString:)) }
    if let prompt, command.isEmpty || prompt.isEmpty { fail("--prompt needs --command and some text") }
    if let worktree {
        let branch = Git.sanitizeBranch(worktree)
        guard !branch.isEmpty else { fail("invalid branch name \(worktree)") }
        do {
            let repo = try Git.mainRepository(of: m.cwd!)
            // From the commit of the folder it is launched in: a lead in its own worktree hands its work on.
            let head = try? Git.runSync(["rev-parse", "--verify", "HEAD"], in: m.cwd!)
            m.cwd = try Git.addWorktreeSync(repo: repo, branch: branch, base: head)
            m.projectPath = repo
            m.branch = branch
        } catch {
            fail("worktree: \(error.localizedDescription)")
        }
    }
    let conn = connection()
    m.cols = 120
    m.rows = 32
    let r = call(conn, m)
    if json, let s = r.sessions?.first { printJSON(s) } else { print(r.id!.uuidString.lowercased()) }

case "send":
    let enter = flag("--enter")
    let conn = connection()
    let s = resolve(conn, args.first)
    var m = Message(type: "send", id: s.id)
    m.text = args.dropFirst().joined(separator: " ")
        .replacingOccurrences(of: "\\r", with: "\r")
        .replacingOccurrences(of: "\\n", with: "\n")
        .replacingOccurrences(of: "\\t", with: "\t")
        .replacingOccurrences(of: "\\e", with: "\u{1b}")
    m.enter = enter
    _ = call(conn, m)

case "ask":
    let timeout = Double(option("--timeout") ?? "") ?? 0
    let json = flag("--json")
    let conn = connection()
    let s = resolve(conn, args.first)
    let text = args.dropFirst().joined(separator: " ")
    guard !text.isEmpty else { fail("nothing to ask") }
    guard s.running else { fail("session \(short(s.id)) has exited") }
    // Its current turn would end first and be taken for the answer.
    guard s.status != "working" else { fail("session \(short(s.id)) is busy: `tly wait` for it first") }
    guard s.status != "paused" else { fail("session \(short(s.id)) is paused") }
    var m = Message(type: "send", id: s.id)
    m.text = text
    m.enter = true
    guard let sentAt = call(conn, m).turns else { fail("the running daemon is too old for `ask`; it updates once no session is running") }
    conn.discardEvents()
    let deadline = timeout > 0 ? Date().addingTimeInterval(timeout) : .distantFuture
    while true {
        guard let frame = (try? conn.nextFrame(before: deadline)) ?? nil else {
            if Date() >= deadline { FileHandle.standardError.write(Data("tly: timeout\n".utf8)); exit(3) }
            fail("daemon closed connection")
        }
        guard let e = frame.message, e.id == s.id else { continue }
        if e.type == "removed" { fail("session removed") }
        guard e.type == "status" else { continue }
        if (e.turns ?? 0) > sentAt {
            printResult(conn, s, json: json)
            exit(0)
        }
        if e.status == "needsInput" {
            FileHandle.standardError.write(Data("tly: session \(short(s.id)) needs input: \(e.detail ?? "waiting")\n".utf8))
            exit(2)
        }
        if e.status == "exited" { fail("session \(short(s.id)) exited") }
    }

case "result":
    let json = flag("--json")
    let conn = connection()
    printResult(conn, resolve(conn, args.first), json: json)

case "logs":
    let lines = Int(option("--lines") ?? "") ?? 200
    let conn = connection()
    let s = resolve(conn, args.first)
    var m = Message(type: "logs", id: s.id)
    m.lines = lines
    print(call(conn, m).text ?? "")

case "kill", "rm":
    let tree = flag("--tree")
    let conn = connection()
    let s = resolve(conn, args.first)
    var targets = [s.id]
    if tree {
        // Workers first: nothing is left reporting to a parent that is gone.
        let workers = (call(conn, Message(type: "list")).sessions ?? []).filter { $0.parent == s.id }.map(\.id)
        targets = workers + targets
    }
    for id in targets { _ = call(conn, Message(type: cmd == "kill" ? "kill" : "remove", id: id)) }

case "pause", "resume":
    let conn = connection()
    let s = resolve(conn, args.first)
    _ = call(conn, Message(type: cmd == "pause" ? "pause" : "continue", id: s.id))

case "wait":
    let timeout = Double(option("--timeout") ?? "") ?? 0
    let any = flag("--any")
    let json = flag("--json")
    let conn = connection()
    guard !args.isEmpty else { fail("missing session id") }
    let targets = args.map { resolve(conn, $0).id }
    var state: [UUID: SessionInfo] = [:]
    for s in call(conn, Message(type: "list")).sessions ?? [] where targets.contains(s.id) { state[s.id] = s }
    conn.discardEvents()
    let deadline = timeout > 0 ? Date().addingTimeInterval(timeout) : .distantFuture
    func done() -> [SessionInfo] { targets.compactMap { state[$0] }.filter { finished.contains($0.status) } }
    while any ? done().isEmpty : done().count < targets.count {
        guard let frame = (try? conn.nextFrame(before: deadline)) ?? nil else {
            fail(Date() >= deadline ? "timeout" : "daemon closed connection")
        }
        guard let e = frame.message, let id = e.id, state[id] != nil else { continue }
        if e.type == "removed" { fail("session removed") }
        guard e.type == "status", let status = e.status else { continue }
        state[id]!.status = status
        state[id]!.turns = e.turns ?? state[id]!.turns
        state[id]!.permission = e.permission
    }
    let out = done()
    if json {
        printJSON(out)
    } else if targets.count == 1 {
        print(out[0].status)
    } else {
        for s in out { print("\(short(s.id))  \(s.status)") }
    }
    exit(0)

case "attach":
    let conn = connection()
    let s = resolve(conn, args.first)
    AttachSession(conn: conn, session: s.id).run()

case "shutdown":
    guard let fd = try? UnixSocket.connect(TerminalyPaths.socket) else {
        print("not running")
        break
    }
    _ = call(SyncConnection(fd: fd), Message(type: "shutdown"))

case "-h", "--help", "help":
    print(usage)

default:
    fail("unknown command \(cmd)\n\n\(usage)")
}
