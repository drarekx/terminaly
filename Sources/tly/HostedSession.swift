import Darwin
import Foundation
import TerminalyKit

/// One PTY-backed session. All methods run on the daemon queue.
final class HostedSession {
    let id: UUID
    let command: String
    let cwd: String
    let createdAt = Date()
    /// Swarm: who started this session, its display name, and the prompt its command was started with.
    let parent: UUID?
    let title: String?
    let prompt: String?
    let projectPath: String?
    let branch: String?
    /// Finished turns, and what the agent said (or the shell printed) in the last one.
    private(set) var turns = 0
    private(set) var result: String?
    private var turnOutput: [UInt8] = []
    private var hookSeq = 0
    private(set) var pid: pid_t = 0
    private(set) var running = false
    private(set) var exitCode: Int32?
    private(set) var status = "starting"
    private(set) var permissionPending = false
    private(set) var agentSessionID: String?
    private(set) var detail: String?
    private(set) var paused = false
    private var statusBeforePause = "idle"
    private var detailBeforePause: String?
    private var master: Int32 = -1
    private var readSource: DispatchSourceRead?
    private var writeSource: DispatchSourceWrite?
    private var pendingInput: [UInt8] = []
    private var exitSource: DispatchSourceProcess?
    private var ring = RingBuffer(capacity: 2 * 1024 * 1024)
    private var hookDriven = false
    private var quietTimer: DispatchWorkItem?
    private let queue: DispatchQueue

    var onOutput: ((HostedSession, ArraySlice<UInt8>) -> Void)?
    var onStatus: ((HostedSession, _ detail: String?, _ notify: Bool) -> Void)?
    var onExit: ((HostedSession) -> Void)?

    init(id: UUID, command: String, cwd: String, queue: DispatchQueue, parent: UUID? = nil, title: String? = nil,
         prompt: String? = nil, projectPath: String? = nil, branch: String? = nil) {
        self.id = id
        self.command = command
        self.cwd = cwd
        self.queue = queue
        self.parent = parent
        self.title = title
        self.prompt = prompt
        self.projectPath = projectPath
        self.branch = branch
        // It starts with work to do: "idle" must mean the prompt was answered, not that the agent just opened.
        if prompt != nil { status = "working" }
    }

    var info: SessionInfo {
        SessionInfo(id: id, command: command, cwd: cwd, pid: pid, running: running,
                    status: status, exitCode: exitCode, createdAt: createdAt,
                    permission: permissionPending, agentSessionID: agentSessionID, parent: parent, title: title,
                    projectPath: projectPath, branch: branch, turns: turns)
    }

    var replay: [UInt8] { ring.contents }

    func start(cols: Int, rows: Int, hookPort: UInt16?, hookToken: String) -> Bool {
        var env = ProcessInfo.processInfo.environment
        let shell = env["SHELL"] ?? "/bin/zsh"
        let shellName = (shell as NSString).lastPathComponent
        var args = ["-\(shellName)"]  // argv[0] with leading dash = login shell
        if !command.isEmpty {
            // Interactive so aliases resolve; fall back to a shell when the command exits.
            let line = prompt.map { "\(command)\(Self.promptFlag(for: command)) \(Self.shellQuote($0))" } ?? command
            args += ["-i", "-c", "\(line); exec \(shell) -l"]
        }
        env["TERM"] = "xterm-256color"
        env["COLORTERM"] = "truecolor"
        env["TERM_PROGRAM"] = "Terminaly"
        env["TERMINALY_SESSION_ID"] = id.uuidString
        // Agents drive their workers with `tly`; last in PATH so it never shadows anything.
        let bin = URL(fileURLWithPath: selfPath).deletingLastPathComponent().path
        env["PATH"] = (env["PATH"].map { "\($0):" } ?? "/usr/bin:/bin:") + bin
        if let hookPort {
            env["TERMINALY_HOOK_PORT"] = String(hookPort)
            env["TERMINALY_HOOK_TOKEN"] = hookToken
        }
        let cwd = FileManager.default.fileExists(atPath: self.cwd) ? self.cwd : NSHomeDirectory()
        guard let (pid, master) = Pty.spawn(executable: shell, args: args,
                                             env: env.map { "\($0.key)=\($0.value)" },
                                             cwd: cwd, cols: cols, rows: rows) else { return false }
        self.pid = pid
        self.master = master
        running = true
        UnixSocket.setNonBlocking(master)

        let rs = DispatchSource.makeReadSource(fileDescriptor: master, queue: queue)
        rs.setEventHandler { [weak self] in self?.readAvailable() }
        rs.setCancelHandler { close(master) }
        readSource = rs
        rs.resume()

        let es = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: queue)
        es.setEventHandler { [weak self] in self?.reap() }
        exitSource = es
        es.resume()
        return true
    }

    /// Most agents take the first prompt as their argument; opencode takes a folder there.
    static func promptFlag(for command: String) -> String {
        let words = command.split(separator: " ")
        let name = words.first.map { ($0 as NSString).lastPathComponent } ?? ""
        return name == "opencode" && !words.contains("--prompt") ? " --prompt" : ""
    }

    static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private func readAvailable() {
        var buf = [UInt8](repeating: 0, count: 65536)
        while true {
            let n = buf.withUnsafeMutableBytes { read(master, $0.baseAddress, 65536) }
            if n > 0 {
                let slice = buf[0..<n]
                ring.append(slice)
                if !hookDriven { captureTurnOutput(slice) }
                onOutput?(self, slice)
                outputActivity()
                if n < 65536 { return }
            } else if n < 0 && errno == EINTR {
                continue
            } else {
                // EAGAIN: drained. 0/EIO: slave closed (child gone); exit source handles cleanup.
                if n == 0 || (n < 0 && errno != EAGAIN) {
                    // The read source owns the fd: stop writing before it closes it.
                    writeSource?.cancel(); writeSource = nil; pendingInput.removeAll()
                    readSource?.cancel(); readSource = nil
                }
                return
            }
        }
    }

    private func reap() {
        var st: Int32 = 0
        guard waitpid(pid, &st, WNOHANG) == pid else { return }
        let exited = (st & 0x7f) == 0
        exitCode = exited ? (st >> 8) & 0xff : nil
        // Drain output written right before exit, then release the PTY.
        if readSource != nil { readAvailable() }
        readSource?.cancel()
        readSource = nil
        exitSource?.cancel()
        exitSource = nil
        writeSource?.cancel()
        writeSource = nil
        pendingInput.removeAll()
        running = false
        paused = false
        quietTimer?.cancel()
        setStatus("exited")
        onExit?(self)
    }

    /// Never blocks: the daemon queue serves every session, and a child that stops reading
    /// (paused, hung) would otherwise freeze the daemon and deadlock with its own output.
    func write(_ bytes: some Collection<UInt8>) {
        // Keys sent to a stopped tree would pile up and flood it on resume.
        guard running, !paused else { return }
        pendingInput.append(contentsOf: bytes)
        if pendingInput.count > Self.maxPendingInput {
            pendingInput.removeFirst(pendingInput.count - Self.maxPendingInput)
        }
        flushInput()
    }

    private static let maxPendingInput = 1 << 20

    private func flushInput() {
        while !pendingInput.isEmpty {
            let n = pendingInput.withUnsafeBytes { Darwin.write(master, $0.baseAddress!, $0.count) }
            if n > 0 {
                pendingInput.removeFirst(n)
            } else if n < 0 && errno == EINTR {
                continue
            } else if n < 0 && errno == EAGAIN {
                if writeSource == nil {
                    let ws = DispatchSource.makeWriteSource(fileDescriptor: master, queue: queue)
                    ws.setEventHandler { [weak self] in self?.flushInput() }
                    writeSource = ws
                    ws.resume()
                }
                return
            } else {
                pendingInput.removeAll()
                break
            }
        }
        writeSource?.cancel()
        writeSource = nil
    }

    func resize(cols: Int, rows: Int) {
        guard running, cols > 0, rows > 0 else { return }
        Pty.resize(master, cols: cols, rows: rows)
    }

    /// SIGHUP to the session's process group, SIGKILL if still alive after 2 s.
    func terminate() {
        guard running else { return }
        let pid = self.pid
        kill(-pid, SIGHUP)
        kill(pid, SIGHUP)
        // A stopped process only acts on SIGHUP once continued.
        if paused { signalTree(SIGCONT) }
        queue.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self, self.running, self.pid == pid else { return }
            kill(-pid, SIGKILL)
            kill(pid, SIGKILL)
        }
    }

    // MARK: Pause

    /// SIGSTOP to the whole process tree: no CPU until continued, memory stays (macOS compresses it).
    /// The tree is walked by parent pid because agents put helpers (MCP servers…) in other process groups.
    func pause() {
        guard running, !paused else { return }
        paused = true
        statusBeforePause = status == "working" ? "idle" : status
        detailBeforePause = detail
        quietTimer?.cancel()
        signalTree(SIGSTOP)
        setStatus("paused")
    }

    func resume() {
        guard running, paused else { return }
        paused = false
        signalTree(SIGCONT)
        // Full-screen agents redraw on a size change.
        let fg = tcgetpgrp(master)
        if fg > 0 { kill(-fg, SIGWINCH) }
        setStatus(statusBeforePause, detail: detailBeforePause, quiet: true)
    }

    /// Parents are stopped before children (a shell must not see its job stop and take the
    /// terminal back) and continued after them.
    private func signalTree(_ sig: Int32) {
        var pids = ProcessStats.tree(of: pid, parents: ProcessStats.parentMap())
        if sig == SIGCONT { pids.reverse() }
        for p in pids { kill(p, sig) }
    }

    // MARK: Status

    private func outputActivity() {
        guard !hookDriven, running, !paused else { return }
        if status != "working" { setStatus("working") }
        quietTimer?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let text = Self.plainText(self.turnOutput)
            self.finishTurn(result: text.isEmpty ? nil : text, idle: true)
        }
        quietTimer = item
        queue.asyncAfter(deadline: .now() + 2, execute: item)
    }

    func hookEvent(_ event: String, payload: [String: Any]) {
        guard running, !paused else { return }
        hookDriven = true
        hookSeq += 1
        turnOutput.removeAll()
        quietTimer?.cancel()
        if let sid = payload["session_id"] as? String, !sid.isEmpty { agentSessionID = sid }
        switch event {
        case "UserPromptSubmit", "PreToolUse", "PostToolUse", "SubagentStop":
            permissionPending = false
            setStatus("working")
        case "PermissionRequest":
            permissionPending = true
            let tool = payload["tool_name"] as? String
            setStatus("needsInput", detail: tool.map { "Permission: \($0)" } ?? payload["message"] as? String)
        case "Notification":
            let message = payload["message"] as? String
            // Claude sends "…needs your permission to use X" alongside PermissionRequest,
            // and "…waiting for your input" when idle.
            permissionPending = permissionPending || (message?.localizedCaseInsensitiveContains("permission") ?? false)
            setStatus("needsInput", detail: message)
        case "Stop":
            permissionPending = false
            if let text = payload["last_assistant_message"] as? String {
                finishTurn(result: text, idle: true)
            } else if let path = payload["transcript_path"] as? String {
                // Older agents only give the transcript; reading it must not hold the daemon queue.
                let seq = hookSeq
                DispatchQueue.global(qos: .utility).async { [weak self] in
                    let text = Transcript.lastAssistantText(path)
                    self?.queue.async {
                        guard let self else { return }
                        // A prompt sent meanwhile already moved the status on.
                        self.finishTurn(result: text, idle: self.hookSeq == seq)
                    }
                }
            } else {
                finishTurn(result: nil, idle: true)
            }
        case "SessionStart":
            permissionPending = false
            // Started with a prompt: still on its first turn, which ends with Stop.
            if prompt == nil || turns > 0 { setStatus("idle") }
        case "SessionEnd":
            hookDriven = false
        default:
            break
        }
    }

    /// The status event of a finished turn always goes out: waiters watch the turn count, not the status.
    private func finishTurn(result: String?, idle: Bool) {
        guard running else { return }
        turns += 1
        self.result = result
        turnOutput.removeAll()
        if idle && !paused {
            setStatus("idle", force: true)
        } else {
            onStatus?(self, detail, false)
        }
    }

    private static let maxTurnOutput = 256 * 1024

    private func captureTurnOutput(_ bytes: ArraySlice<UInt8>) {
        turnOutput.append(contentsOf: bytes)
        if turnOutput.count > Self.maxTurnOutput * 2 { turnOutput.removeFirst(turnOutput.count - Self.maxTurnOutput) }
    }

    private static let escapes = try! NSRegularExpression(
        pattern: "\u{1B}\\[[0-9;?<=>]*[ -/]*[@-~]|\u{1B}\\][^\u{07}\u{1B}]*(?:\u{07}|\u{1B}\\\\)?|\u{1B}[()][0-9A-Za-z]|\u{1B}[@-Z\\\\^_=>]|[\\x00-\\x08\\x0B-\\x1F\\x7F]")

    /// Terminal output without escape sequences or control characters.
    static func plainText(_ bytes: [UInt8]) -> String {
        let raw = String(decoding: bytes, as: UTF8.self)
        let text = escapes.stringByReplacingMatches(in: raw, range: NSRange(raw.startIndex..., in: raw), withTemplate: "")
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func setStatus(_ new: String, detail: String? = nil, quiet: Bool = false, force: Bool = false) {
        let old = status
        self.detail = detail
        if old == new && new != "needsInput" && !force { return }
        status = new
        // Notifications only for hook-driven sessions; output heuristics are too noisy.
        let notify = !quiet && hookDriven && (new == "needsInput" || (new == "idle" && old == "working"))
        onStatus?(self, detail, notify)
    }
}

/// Fixed-capacity byte ring keeping the most recent output for replay on attach.
struct RingBuffer {
    private var storage: [UInt8] = []
    private var head = 0  // index of oldest byte once full
    let capacity: Int

    init(capacity: Int) { self.capacity = capacity }

    mutating func append(_ bytes: ArraySlice<UInt8>) {
        if storage.count < capacity {
            let room = capacity - storage.count
            storage.append(contentsOf: bytes.prefix(room))
            let rest = bytes.dropFirst(room)
            if !rest.isEmpty { append(rest) }
            return
        }
        var src = bytes.suffix(capacity)
        while !src.isEmpty {
            let n = min(capacity - head, src.count)
            storage.replaceSubrange(head..<(head + n), with: src.prefix(n))
            head = (head + n) % capacity
            src = src.dropFirst(n)
        }
    }

    var contents: [UInt8] {
        storage.count < capacity ? storage : Array(storage[head...] + storage[..<head])
    }
}

/// Reads an agent transcript (JSON lines) for sessions whose Stop hook doesn't carry the last message.
enum Transcript {
    static func lastAssistantText(_ path: String) -> String? {
        guard let fh = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? fh.close() }
        let size = (try? fh.seekToEnd()) ?? 0
        let tail: UInt64 = 512 * 1024
        try? fh.seek(toOffset: size > tail ? size - tail : 0)
        guard let data = try? fh.readToEnd() else { return nil }
        for line in data.split(separator: UInt8(ascii: "\n")).reversed() {
            guard let obj = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
                  obj["type"] as? String == "assistant",
                  let content = (obj["message"] as? [String: Any])?["content"] as? [[String: Any]] else { continue }
            let text = content.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }.joined(separator: "\n")
            if !text.isEmpty { return text }
        }
        return nil
    }
}
