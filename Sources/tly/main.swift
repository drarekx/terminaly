import Darwin
import Foundation
import TerminalyKit

let usage = """
tly — Terminaly session host

  tly daemon                         run the session host (started automatically)
  tly ls [--json]                    list sessions
  tly new [--cwd DIR] [--command CMD] [--json]
  tly send <id> <text...> [--enter]  type text into a session
  tly logs <id> [--lines N]          recent output (raw)
  tly attach <id>                    attach this terminal (detach: Ctrl-\\)
  tly wait <id> [--timeout S]        block until the session is idle or needs input
  tly kill <id>                      hang up a session
  tly rm <id>                        kill and forget a session
  tly shutdown                       stop the host and all sessions

<id> may be any unique prefix of the session UUID.
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

case "ls":
    let json = flag("--json")
    let conn = connection()
    let list = call(conn, Message(type: "list")).sessions ?? []
    if json { printJSON(list) ; break }
    if list.isEmpty { print("no sessions") }
    for s in list {
        let id = String(s.id.uuidString.prefix(8)).lowercased()
        let cmd = s.command.isEmpty ? "(shell)" : s.command
        let cwd = (s.cwd as NSString).abbreviatingWithTildeInPath
        print("\(id)  \(s.status.padding(toLength: 10, withPad: " ", startingAt: 0))  \(cmd)  \(cwd)")
    }

case "new":
    let cwd = option("--cwd") ?? FileManager.default.currentDirectoryPath
    let command = option("--command") ?? ""
    let json = flag("--json")
    let conn = connection()
    var m = Message(type: "create")
    m.cwd = (cwd as NSString).expandingTildeInPath
    m.command = command
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

case "logs":
    let lines = Int(option("--lines") ?? "") ?? 200
    let conn = connection()
    let s = resolve(conn, args.first)
    var m = Message(type: "logs", id: s.id)
    m.lines = lines
    print(call(conn, m).text ?? "")

case "kill", "rm":
    let conn = connection()
    let s = resolve(conn, args.first)
    _ = call(conn, Message(type: cmd == "kill" ? "kill" : "remove", id: s.id))

case "wait":
    let timeout = Double(option("--timeout") ?? "") ?? 0
    let conn = connection()
    let target = resolve(conn, args.first)
    let deadline = timeout > 0 ? Date().addingTimeInterval(timeout) : .distantFuture
    while Date() < deadline {
        let s = (call(conn, Message(type: "list")).sessions ?? []).first { $0.id == target.id }
        guard let s else { fail("session removed") }
        if ["idle", "needsInput", "exited"].contains(s.status) {
            print(s.status)
            exit(0)
        }
        usleep(250_000)
    }
    fail("timeout")

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
