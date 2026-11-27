import Foundation
#if canImport(Glibc)
import Glibc
#endif

/// The MCP servers Claude Code starts for a folder, and the per-project switch behind its `/mcp`
/// dialog. Each enabled server is a process tree of its own in every session (often 100–300 MB),
/// so turning off the ones a project does not need is the cheapest way to shrink a session.
///
/// Claude has no command for this: the switch is `projects[<repo>].disabledMcpServers` in its
/// `.claude.json`, which it rewrites all the time. Writes here take the same lock it does.
public enum ClaudeMCP {
    public enum Source: Equatable, Sendable {
        case user, local, project
        case plugin(String)
    }

    public struct Server: Identifiable, Equatable, Sendable {
        /// The name Claude knows it by, as stored in `disabledMcpServers`.
        public let name: String
        public let label: String
        public let source: Source
        public var enabled: Bool
        public var id: String { name }

        public init(name: String, label: String, source: Source, enabled: Bool) {
            self.name = name
            self.label = label
            self.source = source
            self.enabled = enabled
        }
    }

    public enum Failure: Error {
        /// Claude Code held the lock on its state file for too long.
        case busy
        /// The state file is missing or is not JSON.
        case invalid
    }

    /// Claude Code keeps everything in `CLAUDE_CONFIG_DIR` when set; otherwise the settings folder
    /// is `~/.claude` and the state file sits next to it, in the home folder.
    public struct Paths: Sendable {
        public var configDir: URL
        public var stateFile: URL

        public static var standard: Paths {
            if let dir = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"], !dir.isEmpty {
                return Paths(configDir: URL(fileURLWithPath: dir))
            }
            let home = FileManager.default.homeDirectoryForCurrentUser
            return Paths(configDir: home.appendingPathComponent(".claude"), stateFile: home.appendingPathComponent(".claude.json"))
        }

        public init(configDir: URL, stateFile: URL? = nil) {
            self.configDir = configDir
            self.stateFile = stateFile ?? configDir.appendingPathComponent(".claude.json")
        }
    }

    public static func isClaude(_ command: String) -> Bool {
        command.split(separator: " ").first == "claude"
    }

    /// Runs git: call it off the main thread.
    public static func servers(for directory: String, paths: Paths = .standard) -> [Server] {
        let state = object(at: paths.stateFile)
        let root = projectRoot(of: directory)
        let project = (state["projects"] as? [String: Any])?[projectKey(root, in: state)] as? [String: Any] ?? [:]
        let disabled = Set(project["disabledMcpServers"] as? [String] ?? [])

        // Later sources win a name clash, as in Claude Code: local over project over user.
        var found: [String: Server] = [:]
        func add(_ names: [String], _ source: Source, prefix: String = "") {
            for name in names {
                let full = prefix + name
                found[full] = Server(name: full, label: name, source: source, enabled: !disabled.contains(full))
            }
        }
        add(serverNames(state["mcpServers"]), .user)
        for folder in Set([root, directory]) {
            add(serverNames(object(at: URL(fileURLWithPath: folder).appendingPathComponent(".mcp.json"))["mcpServers"]), .project)
        }
        add(serverNames(project["mcpServers"]), .local)
        for (plugin, names) in pluginServers(root: root, paths: paths) {
            add(names, .plugin(plugin), prefix: "plugin:\(plugin):")
        }
        return found.values.sorted { $0.label.localizedCaseInsensitiveCompare($1.label) == .orderedAscending }
    }

    /// Takes effect in sessions started afterwards: a running agent keeps the servers it has.
    public static func setEnabled(_ name: String, _ enabled: Bool, for directory: String, paths: Paths = .standard) throws {
        try editDisabled(root: projectRoot(of: directory), paths: paths, wait: 3) { disabled in
            disabled.removeAll { $0 == name }
            if !enabled { disabled.append(name) }
        }
    }

    private static func editDisabled(root: String, paths: Paths, wait: TimeInterval, _ edit: (inout [String]) -> Void) throws {
        try locked(paths.stateFile, wait: wait) {
            guard let data = try? Data(contentsOf: paths.stateFile),
                  var state = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw Failure.invalid }
            let key = projectKey(root, in: state)
            var projects = state["projects"] as? [String: Any] ?? [:]
            var project = projects[key] as? [String: Any] ?? [:]
            var disabled = project["disabledMcpServers"] as? [String] ?? []
            edit(&disabled)
            project["disabledMcpServers"] = disabled
            projects[key] = project
            state["projects"] = projects
            let out = try JSONSerialization.data(withJSONObject: state, options: [.prettyPrinted, .withoutEscapingSlashes])
            // Replacing the file would drop its 0600 mode; it holds account details.
            let attributes = try? FileManager.default.attributesOfItem(atPath: paths.stateFile.path)
            try out.write(to: paths.stateFile, options: .atomic)
            if let mode = attributes?[.posixPermissions] {
                try? FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: paths.stateFile.path)
            }
        }
    }

    // MARK: Off by default

    /// Claude Code has no "installed but off" state: a server set up for every project runs in
    /// every project until that project switches it off. Terminaly keeps the list of servers that
    /// should start switched off and applies it once per project, before the project's first
    /// Claude session and before listing its servers. After that the project's own switch stands.
    public struct Defaults: Codable, Equatable, Sendable {
        public var off: [String] = []
        /// Per project root, the servers already switched off there once.
        public var applied: [String: [String]] = [:]

        public init() {}

        public static var url: URL { TerminalyPaths.stateDir.appendingPathComponent("mcp-defaults.json") }

        public static func load(from url: URL = url) -> Defaults {
            guard let data = try? Data(contentsOf: url),
                  let value = try? JSONDecoder().decode(Defaults.self, from: data) else { return Defaults() }
            return value
        }

        public func save(to url: URL = url) throws {
            let enc = JSONEncoder()
            enc.outputFormatting = [.prettyPrinted, .sortedKeys]
            try enc.encode(self).write(to: url, options: .atomic)
        }
    }

    /// The servers every project gets: the ones that can be made off by default. `enabled` here
    /// means "on by default".
    public static func globalServers(paths: Paths = .standard, defaults: URL = Defaults.url) -> [Server] {
        let off = Set(Defaults.load(from: defaults).off)
        var found: [Server] = serverNames(object(at: paths.stateFile)["mcpServers"]).map {
            Server(name: $0, label: $0, source: .user, enabled: !off.contains($0))
        }
        for (plugin, names) in pluginServers(root: nil, paths: paths) {
            for name in names {
                let full = "plugin:\(plugin):\(name)"
                found.append(Server(name: full, label: name, source: .plugin(plugin), enabled: !off.contains(full)))
            }
        }
        return found.sorted { $0.label.localizedCaseInsensitiveCompare($1.label) == .orderedAscending }
    }

    public static func setOffByDefault(_ name: String, _ off: Bool, defaults url: URL = Defaults.url) throws {
        var defaults = Defaults.load(from: url)
        defaults.off.removeAll { $0 == name }
        if off {
            defaults.off.append(name)
        } else {
            // Forget where it was applied: making it off by default again starts over.
            defaults.applied = defaults.applied.mapValues { $0.filter { $0 != name } }.filter { !$0.value.isEmpty }
        }
        try defaults.save(to: url)
    }

    /// Switches the off-by-default servers off in the project of `directory`, each one only the
    /// first time. `wait` is how long to wait for Claude Code's lock: keep it short on the main thread.
    public static func applyDefaults(for directory: String, paths: Paths = .standard, defaults url: URL = Defaults.url, wait: TimeInterval = 3) {
        var defaults = Defaults.load(from: url)
        guard !defaults.off.isEmpty else { return }
        let root = projectRoot(of: directory)
        let done = defaults.applied[root] ?? []
        let pending = defaults.off.filter { !done.contains($0) }
        guard !pending.isEmpty else { return }
        do {
            try editDisabled(root: root, paths: paths, wait: wait) { disabled in
                disabled.append(contentsOf: pending.filter { !disabled.contains($0) })
            }
        } catch {
            return  // not recorded as applied: the next session start tries again
        }
        defaults.applied[root] = done + pending
        try? defaults.save(to: url)
    }

    // MARK: Lookup

    /// Claude Code files a folder under the main checkout of its repository, worktrees included.
    private static func projectRoot(of directory: String) -> String {
        (try? Git.mainRepository(of: directory)) ?? directory
    }

    /// The entry may have been written with or without symlinks resolved (`/tmp` → `/private/tmp`).
    private static func projectKey(_ root: String, in state: [String: Any]) -> String {
        let projects = state["projects"] as? [String: Any] ?? [:]
        let resolved = URL(fileURLWithPath: root).resolvingSymlinksInPath().path
        return [root, resolved].first { projects[$0] != nil } ?? root
    }

    private static func object(at url: URL) -> [String: Any] {
        guard let data = try? Data(contentsOf: url) else { return [:] }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    }

    private static func serverNames(_ value: Any?) -> [String] {
        (value as? [String: Any]).map { Array($0.keys) } ?? []
    }

    /// Servers that ship inside the plugins enabled for this folder.
    /// `root` nil: only the plugins enabled for every project.
    private static func pluginServers(root: String?, paths: Paths) -> [(String, [String])] {
        var enabled: [String: Bool] = [:]
        var files = [paths.configDir.appendingPathComponent("settings.json")]
        if let root {
            let claude = URL(fileURLWithPath: root).appendingPathComponent(".claude")
            files += [claude.appendingPathComponent("settings.json"), claude.appendingPathComponent("settings.local.json")]
        }
        for file in files {
            for (id, on) in object(at: file)["enabledPlugins"] as? [String: Any] ?? [:] {
                if let on = on as? Bool { enabled[id] = on }
            }
        }
        let installed = object(at: paths.configDir.appendingPathComponent("plugins/installed_plugins.json"))["plugins"] as? [String: Any] ?? [:]
        var out: [(String, [String])] = []
        for (id, on) in enabled where on {
            guard let installs = installed[id] as? [[String: Any]],
                  let path = installs.last?["installPath"] as? String else { continue }
            let dir = URL(fileURLWithPath: path)
            var names = serverNames(object(at: dir.appendingPathComponent(".mcp.json"))["mcpServers"])
            let manifest = object(at: dir.appendingPathComponent(".claude-plugin/plugin.json"))["mcpServers"]
            if let file = manifest as? String {
                names += serverNames(object(at: dir.appendingPathComponent(file))["mcpServers"])
            } else {
                names += serverNames(manifest)
            }
            guard !names.isEmpty else { continue }
            out.append((String(id.split(separator: "@").first ?? Substring(id)), Array(Set(names))))
        }
        return out
    }

    // MARK: Lock

    /// Same protocol as Claude Code (the `proper-lockfile` package): a `<file>.lock` folder held
    /// while writing, taken over when its holder has not touched it for 10 s.
    private static func locked(_ file: URL, wait: TimeInterval, _ body: () throws -> Void) throws {
        let lock = file.path + ".lock"
        let deadline = Date().addingTimeInterval(wait)
        while mkdir(lock, 0o755) != 0 {
            guard errno == EEXIST else { throw Failure.busy }
            let touched = (try? FileManager.default.attributesOfItem(atPath: lock))?[.modificationDate] as? Date
            if let touched, Date().timeIntervalSince(touched) > 10 {
                rmdir(lock)
                continue
            }
            guard Date() < deadline else { throw Failure.busy }
            usleep(50_000)
        }
        defer { rmdir(lock) }
        try body()
    }
}
