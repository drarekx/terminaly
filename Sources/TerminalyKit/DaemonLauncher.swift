import Darwin
import Foundation

public enum DaemonLauncher {
    /// Connects to the daemon, starting `tlyPath daemon` detached if nothing is listening.
    public static func connect(tlyPath: String, timeout: TimeInterval = 3) throws -> Int32 {
        if let fd = try? UnixSocket.connect(TerminalyPaths.socket) { return fd }
        try spawnDaemon(tlyPath: tlyPath)
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            usleep(50_000)
            if let fd = try? UnixSocket.connect(TerminalyPaths.socket) { return fd }
        }
        return try UnixSocket.connect(TerminalyPaths.socket)
    }

    /// New session (setsid) so the daemon outlives the app and its terminal; output to tly.log.
    static func spawnDaemon(tlyPath: String) throws {
        try spawnDetached(tlyPath: tlyPath, arguments: ["daemon"], log: TerminalyPaths.log)
    }

    /// Runs `tlyPath arguments…` in its own session with stdin from /dev/null and output appended to `log`.
    @discardableResult
    public static func spawnDetached(tlyPath: String, arguments: [String], log: String) throws -> pid_t {
        var attr: posix_spawnattr_t?
        posix_spawnattr_init(&attr)
        defer { posix_spawnattr_destroy(&attr) }
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT))

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_addopen(&actions, 1, log, O_WRONLY | O_CREAT | O_APPEND, 0o600)
        posix_spawn_file_actions_adddup2(&actions, 1, 2)

        let args = [tlyPath] + arguments
        let cArgs = args.map { strdup($0) } + [nil]
        defer { cArgs.forEach { free($0) } }
        var pid: pid_t = 0
        let rc = cArgs.withUnsafeBufferPointer { argv in
            posix_spawn(&pid, tlyPath, &actions, &attr,
                        UnsafeMutablePointer(mutating: argv.baseAddress!), environ)
        }
        guard rc == 0 else { throw UnixSocket.SocketError.sys("posix_spawn \(tlyPath)", rc) }
        return pid
    }
}

/// Blocking request/response connection, used by the CLI.
public final class SyncConnection {
    public let fd: Int32
    private var decoder = FrameDecoder()
    private var nextID = 1
    /// Frames decoded from the socket but not yet read.
    private var incoming: [Frame] = []
    /// Non-reply frames that arrived while waiting for a reply.
    private var events: [Frame] = []

    public init(fd: Int32) { self.fd = fd }

    deinit { close(fd) }

    public func request(_ msg: Message) throws -> Message {
        var m = msg
        m.reqID = nextID
        nextID += 1
        guard UnixSocket.writeAll(fd, Frame.json(m)) else { throw UnixSocket.SocketError.sys("write", errno) }
        while true {
            let frame = try readFrame()
            if let reply = frame.message, reply.reqID == m.reqID { return reply }
            events.append(frame)
        }
    }

    public func send(_ bytes: [UInt8]) -> Bool { UnixSocket.writeAll(fd, bytes) }

    /// Next frame not consumed as a reply.
    public func nextFrame() throws -> Frame {
        if !events.isEmpty { return events.removeFirst() }
        return try readFrame()
    }

    /// Next event, or nil once `deadline` passes.
    public func nextFrame(before deadline: Date) throws -> Frame? {
        if !events.isEmpty { return events.removeFirst() }
        if !incoming.isEmpty { return incoming.removeFirst() }
        while true {
            let left = deadline.timeIntervalSinceNow
            guard left > 0 else { return nil }
            var p = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let rc = poll(&p, 1, Int32(min(left * 1000, 60_000).rounded(.up)))
            if rc > 0 { return try readFrame() }
            if rc < 0 && errno != EINTR { throw UnixSocket.SocketError.sys("poll", errno) }
        }
    }

    /// Forgets events that arrived before the last reply: they describe state older than that reply.
    public func discardEvents() { events.removeAll() }

    private func readFrame() throws -> Frame {
        if !incoming.isEmpty { return incoming.removeFirst() }
        var buf = [UInt8](repeating: 0, count: 65536)
        while true {
            let n = buf.withUnsafeMutableBytes { read(fd, $0.baseAddress, 65536) }
            if n < 0 && errno == EINTR { continue }
            guard n > 0 else { throw UnixSocket.SocketError.sys("daemon closed connection", errno) }
            let frames = try buf.withUnsafeBytes { try decoder.append(UnsafeRawBufferPointer(rebasing: $0[0..<n])) }
            incoming.append(contentsOf: frames)
            if !incoming.isEmpty { return incoming.removeFirst() }
        }
    }
}
