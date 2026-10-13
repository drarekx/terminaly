import Foundation

/// Wire format between the app/CLI and the `tly` daemon over a Unix socket:
///   [UInt32 big-endian length][UInt8 kind][payload]
/// `json` carries a `Message`; `output`/`input` carry a 16-byte session UUID followed by raw terminal bytes.
public enum FrameKind: UInt8 {
    case json = 1
    case output = 2
    case input = 3
}

public struct Frame {
    public let kind: FrameKind
    public let payload: [UInt8]

    public static func json(_ message: Message) -> [UInt8] {
        let data = (try? JSONEncoder().encode(message)) ?? Data()
        return encode(.json, [UInt8](data))
    }

    public static func data(_ kind: FrameKind, session: UUID, bytes: some Collection<UInt8>) -> [UInt8] {
        var payload = session.bytes
        payload.append(contentsOf: bytes)
        return encode(kind, payload)
    }

    static func encode(_ kind: FrameKind, _ payload: [UInt8]) -> [UInt8] {
        let len = UInt32(payload.count + 1)
        var out: [UInt8] = [UInt8(len >> 24), UInt8((len >> 16) & 0xff), UInt8((len >> 8) & 0xff), UInt8(len & 0xff), kind.rawValue]
        out.reserveCapacity(payload.count + 5)
        out.append(contentsOf: payload)
        return out
    }

    public var message: Message? {
        guard kind == .json else { return nil }
        return try? JSONDecoder().decode(Message.self, from: Data(payload))
    }

    /// For output/input frames: (session, bytes).
    public var sessionData: (UUID, ArraySlice<UInt8>)? {
        guard kind != .json, payload.count >= 16 else { return nil }
        return (UUID(bytes: payload[0..<16]), payload[16...])
    }
}

/// Incremental frame parser.
public struct FrameDecoder {
    private var buffer: [UInt8] = []
    private var start = 0
    public static let maxFrame = 16 * 1024 * 1024

    public init() {}

    public enum DecodeError: Error { case oversized, badKind }

    public mutating func append(_ bytes: UnsafeRawBufferPointer) throws -> [Frame] {
        buffer.append(contentsOf: bytes)
        var frames: [Frame] = []
        while buffer.count - start >= 4 {
            let len = Int(buffer[start]) << 24 | Int(buffer[start + 1]) << 16 | Int(buffer[start + 2]) << 8 | Int(buffer[start + 3])
            guard len >= 1, len <= Self.maxFrame else { throw DecodeError.oversized }
            guard buffer.count - start - 4 >= len else { break }
            guard let kind = FrameKind(rawValue: buffer[start + 4]) else { throw DecodeError.badKind }
            frames.append(Frame(kind: kind, payload: Array(buffer[(start + 5)..<(start + 4 + len)])))
            start += 4 + len
        }
        if start > 0 && start == buffer.count {
            buffer.removeAll(keepingCapacity: true)
            start = 0
        } else if start > 64 * 1024 {
            buffer.removeFirst(start)
            start = 0
        }
        return frames
    }
}

/// Flat control message. `type` selects the meaning; unused fields stay nil.
///
/// Requests: hello, list, create, attach, detach, resize, send, kill, remove, logs
/// Replies echo `reqID`. Events (no reqID): sessions, status, exited, removed
public struct Message: Codable {
    public var type: String
    public var reqID: Int?
    public var id: UUID?
    public var command: String?
    public var cwd: String?
    public var cols: Int?
    public var rows: Int?
    public var text: String?
    public var enter: Bool?
    public var lines: Int?
    public var sessions: [SessionInfo]?
    public var status: String?
    public var detail: String?
    public var notify: Bool?
    public var exitCode: Int32?
    public var error: String?
    public var version: String?

    public init(type: String, reqID: Int? = nil, id: UUID? = nil) {
        self.type = type
        self.reqID = reqID
        self.id = id
    }
}

public struct SessionInfo: Codable, Hashable {
    public var id: UUID
    public var command: String
    public var cwd: String
    public var pid: Int32
    public var running: Bool
    public var status: String
    public var exitCode: Int32?
    public var createdAt: Date

    public init(id: UUID, command: String, cwd: String, pid: Int32, running: Bool, status: String, exitCode: Int32?, createdAt: Date) {
        self.id = id
        self.command = command
        self.cwd = cwd
        self.pid = pid
        self.running = running
        self.status = status
        self.exitCode = exitCode
        self.createdAt = createdAt
    }
}

public enum TerminalyPaths {
    public static let protocolVersion = "1"

    public static var stateDir: URL {
        let dir = ProcessInfo.processInfo.environment["TERMINALY_STATE_DIR"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Terminaly", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        return dir
    }

    /// sockaddr_un paths are limited to 104 bytes; fall back to a per-user /tmp name for long state dirs.
    public static var socket: String {
        let path = stateDir.appendingPathComponent("tly.sock").path
        if path.utf8.count < 100 { return path }
        var hash: UInt64 = 1469598103934665603  // FNV-1a
        for b in stateDir.path.utf8 { hash = (hash ^ UInt64(b)) &* 1099511628211 }
        return "/tmp/tly-\(getuid())-\(String(hash, radix: 16)).sock"
    }
    public static var log: String { stateDir.appendingPathComponent("tly.log").path }
}

extension UUID {
    var bytes: [UInt8] {
        withUnsafeBytes(of: uuid) { Array($0) }
    }

    init(bytes: ArraySlice<UInt8>) {
        var u: uuid_t = (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
        withUnsafeMutableBytes(of: &u) { dst in
            for (i, b) in bytes.enumerated() { dst[i] = b }
        }
        self.init(uuid: u)
    }
}
