import Foundation

/// Settings of the session host that the app edits (`daemon.json` in the state dir).
/// The daemon reads the file when it needs a value, so a change applies without restarting it.
public struct DaemonConfig: Codable, Equatable, Sendable {
    /// Running workers one session may have. nil = default.
    public var maxWorkers: Int?

    public static let defaultMaxWorkers = 6
    public static let maxWorkersRange = 1...16

    public init(maxWorkers: Int? = nil) {
        self.maxWorkers = maxWorkers
    }

    public static var url: URL { TerminalyPaths.stateDir.appendingPathComponent("daemon.json") }

    public static func load() -> DaemonConfig {
        guard let data = try? Data(contentsOf: url),
              let config = try? JSONDecoder().decode(DaemonConfig.self, from: data) else { return DaemonConfig() }
        return config
    }

    public func save() throws {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(self).write(to: Self.url, options: .atomic)
    }

    /// `TERMINALY_MAX_WORKERS` (tests, one-off runs) wins over the file.
    public static var effectiveMaxWorkers: Int {
        let value = Int(ProcessInfo.processInfo.environment["TERMINALY_MAX_WORKERS"] ?? "")
            ?? load().maxWorkers ?? defaultMaxWorkers
        return min(max(value, maxWorkersRange.lowerBound), maxWorkersRange.upperBound)
    }
}
