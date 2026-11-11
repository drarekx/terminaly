import CryptoKit
import Darwin
import Foundation
import Network
import TerminalyKit

/// `tly web`: serves the browser UI on the local network and bridges each WebSocket to its own
/// daemon connection. It runs apart from the daemon so a slow or buggy browser can never stall
/// the queue every session shares, and it holds no daemon connection while nobody is connected.
final class WebServer {
    private let config: WebConfig
    private let webRoot: URL
    private let queue = DispatchQueue(label: "tly.web")
    private var listener: NWListener?
    private var bridges: [ObjectIdentifier: WebBridge] = [:]
    private var failedLogins: [Date] = []
    private var signalSources: [DispatchSourceSignal] = []

    /// Files the page may load; anything else is a 404, so no path ever reaches the filesystem.
    private static let files: [String: (name: String, type: String)] = [
        "/": ("index.html", "text/html; charset=utf-8"),
        "/index.html": ("index.html", "text/html; charset=utf-8"),
        "/app.js": ("app.js", "text/javascript; charset=utf-8"),
        "/app.css": ("app.css", "text/css; charset=utf-8"),
        "/xterm.js": ("xterm.js", "text/javascript; charset=utf-8"),
        "/xterm.css": ("xterm.css", "text/css; charset=utf-8"),
        "/addon-fit.js": ("addon-fit.js", "text/javascript; charset=utf-8"),
        "/icon.svg": ("icon.svg", "image/svg+xml"),
    ]

    /// Daemon requests a browser may send. Creating, killing and removing sessions stay in the app.
    static let allowedRequests: Set<String> = ["hello", "list", "attach", "detach", "resize", "send", "pause", "continue"]

    init(config: WebConfig, webRoot: URL) {
        self.config = config
        self.webRoot = webRoot
    }

    /// The web files live in the app bundle (Contents/Resources/web) or, for `swift build`, in the repo.
    static func findWebRoot() -> URL? {
        if let dir = ProcessInfo.processInfo.environment["TERMINALY_WEB_DIR"] { return URL(fileURLWithPath: dir) }
        var dir = URL(fileURLWithPath: selfPath).deletingLastPathComponent()
        let bundled = dir.deletingLastPathComponent().appendingPathComponent("Resources/web")
        if FileManager.default.fileExists(atPath: bundled.appendingPathComponent("index.html").path) { return bundled }
        while dir.path != "/" {
            let candidate = dir.appendingPathComponent("Resources/web")
            if FileManager.default.fileExists(atPath: candidate.appendingPathComponent("index.html").path) { return candidate }
            dir = dir.deletingLastPathComponent()
        }
        return nil
    }

    func run() -> Never {
        signal(SIGPIPE, SIG_IGN)
        let lockFD = open(TerminalyPaths.stateDir.appendingPathComponent("web.lock").path, O_CREAT | O_RDWR, 0o600)
        guard lockFD >= 0, flock(lockFD, LOCK_EX | LOCK_NB) == 0 else {
            log("already running")
            exit(0)
        }
        guard let port = NWEndpoint.Port(rawValue: UInt16(clamping: config.port)), config.port > 0 else {
            log("invalid port \(config.port)")
            exit(1)
        }
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        let listener: NWListener
        do {
            listener = try NWListener(using: params, on: port)
        } catch {
            log("listen failed: \(error)")
            exit(1)
        }
        listener.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                self?.log("listening on port \(port.rawValue), pid \(getpid()), files \(self?.webRoot.path ?? "")")
            case .failed(let error):
                self?.log("listener failed: \(error)")
                exit(1)
            default:
                break
            }
        }
        listener.newConnectionHandler = { [weak self] conn in self?.accept(conn) }
        listener.start(queue: queue)
        self.listener = listener

        try? "\(getpid())\n".write(to: WebConfig.pidURL, atomically: true, encoding: .utf8)
        for sig in [SIGTERM, SIGINT] {
            signal(sig, SIG_IGN)
            let src = DispatchSource.makeSignalSource(signal: sig, queue: queue)
            src.setEventHandler { [weak self] in
                self?.log("stopping")
                if WebConfig.runningPID == getpid() { try? FileManager.default.removeItem(at: WebConfig.pidURL) }
                exit(0)
            }
            src.resume()
            signalSources.append(src)
        }
        dispatchMain()
    }

    // MARK: HTTP

    private func accept(_ conn: NWConnection) {
        conn.start(queue: queue)
        readRequest(conn, buffer: Data())
    }

    private func readRequest(_ conn: NWConnection, buffer: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, done, error in
            guard let self else { return }
            var buf = buffer
            if let data { buf.append(data) }
            if let request = HTTPRequest(buf) {
                // Whatever follows the headers already belongs to the WebSocket stream.
                let headerEnd = buf.range(of: Data("\r\n\r\n".utf8))!.upperBound
                let leftover = [UInt8](buf[headerEnd...].dropFirst(request.body.count))
                self.route(request, conn: conn, leftover: leftover)
            } else if done || error != nil || buf.count > 64 * 1024 {
                conn.cancel()
            } else {
                self.readRequest(conn, buffer: buf)
            }
        }
    }

    private func route(_ req: HTTPRequest, conn: NWConnection, leftover: [UInt8]) {
        let path = String(req.path.split(separator: "?", maxSplits: 1).first ?? "")
        let host = req.headers["host"] ?? ""
        guard req.method == "GET" else { return respond(conn, status: "405 Method Not Allowed") }

        if path == "/ws" {
            // Another site open in the same browser must not be able to reach the sessions.
            if let origin = req.headers["origin"], URL(string: origin)?.hostPort != host {
                return respond(conn, status: "403 Forbidden")
            }
            guard req.headers["upgrade"]?.lowercased() == "websocket", let key = req.headers["sec-websocket-key"] else {
                return respond(conn, status: "400 Bad Request")
            }
            let accept = Data(Insecure.SHA1.hash(data: Data((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").utf8))).base64EncodedString()
            let head = "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: \(accept)\r\n\r\n"
            conn.send(content: Data(head.utf8), completion: .contentProcessed { _ in })
            let bridge = WebBridge(conn: conn, queue: queue, server: self)
            bridges[ObjectIdentifier(bridge)] = bridge
            bridge.onClose = { [weak self, weak bridge] in
                guard let self, let bridge else { return }
                self.bridges[ObjectIdentifier(bridge)] = nil
            }
            bridge.start(leftover: leftover)
            return
        }

        guard let file = Self.files[path],
              let body = try? Data(contentsOf: webRoot.appendingPathComponent(file.name)) else {
            return respond(conn, status: "404 Not Found")
        }
        let headers = [
            "Content-Type: \(file.type)",
            "Cache-Control: no-cache",
            "X-Content-Type-Options: nosniff",
            "X-Frame-Options: DENY",
            "Referrer-Policy: no-referrer",
            "Content-Security-Policy: default-src 'self'; connect-src 'self' ws://\(host); style-src 'self' 'unsafe-inline'; img-src 'self' data:",
        ]
        respond(conn, status: "200 OK", headers: headers, body: body)
    }

    private func respond(_ conn: NWConnection, status: String, headers: [String] = [], body: Data = Data()) {
        var head = "HTTP/1.1 \(status)\r\nContent-Length: \(body.count)\r\nConnection: close\r\n"
        for h in headers { head += h + "\r\n" }
        var data = Data((head + "\r\n").utf8)
        data.append(body)
        conn.send(content: data, completion: .contentProcessed { _ in conn.cancel() })
    }

    // MARK: Auth

    /// Constant-time compare, and a global brake on guessing.
    func checkToken(_ token: String, from endpoint: NWEndpoint) -> Bool {
        let now = Date()
        failedLogins.removeAll { now.timeIntervalSince($0) > 60 }
        let a = Array(token.utf8), b = Array(config.token.utf8)
        var diff = a.count ^ b.count
        for i in 0..<min(a.count, b.count) { diff |= Int(a[i] ^ b[i]) }
        if diff == 0 && failedLogins.count < 20 { return true }
        failedLogins.append(now)
        log("rejected token from \(endpoint)")
        return false
    }

    /// What the page needs from the app's state file: names, projects, presets and stopped sessions.
    /// The daemon only knows the sessions that are running.
    func catalog() -> [String: Any] {
        let state = AppStateFile.load()
        return [
            "workspaces": (state.workspaces ?? []).map { ["id": $0.id.uuidString, "name": $0.name ?? "", "color": $0.color ?? "blue"] },
            "projects": (state.projects ?? []).map {
                ["id": $0.id.uuidString, "name": $0.name ?? "", "workspaceID": $0.workspaceID?.uuidString ?? ""]
            },
            "presets": state.presetList.map { ["id": $0.id, "label": $0.label, "command": $0.command] },
            "sessions": (state.sessions ?? []).filter { $0.archived != true }.map { s -> [String: Any] in
                [
                    "id": s.id.uuidString,
                    "projectID": s.projectID?.uuidString ?? "",
                    "title": s.title ?? "",
                    "command": s.command ?? "",
                    "createdAt": s.createdAt?.timeIntervalSinceReferenceDate ?? 0,
                    "resumable": AgentResume.command(for: s.command ?? "", agentSessionID: s.agentSessionID) != nil,
                ]
            },
        ]
    }

    func log(_ s: String) {
        let line = "\(ISO8601DateFormatter().string(from: Date())) web: \(s)\n"
        FileHandle.standardError.write(Data(line.utf8))
    }
}

/// One browser tab: WebSocket on one side, a private daemon connection on the other.
/// Each binary WebSocket message carries exactly one daemon frame in either direction.
final class WebBridge {
    private let conn: NWConnection
    private let queue: DispatchQueue
    private weak var server: WebServer?
    private var ws = WebSocketDecoder()
    private var authenticated = false
    private var closed = false
    private var daemonFD: Int32 = -1
    private var daemonSource: DispatchSourceRead?
    private var daemonWriter: SocketWriter?
    private var daemonDecoder = FrameDecoder()
    /// Bytes handed to the network but not yet sent; a tab that stops reading is dropped.
    private var unsent = 0
    private static let maxUnsent = 16 * 1024 * 1024
    var onClose: (() -> Void)?

    init(conn: NWConnection, queue: DispatchQueue, server: WebServer) {
        self.conn = conn
        self.queue = queue
        self.server = server
    }

    func start(leftover: [UInt8]) {
        consume(leftover)
        receive()
        // Nobody gets to hold a socket open without logging in.
        queue.asyncAfter(deadline: .now() + 10) { [weak self] in
            guard let self, !self.authenticated else { return }
            self.close(code: 4001, reason: "auth timeout")
        }
    }

    private func receive() {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, done, error in
            guard let self, !self.closed else { return }
            if let data { self.consume([UInt8](data)) }
            if done || error != nil { self.close() } else if !self.closed { self.receive() }
        }
    }

    private func consume(_ bytes: [UInt8]) {
        guard !bytes.isEmpty else { return }
        do {
            for message in try ws.append(bytes) where !closed { handle(message) }
        } catch {
            close(code: 1002, reason: "protocol error")
        }
    }

    private func handle(_ m: WebSocketMessage) {
        switch m.opcode {
        case .close:
            close(code: 1000)
        case .ping:
            send(.pong, m.payload)
        case .pong:
            break
        case .text:
            guard let obj = try? JSONSerialization.jsonObject(with: Data(m.payload)) as? [String: Any],
                  let type = obj["type"] as? String else { return close(code: 1003, reason: "bad message") }
            if !authenticated {
                guard type == "auth", let token = obj["token"] as? String, let server,
                      server.checkToken(token, from: conn.endpoint) else {
                    // A short wait makes guessing slower without tying up anything.
                    queue.asyncAfter(deadline: .now() + 1) { [weak self] in self?.close(code: 4001, reason: "unauthorized") }
                    return
                }
                authenticated = true
                guard connectDaemon() else { return close(code: 1011, reason: "session host unavailable") }
                sendJSON(["type": "ready", "catalog": server.catalog()])
            } else if let server {
                handleCommand(type, obj, server: server)
            }
        case .binary:
            guard authenticated else { return close(code: 4001, reason: "unauthorized") }
            forwardToDaemon(m.payload)
        }
    }

    /// Starting sessions goes through here instead of the daemon's `create`: the browser names a saved
    /// session or a preset, and the command and folder come from the app's state, never from the page.
    private func handleCommand(_ type: String, _ obj: [String: Any], server: WebServer) {
        let cols = obj["cols"] as? Int ?? 120
        let rows = obj["rows"] as? Int ?? 32
        switch type {
        case "catalog":
            sendJSON(["type": "catalog", "catalog": server.catalog()])
        case "start":
            let state = AppStateFile.load()
            guard let id = (obj["id"] as? String).flatMap(UUID.init(uuidString:)),
                  let s = state.sessions?.first(where: { $0.id == id }) else {
                return sendJSON(["type": "started", "error": "unknown session"])
            }
            let command = obj["resume"] as? Bool == true
                ? AgentResume.command(for: s.command ?? "", agentSessionID: s.agentSessionID)
                : s.command ?? ""
            guard let command else { return sendJSON(["type": "started", "id": id.uuidString, "error": "nothing to resume"]) }
            let cwd = s.worktreePath ?? state.project(s.projectID)?.path ?? NSHomeDirectory()
            create(id: id, command: command, cwd: cwd, cols: cols, rows: rows)
        case "new":
            let state = AppStateFile.load()
            guard let project = state.project((obj["projectID"] as? String).flatMap(UUID.init(uuidString:))),
                  let preset = state.presetList.first(where: { $0.id == obj["presetID"] as? String }) else {
                return sendJSON(["type": "started", "error": "unknown project or preset"])
            }
            create(id: UUID(), command: preset.command, cwd: project.path ?? NSHomeDirectory(), cols: cols, rows: rows)
        default:
            break
        }
    }

    /// Bridge-made requests use negative ids so their replies are not forwarded to the page.
    private var nextInternalID = -1
    private var pendingCreates: [Int: UUID] = [:]

    private func create(id: UUID, command: String, cwd: String, cols: Int, rows: Int) {
        var m = Message(type: "create", reqID: nextInternalID, id: id)
        m.command = command
        m.cwd = cwd
        m.cols = max(2, min(cols, 1000))
        m.rows = max(1, min(rows, 1000))
        pendingCreates[nextInternalID] = id
        nextInternalID -= 1
        server?.log("start \(command.isEmpty ? "shell" : command) in \(cwd)")
        daemonWriter?.send(Frame.json(m))
    }

    private func forwardToDaemon(_ bytes: [UInt8]) {
        var decoder = FrameDecoder()
        guard let frames = try? bytes.withUnsafeBytes({ try decoder.append($0) }),
              frames.count == 1, frames[0].payload.count + 5 == bytes.count else {
            return close(code: 1003, reason: "bad frame")
        }
        let frame = frames[0]
        switch frame.kind {
        case .input:
            break
        case .json:
            guard let msg = frame.message, WebServer.allowedRequests.contains(msg.type) else {
                server?.log("blocked request from browser: \(frame.message?.type ?? "?")")
                return
            }
        case .output:
            return
        }
        daemonWriter?.send(bytes)
        if daemonWriter?.failed == true { close(code: 1011, reason: "session host closed") }
    }

    private func connectDaemon() -> Bool {
        guard let fd = try? DaemonLauncher.connect(tlyPath: selfPath) else { return false }
        UnixSocket.setNonBlocking(fd)
        daemonFD = fd
        daemonWriter = SocketWriter(fd: fd, queue: queue)
        let rs = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        rs.setEventHandler { [weak self] in self?.readDaemon() }
        rs.setCancelHandler { Darwin.close(fd) }
        daemonSource = rs
        rs.resume()
        return true
    }

    private func readDaemon() {
        var buf = [UInt8](repeating: 0, count: 65536)
        let n = buf.withUnsafeMutableBytes { read(daemonFD, $0.baseAddress, 65536) }
        if n > 0 {
            guard let frames = try? buf.withUnsafeBytes({ try daemonDecoder.append(UnsafeRawBufferPointer(rebasing: $0[0..<n])) }) else {
                return close(code: 1011, reason: "bad data from session host")
            }
            for f in frames {
                if f.kind == .json, let msg = f.message, let r = msg.reqID, r < 0, let id = pendingCreates.removeValue(forKey: r) {
                    sendJSON(["type": "started", "id": id.uuidString, "error": msg.error ?? NSNull()])
                    continue
                }
                send(.binary, f.bytes)
            }
        } else if n == 0 || (errno != EAGAIN && errno != EINTR) {
            close(code: 1011, reason: "session host closed")
        }
    }

    private func sendJSON(_ obj: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: obj) else { return }
        send(.text, [UInt8](data))
    }

    private func send(_ opcode: WebSocketOpcode, _ payload: [UInt8]) {
        guard !closed else { return }
        let frame = WebSocketDecoder.encode(opcode, payload)
        unsent += frame.count
        if unsent > Self.maxUnsent { return close() }
        let count = frame.count
        conn.send(content: Data(frame), completion: .contentProcessed { [weak self] _ in self?.unsent -= count })
    }

    func close(code: UInt16? = nil, reason: String = "") {
        guard !closed else { return }
        if let code {
            let payload = [UInt8(code >> 8), UInt8(code & 0xff)] + Array(reason.utf8.prefix(100))
            conn.send(content: Data(WebSocketDecoder.encode(.close, payload)), completion: .contentProcessed { [conn] _ in conn.cancel() })
        } else {
            conn.cancel()
        }
        closed = true
        daemonWriter?.cancel()
        daemonWriter = nil
        daemonSource?.cancel()
        daemonSource = nil
        onClose?()
    }
}

enum WebSocketOpcode: UInt8 {
    case continuation = 0, text = 1, binary = 2, close = 8, ping = 9, pong = 10
}

struct WebSocketMessage {
    enum Kind { case text, binary, close, ping, pong }
    let opcode: Kind
    let payload: [UInt8]
}

/// RFC 6455 server side: clients must mask, messages may be fragmented, control frames may interleave.
struct WebSocketDecoder {
    private var buffer: [UInt8] = []
    private var fragments: [UInt8] = []
    private var fragmentOpcode: WebSocketOpcode?
    static let maxMessage = 4 * 1024 * 1024

    enum DecodeError: Error { case unmasked, oversized, badOpcode, badContinuation }

    mutating func append(_ bytes: [UInt8]) throws -> [WebSocketMessage] {
        buffer.append(contentsOf: bytes)
        var out: [WebSocketMessage] = []
        var start = 0
        while buffer.count - start >= 2 {
            let b0 = buffer[start], b1 = buffer[start + 1]
            guard b1 & 0x80 != 0 else { throw DecodeError.unmasked }
            guard let opcode = WebSocketOpcode(rawValue: b0 & 0x0f) else { throw DecodeError.badOpcode }
            let fin = b0 & 0x80 != 0
            var length = Int(b1 & 0x7f)
            var header = 2
            if length == 126 {
                guard buffer.count - start >= 4 else { break }
                length = Int(buffer[start + 2]) << 8 | Int(buffer[start + 3])
                header = 4
            } else if length == 127 {
                guard buffer.count - start >= 10 else { break }
                var l: UInt64 = 0
                for i in 2..<10 { l = l << 8 | UInt64(buffer[start + i]) }
                guard l <= UInt64(Self.maxMessage) else { throw DecodeError.oversized }
                length = Int(l)
                header = 10
            }
            guard length <= Self.maxMessage else { throw DecodeError.oversized }
            guard buffer.count - start >= header + 4 + length else { break }
            let mask = Array(buffer[(start + header)..<(start + header + 4)])
            let bodyStart = start + header + 4
            var payload = Array(buffer[bodyStart..<(bodyStart + length)])
            for i in 0..<payload.count { payload[i] ^= mask[i & 3] }
            start = bodyStart + length

            switch opcode {
            case .close: out.append(WebSocketMessage(opcode: .close, payload: payload))
            case .ping: out.append(WebSocketMessage(opcode: .ping, payload: payload))
            case .pong: out.append(WebSocketMessage(opcode: .pong, payload: payload))
            case .text, .binary, .continuation:
                if opcode == .continuation {
                    guard fragmentOpcode != nil else { throw DecodeError.badContinuation }
                } else {
                    guard fragmentOpcode == nil else { throw DecodeError.badContinuation }
                    fragmentOpcode = opcode
                    fragments = []
                }
                fragments.append(contentsOf: payload)
                guard fragments.count <= Self.maxMessage else { throw DecodeError.oversized }
                if fin {
                    out.append(WebSocketMessage(opcode: fragmentOpcode == .text ? .text : .binary, payload: fragments))
                    fragments = []
                    fragmentOpcode = nil
                }
            }
        }
        buffer.removeFirst(start)
        return out
    }

    static func encode(_ opcode: WebSocketOpcode, _ payload: [UInt8]) -> [UInt8] {
        var out: [UInt8] = [0x80 | opcode.rawValue]
        let n = payload.count
        if n < 126 {
            out.append(UInt8(n))
        } else if n <= 0xffff {
            out += [126, UInt8(n >> 8), UInt8(n & 0xff)]
        } else {
            out.append(127)
            for shift in stride(from: 56, through: 0, by: -8) { out.append(UInt8((UInt64(n) >> UInt64(shift)) & 0xff)) }
        }
        out.reserveCapacity(out.count + n)
        out += payload
        return out
    }
}

private extension URL {
    /// "host:port" as a browser writes it in the Host header (port only when not the default).
    var hostPort: String? {
        guard let host else { return nil }
        return port.map { "\(host):\($0)" } ?? host
    }
}

/// The parts of the app's `state.json` the web needs. Read fresh on every request: the app owns
/// the file and rewrites it whenever something changes.
struct AppStateFile: Decodable {
    struct Workspace: Decodable { var id: UUID; var name: String?; var color: String? }
    struct Project: Decodable { var id: UUID; var name: String?; var path: String?; var workspaceID: UUID? }
    struct Preset: Decodable { var id: UUID; var label: String?; var command: String? }
    struct Session: Decodable {
        var id: UUID
        var projectID: UUID?
        var title: String?
        var command: String?
        var archived: Bool?
        var agentSessionID: String?
        var worktreePath: String?
        var createdAt: Date?
    }

    var workspaces: [Workspace]?
    var projects: [Project]?
    var presets: [Preset]?
    var sessions: [Session]?

    static func load() -> AppStateFile {
        let url = TerminalyPaths.stateDir.appendingPathComponent("state.json")
        guard let data = try? Data(contentsOf: url),
              let state = try? JSONDecoder().decode(AppStateFile.self, from: data) else {
            return AppStateFile()
        }
        return state
    }

    func project(_ id: UUID?) -> Project? {
        guard let id else { return nil }
        return projects?.first { $0.id == id }
    }

    /// The app's presets; a state file without them gets the app's defaults.
    var presetList: [(id: String, label: String, command: String)] {
        if let presets, !presets.isEmpty {
            return presets.map { ($0.id.uuidString, $0.label ?? "", $0.command ?? "") }
        }
        return [("default-shell", "Shell", ""), ("default-claude", "Claude", "claude"), ("default-codex", "Codex", "codex")]
    }
}
