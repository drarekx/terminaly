import Darwin
import Foundation

/// Settings for `tly web`, shared by the app (which edits them) and the web bridge (which reads them at start).
/// Stored in `web.json` in the state dir with 0600 permissions because it holds the access token.
public struct WebConfig: Codable, Equatable, Sendable {
    public var enabled: Bool
    public var port: Int
    public var token: String

    public static let defaultPort = 7878

    public init(enabled: Bool = false, port: Int = WebConfig.defaultPort, token: String = WebConfig.newToken()) {
        self.enabled = enabled
        self.port = port
        self.token = token
    }

    /// 32 random bytes as hex: long enough that guessing over the network is hopeless.
    public static func newToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        arc4random_buf(&bytes, bytes.count)
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    public static var url: URL { TerminalyPaths.stateDir.appendingPathComponent("web.json") }
    public static var pidURL: URL { TerminalyPaths.stateDir.appendingPathComponent("web.pid") }
    public static var logPath: String { TerminalyPaths.stateDir.appendingPathComponent("tly-web.log").path }

    public static func load() -> WebConfig? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(WebConfig.self, from: data)
    }

    public func save() throws {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(self).write(to: Self.url, options: .atomic)
        chmod(Self.url.path, 0o600)
    }

    /// PID of a running `tly web`, if any.
    public static var runningPID: pid_t? {
        guard let text = try? String(contentsOf: pidURL, encoding: .utf8),
              let pid = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)), pid > 0,
              kill(pid, 0) == 0 else { return nil }
        return pid
    }
}
