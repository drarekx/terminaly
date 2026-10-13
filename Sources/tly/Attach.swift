import Darwin
import Foundation
import TerminalyKit

/// `tly attach`: puts the local terminal in raw mode and bridges it to a hosted session.
struct AttachSession {
    let conn: SyncConnection
    let session: UUID

    func run() -> Never {
        guard isatty(0) != 0 else { fail("attach needs a terminal") }
        var original = termios()
        tcgetattr(0, &original)
        var raw = original
        cfmakeraw(&raw)
        tcsetattr(0, TCSANOW, &raw)
        let restore = { var t = original; tcsetattr(0, TCSANOW, &t) }

        func sendSize() {
            var ws = winsize()
            if ioctl(0, TIOCGWINSZ, &ws) == 0 {
                var m = Message(type: "resize", id: session)
                m.cols = Int(ws.ws_col)
                m.rows = Int(ws.ws_row)
                _ = conn.send(Frame.json(m))
            }
        }

        _ = conn.send(Frame.json(Message(type: "attach", reqID: 0, id: session)))
        sendSize()

        signal(SIGWINCH, SIG_IGN)
        let winch = DispatchSource.makeSignalSource(signal: SIGWINCH, queue: .main)
        winch.setEventHandler { sendSize() }
        winch.resume()

        // stdin → session. Ctrl-\ (0x1c) detaches.
        let input = DispatchSource.makeReadSource(fileDescriptor: 0, queue: .main)
        input.setEventHandler {
            var buf = [UInt8](repeating: 0, count: 4096)
            let n = read(0, &buf, 4096)
            guard n > 0 else { return }
            let bytes = buf[0..<n]
            if bytes.contains(0x1c) {
                restore()
                print("\r\n[detached]")
                exit(0)
            }
            _ = conn.send(Frame.data(.input, session: session, bytes: bytes))
        }
        input.resume()

        // session → stdout, on a background thread (blocking reads).
        let sessionID = session
        Thread.detachNewThread { [conn] in
            while true {
                guard let frame = try? conn.nextFrame() else {
                    DispatchQueue.main.async { restore(); print("\r\n[connection closed]"); exit(1) }
                    return
                }
                if let (id, bytes) = frame.sessionData, frame.kind == .output, id == sessionID {
                    _ = UnixSocket.writeAll(1, Array(bytes))
                } else if let m = frame.message, m.type == "status", m.id == sessionID, m.status == "exited" {
                    DispatchQueue.main.async { restore(); print("\r\n[session exited]"); exit(0) }
                    return
                }
            }
        }
        dispatchMain()
    }
}
