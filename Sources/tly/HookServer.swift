import Foundation
import Network

/// Tiny localhost HTTP server receiving agent hook events:
///   POST /hook/<session-uuid>/<EventName>   header X-Terminaly-Token: <token>   body: hook JSON
final class HookServer: @unchecked Sendable {
    let token = UUID().uuidString
    /// Called on the hook queue; the receiver hops to its own queue.
    var onEvent: ((UUID, String, [String: Any]) -> Void)?
    private(set) var port: UInt16?
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "terminaly.hooks")

    func start() {
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .any)
        guard let listener = try? NWListener(using: params) else { return }
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { [weak self] state in
            if case .ready = state {
                self?.port = listener.port?.rawValue
                ready.signal()
            } else if case .failed = state {
                ready.signal()
            }
        }
        listener.newConnectionHandler = { [weak self] conn in self?.handle(conn) }
        listener.start(queue: queue)
        self.listener = listener
        // Sessions need the port in their environment, so wait briefly for it.
        _ = ready.wait(timeout: .now() + 2)
    }

    private func handle(_ conn: NWConnection) {
        conn.start(queue: queue)
        receive(conn, buffer: Data())
    }

    private func receive(_ conn: NWConnection, buffer: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, done, error in
            guard let self else { return }
            var buf = buffer
            if let data { buf.append(data) }
            if let request = HTTPRequest(buf) {
                self.respond(conn, status: self.dispatch(request) ? "204 No Content" : "404 Not Found")
            } else if done || error != nil || buf.count > 1_000_000 {
                conn.cancel()
            } else {
                self.receive(conn, buffer: buf)
            }
        }
    }

    private func respond(_ conn: NWConnection, status: String) {
        let resp = "HTTP/1.1 \(status)\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
        conn.send(content: resp.data(using: .utf8), completion: .contentProcessed { _ in conn.cancel() })
    }

    private func dispatch(_ req: HTTPRequest) -> Bool {
        guard req.method == "POST", req.headers["x-terminaly-token"] == token else { return false }
        let parts = req.path.split(separator: "/").map(String.init)
        guard parts.count == 3, parts[0] == "hook", let id = UUID(uuidString: parts[1]) else { return false }
        let event = parts[2]
        let payload = (try? JSONSerialization.jsonObject(with: req.body)) as? [String: Any] ?? [:]
        onEvent?(id, event, payload)
        return true
    }
}

/// Minimal HTTP/1.1 request parser; returns nil until headers and full body have arrived.
private struct HTTPRequest {
    let method: String
    let path: String
    let headers: [String: String]
    let body: Data

    init?(_ data: Data) {
        guard let sep = data.range(of: Data("\r\n\r\n".utf8)),
              let head = String(data: data[..<sep.lowerBound], encoding: .utf8) else { return nil }
        let lines = head.components(separatedBy: "\r\n")
        let start = lines[0].split(separator: " ")
        guard start.count >= 2 else { return nil }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let length = Int(headers["content-length"] ?? "0") ?? 0
        let body = data[sep.upperBound...]
        guard body.count >= length else { return nil }
        method = String(start[0])
        path = String(start[1])
        self.headers = headers
        self.body = Data(body.prefix(length))
    }
}
