import Darwin
import Foundation
import TerminalyKit

/// One PTY-backed session. All methods run on the daemon queue.
final class HostedSession {
    let id: UUID
    let command: String
    let cwd: String
    let createdAt = Date()
    private(set) var pid: pid_t = 0
    private(set) var running = false
    private(set) var exitCode: Int32?
    private(set) var status = "starting"
    private var master: Int32 = -1
    private var readSource: DispatchSourceRead?
    private var exitSource: DispatchSourceProcess?
    private var ring = RingBuffer(capacity: 2 * 1024 * 1024)
    private var hookDriven = false
    private var quietTimer: DispatchWorkItem?
    private let queue: DispatchQueue

    var onOutput: ((HostedSession, ArraySlice<UInt8>) -> Void)?
    var onStatus: ((HostedSession, _ detail: String?, _ notify: Bool) -> Void)?
    var onExit: ((HostedSession) -> Void)?

    init(id: UUID, command: String, cwd: String, queue: DispatchQueue) {
        self.id = id
        self.command = command
        self.cwd = cwd
        self.queue = queue
    }

    var info: SessionInfo {
        SessionInfo(id: id, command: command, cwd: cwd, pid: pid, running: running,
                    status: status, exitCode: exitCode, createdAt: createdAt)
    }

    var replay: [UInt8] { ring.contents }

    func start(cols: Int, rows: Int, hookPort: UInt16?, hookToken: String) -> Bool {
        var env = ProcessInfo.processInfo.environment
        let shell = env["SHELL"] ?? "/bin/zsh"
        let shellName = (shell as NSString).lastPathComponent
        var args = ["-\(shellName)"]  // argv[0] with leading dash = login shell
        if !command.isEmpty {
            // Interactive so aliases resolve; fall back to a shell when the command exits.
            args += ["-i", "-c", "\(command); exec \(shell) -l"]
        }
        env["TERM"] = "xterm-256color"
        env["COLORTERM"] = "truecolor"
        env["TERM_PROGRAM"] = "Terminaly"
        env["TERMINALY_SESSION_ID"] = id.uuidString
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

    private func readAvailable() {
        var buf = [UInt8](repeating: 0, count: 65536)
        while true {
            let n = buf.withUnsafeMutableBytes { read(master, $0.baseAddress, 65536) }
            if n > 0 {
                let slice = buf[0..<n]
                ring.append(slice)
                onOutput?(self, slice)
                outputActivity()
                if n < 65536 { return }
            } else if n < 0 && errno == EINTR {
                continue
            } else {
                // EAGAIN: drained. 0/EIO: slave closed (child gone); exit source handles cleanup.
                if n == 0 || (n < 0 && errno != EAGAIN) { readSource?.cancel(); readSource = nil }
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
        running = false
        quietTimer?.cancel()
        setStatus("exited")
        onExit?(self)
    }

    func write(_ bytes: some Collection<UInt8>) {
        guard running else { return }
        let arr = Array(bytes)
        var off = 0
        while off < arr.count {
            let n = arr.withUnsafeBytes { Darwin.write(master, $0.baseAddress! + off, arr.count - off) }
            if n > 0 { off += n }
            else if n < 0 && (errno == EINTR || errno == EAGAIN) { usleep(1000) }
            else { return }
        }
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
        queue.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self, self.running, self.pid == pid else { return }
            kill(-pid, SIGKILL)
            kill(pid, SIGKILL)
        }
    }

    // MARK: Status

    private func outputActivity() {
        guard !hookDriven, running else { return }
        if status != "working" { setStatus("working") }
        quietTimer?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.setStatus("idle") }
        quietTimer = item
        queue.asyncAfter(deadline: .now() + 2, execute: item)
    }

    func hookEvent(_ event: String, payload: [String: Any]) {
        guard running else { return }
        hookDriven = true
        quietTimer?.cancel()
        switch event {
        case "UserPromptSubmit", "PreToolUse", "PostToolUse", "SubagentStop":
            setStatus("working")
        case "Notification", "PermissionRequest":
            setStatus("needsInput", detail: payload["message"] as? String)
        case "Stop", "SessionStart":
            setStatus("idle")
        case "SessionEnd":
            hookDriven = false
        default:
            break
        }
    }

    private func setStatus(_ new: String, detail: String? = nil) {
        let old = status
        if old == new && new != "needsInput" { return }
        status = new
        // Notifications only for hook-driven sessions; output heuristics are too noisy.
        let notify = hookDriven && (new == "needsInput" || (new == "idle" && old == "working"))
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
