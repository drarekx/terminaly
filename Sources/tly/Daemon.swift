import Darwin
import Foundation
import TerminalyKit

/// Hosts every session in one process. Everything runs on `queue`; idle cost is zero
/// (kqueue-backed dispatch sources, no polling except a 30 s idle-exit check).
final class Daemon {
    let queue = DispatchQueue(label: "tly.daemon")
    private var sessions: [UUID: HostedSession] = [:]
    private var clients: [ObjectIdentifier: Client] = [:]
    private var listenSource: DispatchSourceRead?
    private let hooks = HookServer()
    private var idleSince = Date()
    private var idleTimer: DispatchSourceTimer?
    static let idleExitSeconds: TimeInterval = 60

    func run() -> Never {
        signal(SIGPIPE, SIG_IGN)
        signal(SIGHUP, SIG_IGN)

        let path = TerminalyPaths.socket
        if let fd = try? UnixSocket.connect(path) {
            close(fd)
            log("already running at \(path)")
            exit(0)
        }
        let lfd: Int32
        do {
            lfd = try UnixSocket.listen(path)
        } catch {
            log("listen failed: \(error)")
            exit(1)
        }
        UnixSocket.setNonBlocking(lfd)

        hooks.onEvent = { [weak self] id, event, payload in
            nonisolated(unsafe) let p = payload
            self?.queue.async { self?.sessions[id]?.hookEvent(event, payload: p) }
        }
        hooks.start()

        let ls = DispatchSource.makeReadSource(fileDescriptor: lfd, queue: queue)
        ls.setEventHandler { [weak self] in self?.accept(lfd) }
        listenSource = ls
        ls.resume()

        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 30, repeating: 30)
        t.setEventHandler { [weak self] in self?.checkIdle() }
        idleTimer = t
        t.resume()

        // Clean shutdown on SIGTERM/SIGINT: hang up all sessions.
        for sig in [SIGTERM, SIGINT] {
            signal(sig, SIG_IGN)
            let src = DispatchSource.makeSignalSource(signal: sig, queue: queue)
            src.setEventHandler { [weak self] in self?.shutdown() }
            src.resume()
            signalSources.append(src)
        }

        log("listening on \(path), hook port \(hooks.port.map(String.init) ?? "none"), pid \(getpid())")
        dispatchMain()
    }

    private var signalSources: [DispatchSourceSignal] = []

    private func shutdown() {
        log("shutting down")
        for s in sessions.values { s.terminate() }
        unlink(TerminalyPaths.socket)
        queue.asyncAfter(deadline: .now() + 0.5) { exit(0) }
    }

    private func checkIdle() {
        let busy = !clients.isEmpty || sessions.values.contains { $0.running }
        if busy {
            idleSince = Date()
        } else if Date().timeIntervalSince(idleSince) > Self.idleExitSeconds {
            log("idle, exiting")
            unlink(TerminalyPaths.socket)
            exit(0)
        }
    }

    // MARK: Clients

    private func accept(_ lfd: Int32) {
        while true {
            let fd = Darwin.accept(lfd, nil, nil)
            if fd < 0 { return }
            guard UnixSocket.peerIsSameUser(fd) else {
                close(fd)
                continue
            }
            var one: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
            UnixSocket.setNonBlocking(fd)
            let client = Client(fd: fd, queue: queue)
            client.onFrame = { [weak self, weak client] frame in
                guard let self, let client else { return }
                self.handle(frame, from: client)
            }
            client.onClose = { [weak self, weak client] in
                guard let self, let client else { return }
                self.clients[ObjectIdentifier(client)] = nil
            }
            clients[ObjectIdentifier(client)] = client
            client.start()
        }
    }

    private func broadcast(_ message: Message) {
        let bytes = Frame.json(message)
        for c in clients.values { c.send(bytes) }
    }

    private func handle(_ frame: Frame, from client: Client) {
        if let (id, bytes) = frame.sessionData, frame.kind == .input {
            sessions[id]?.write(bytes)
            return
        }
        guard let msg = frame.message else { return }
        var reply = Message(type: msg.type, reqID: msg.reqID, id: msg.id)

        switch msg.type {
        case "hello":
            reply.version = TerminalyPaths.protocolVersion

        case "list":
            reply.sessions = sessions.values.map(\.info).sorted { $0.createdAt < $1.createdAt }

        case "create":
            let id = msg.id ?? UUID()
            if let existing = sessions[id], existing.running {
                reply.error = "session already running"
                break
            }
            let s = HostedSession(id: id, command: msg.command ?? "", cwd: msg.cwd ?? NSHomeDirectory(), queue: queue)
            wire(s)
            guard s.start(cols: msg.cols ?? 80, rows: msg.rows ?? 24, hookPort: hooks.port, hookToken: hooks.token) else {
                reply.error = "spawn failed"
                break
            }
            sessions[id] = s
            reply.id = id
            reply.sessions = [s.info]
            var event = Message(type: "sessions")
            event.sessions = [s.info]
            broadcast(event)

        case "attach":
            guard let id = msg.id, let s = sessions[id] else { reply.error = "no such session"; break }
            client.attached.insert(id)
            // Reply first so the client creates its view, then the replay, then live output.
            reply.sessions = [s.info]
            client.send(Frame.json(reply))
            client.send(Frame.data(.output, session: id, bytes: s.replay))
            return

        case "detach":
            if let id = msg.id { client.attached.remove(id) }

        case "resize":
            if let id = msg.id { sessions[id]?.resize(cols: msg.cols ?? 80, rows: msg.rows ?? 24) }

        case "send":
            guard let id = msg.id, let s = sessions[id] else { reply.error = "no such session"; break }
            var text = msg.text ?? ""
            if msg.enter == true { text += "\r" }
            s.write(Array(text.utf8))

        case "kill":
            guard let id = msg.id, let s = sessions[id] else { reply.error = "no such session"; break }
            s.terminate()

        case "remove":
            guard let id = msg.id, let s = sessions.removeValue(forKey: id) else { reply.error = "no such session"; break }
            s.onOutput = nil
            s.onStatus = nil
            s.onExit = nil
            s.terminate()
            broadcast(Message(type: "removed", id: id))

        case "logs":
            guard let id = msg.id, let s = sessions[id] else { reply.error = "no such session"; break }
            let text = String(decoding: s.replay, as: UTF8.self)
            let lines = text.components(separatedBy: "\n").suffix(msg.lines ?? 200)
            reply.text = lines.joined(separator: "\n")

        case "shutdown":
            client.send(Frame.json(reply))
            shutdown()
            return

        default:
            reply.error = "unknown request \(msg.type)"
        }
        client.send(Frame.json(reply))
    }

    private func wire(_ s: HostedSession) {
        s.onOutput = { [weak self] session, bytes in
            guard let self else { return }
            let frame = Frame.data(.output, session: session.id, bytes: bytes)
            for c in self.clients.values where c.attached.contains(session.id) { c.send(frame) }
        }
        s.onStatus = { [weak self] session, detail, notify in
            var m = Message(type: "status", id: session.id)
            m.status = session.status
            m.detail = detail
            m.notify = notify
            m.exitCode = session.exitCode
            m.permission = session.permissionPending
            m.agentSessionID = session.agentSessionID
            self?.broadcast(m)
        }
        s.onExit = { [weak self] session in
            self?.log("session \(session.id) exited code=\(session.exitCode.map(String.init) ?? "signal")")
        }
    }

    func log(_ s: String) {
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(s)\n"
        FileHandle.standardError.write(Data(line.utf8))
    }
}

/// One connected app/CLI.
final class Client {
    let fd: Int32
    private let queue: DispatchQueue
    private var readSource: DispatchSourceRead?
    private let writer: SocketWriter
    private var decoder = FrameDecoder()
    var attached: Set<UUID> = []
    var onFrame: ((Frame) -> Void)?
    var onClose: (() -> Void)?
    private var closed = false
    /// A client that stops reading gets dropped instead of growing memory without bound.
    static let maxBacklog = 8 * 1024 * 1024

    init(fd: Int32, queue: DispatchQueue) {
        self.fd = fd
        self.queue = queue
        writer = SocketWriter(fd: fd, queue: queue)
    }

    func start() {
        let rs = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        rs.setEventHandler { [weak self] in self?.readAvailable() }
        rs.setCancelHandler { [fd] in Darwin.close(fd) }
        readSource = rs
        rs.resume()
    }

    private func readAvailable() {
        var buf = [UInt8](repeating: 0, count: 65536)
        let n = buf.withUnsafeMutableBytes { read(fd, $0.baseAddress, 65536) }
        if n > 0 {
            do {
                let frames = try buf.withUnsafeBytes { try decoder.append(UnsafeRawBufferPointer(rebasing: $0[0..<n])) }
                for f in frames { onFrame?(f) }
            } catch {
                close()
            }
        } else if n == 0 || (errno != EAGAIN && errno != EINTR) {
            close()
        }
    }

    func send(_ bytes: [UInt8]) {
        guard !closed else { return }
        writer.send(bytes)
        if writer.failed || writer.backlog > Self.maxBacklog { close() }
    }

    func close() {
        guard !closed else { return }
        closed = true
        writer.cancel()
        readSource?.cancel()
        readSource = nil
        onClose?()
    }
}
