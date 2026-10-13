import Darwin
import Foundation

public enum UnixSocket {
    public enum SocketError: Error, CustomStringConvertible {
        case sys(String, Int32)
        case pathTooLong

        public var description: String {
            switch self {
            case .sys(let call, let err): "\(call): \(String(cString: strerror(err)))"
            case .pathTooLong: "socket path too long"
            }
        }
    }

    static func address(_ path: String) throws -> sockaddr_un {
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: addr.sun_path) else { throw SocketError.pathTooLong }
        withUnsafeMutableBytes(of: &addr.sun_path) { dst in
            for (i, b) in bytes.enumerated() { dst[i] = b }
            dst[bytes.count] = 0
        }
        return addr
    }

    public static func connect(_ path: String) throws -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw SocketError.sys("socket", errno) }
        var addr = try address(path)
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard rc == 0 else {
            let e = errno
            close(fd)
            throw SocketError.sys("connect", e)
        }
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        return fd
    }

    /// Binds a listening socket readable only by the current user.
    public static func listen(_ path: String) throws -> Int32 {
        unlink(path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw SocketError.sys("socket", errno) }
        var addr = try address(path)
        let old = umask(0o077)
        defer { umask(old) }
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard rc == 0 else { throw SocketError.sys("bind", errno) }
        guard Darwin.listen(fd, 16) == 0 else { throw SocketError.sys("listen", errno) }
        return fd
    }

    public static func setNonBlocking(_ fd: Int32) {
        let flags = fcntl(fd, F_GETFL)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
    }

    /// True if the peer runs as the same user.
    public static func peerIsSameUser(_ fd: Int32) -> Bool {
        var uid: uid_t = 0
        var gid: gid_t = 0
        return getpeereid(fd, &uid, &gid) == 0 && uid == getuid()
    }

    /// Blocking write of the whole buffer.
    public static func writeAll(_ fd: Int32, _ bytes: [UInt8]) -> Bool {
        var off = 0
        while off < bytes.count {
            let n = bytes.withUnsafeBytes { write(fd, $0.baseAddress! + off, bytes.count - off) }
            if n < 0 {
                if errno == EINTR { continue }
                return false
            }
            off += n
        }
        return true
    }
}

/// Buffered, non-blocking writer for a socket driven by a DispatchSource on `queue`.
public final class SocketWriter {
    private let fd: Int32
    private let queue: DispatchQueue
    private var pending: [UInt8] = []
    private var offset = 0
    private var source: DispatchSourceWrite?
    public private(set) var failed = false
    public var backlog: Int { pending.count - offset }

    public init(fd: Int32, queue: DispatchQueue) {
        self.fd = fd
        self.queue = queue
    }

    /// Must be called on `queue`.
    public func send(_ bytes: [UInt8]) {
        guard !failed else { return }
        pending.append(contentsOf: bytes)
        flush()
    }

    private func flush() {
        while offset < pending.count {
            let n = pending.withUnsafeBytes { write(fd, $0.baseAddress! + offset, pending.count - offset) }
            if n > 0 {
                offset += n
            } else if n < 0 && errno == EINTR {
                continue
            } else if n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) {
                armSource()
                return
            } else {
                failed = true
                cancel()
                return
            }
        }
        pending.removeAll(keepingCapacity: pending.count < 1 << 20)
        offset = 0
        if let s = source, !sourceSuspended {
            s.suspend()
            sourceSuspended = true
        }
    }

    private var sourceSuspended = false

    private func armSource() {
        if source == nil {
            let s = DispatchSource.makeWriteSource(fileDescriptor: fd, queue: queue)
            s.setEventHandler { [weak self] in self?.flush() }
            source = s
            sourceSuspended = false
            s.resume()
        } else if sourceSuspended {
            sourceSuspended = false
            source?.resume()
        }
    }

    public func cancel() {
        if let s = source {
            if sourceSuspended { s.resume() }
            s.cancel()
            source = nil
        }
    }
}
