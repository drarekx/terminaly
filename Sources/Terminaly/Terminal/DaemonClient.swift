import Darwin
import Foundation
import TerminalyKit

/// Async connection to the `tly` session host. Everything runs on the main queue.
@MainActor
final class DaemonClient {
    private var fd: Int32 = -1
    private var readSource: DispatchSourceRead?
    private var writer: SocketWriter?
    private var decoder = FrameDecoder()
    private var nextID = 1
    private var pending: [Int: (Message) -> Void] = [:]

    var onOutput: ((UUID, ArraySlice<UInt8>) -> Void)?
    var onEvent: ((Message) -> Void)?
    var onDisconnect: (() -> Void)?

    var isConnected: Bool { fd >= 0 }

    /// `tly` ships next to the app executable (also true for `swift build` output).
    static var tlyPath: String {
        Bundle.main.executableURL!.deletingLastPathComponent().appendingPathComponent("tly").path
    }

    func connect() throws {
        guard fd < 0 else { return }
        let fd = try DaemonLauncher.connect(tlyPath: Self.tlyPath)
        UnixSocket.setNonBlocking(fd)
        self.fd = fd
        decoder = FrameDecoder()
        writer = SocketWriter(fd: fd, queue: .main)
        let rs = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .main)
        rs.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.readAvailable() }
        }
        rs.setCancelHandler { Darwin.close(fd) }
        readSource = rs
        rs.resume()
    }

    func disconnect() {
        guard fd >= 0 else { return }
        writer?.cancel()
        writer = nil
        readSource?.cancel()
        readSource = nil
        fd = -1
        let waiting = pending
        pending.removeAll()
        var err = Message(type: "error")
        err.error = "disconnected"
        for (_, cb) in waiting { cb(err) }
    }

    private func readAvailable() {
        var buf = [UInt8](repeating: 0, count: 65536)
        let n = buf.withUnsafeMutableBytes { read(fd, $0.baseAddress, 65536) }
        if n > 0 {
            guard let frames = try? buf.withUnsafeBytes({ try decoder.append(UnsafeRawBufferPointer(rebasing: $0[0..<n])) }) else {
                lost()
                return
            }
            for f in frames { dispatch(f) }
        } else if n == 0 || (errno != EAGAIN && errno != EINTR) {
            lost()
        }
    }

    private func lost() {
        disconnect()
        onDisconnect?()
    }

    private func dispatch(_ frame: Frame) {
        if frame.kind == .output, let (id, bytes) = frame.sessionData {
            onOutput?(id, bytes)
        } else if let msg = frame.message {
            if let rid = msg.reqID, let cb = pending.removeValue(forKey: rid) {
                cb(msg)
            } else {
                onEvent?(msg)
            }
        }
    }

    func request(_ msg: Message, reply: ((Message) -> Void)? = nil) {
        if fd < 0 { try? connect() }
        guard let writer else {
            var err = Message(type: "error")
            err.error = "session host unavailable"
            reply?(err)
            return
        }
        var m = msg
        m.reqID = nextID
        nextID += 1
        if let reply { pending[m.reqID!] = reply }
        writer.send(Frame.json(m))
        if writer.failed { lost() }
    }

    func sendInput(_ id: UUID, _ bytes: ArraySlice<UInt8>) {
        guard let writer else { return }
        writer.send(Frame.data(.input, session: id, bytes: bytes))
    }
}
