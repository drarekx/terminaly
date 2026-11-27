import Foundation
import TerminalyKit

/// The MCP servers Claude Code starts for a folder, and the per-project switch behind its `/mcp`
/// dialog. Each enabled server is a process tree of its own in every session (often 100–300 MB),
/// so turning off the ones a project does not need is the cheapest way to shrink a session.
///
/// Claude has no command for this: the switch is `projects[<repo>].disabledMcpServers` in its
/// `.claude.json`, which it rewrites all the time. Writes here take the same lock it does.
enum ClaudeMCP {
    enum Source: Equatable {
        case user, local, project
        case plugin(String)
    }

    struct Server: Identifiable, Equatable {
        /// The name Claude knows it by, as stored in `disabledMcpServers`.
        let name: String
        let label: String
        let source: Source
        var enabled: Bool
        var id: String { name }
    }

    enum Failure: LocalizedError {
        case busy, invalid

        var errorDescription: String? {
            switch self {
            case .busy: return String(localized: "Claude Code is using its settings file. Try again.")
            case .invalid: return String(localized: "Claude Code's settings file could not be read.")
            }
        }
    }

    /// Claude Code keeps everything in `CLAUDE_CONFIG_DIR` when set; otherwise the settings folder
    /// is `~/.claude` and the state file sits next to it, in the home folder.
    struct Paths {
        var configDir: URL
        var stateFile: URL

        static var standard: Paths {
            if let dir = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"], !dir.isEmpty {
                return Paths(configDir: URL(fileURLWithPath: dir))
            }
            let home = FileManager.default.homeDirectoryForCurrentUser
            return Paths(configDir: home.appendingPathComponent(".claude"), stateFile: home.appendingPathComponent(".claude.json"))
        }

        init(configDir: URL, stateFile: URL? = nil) {
            self.configDir = configDir
            self.stateFile = stateFile ?? configDir.appendingPathComponent(".claude.json")
        }
    }

    static func isClaude(_ command: String) -> Bool {
        command.split(separator: " ").first == "claude"
    }

    /// Runs git: call it off the main thread.
    static func servers(for directory: String, paths: Paths = .standard) -> [Server] {
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
    static func setEnabled(_ name: String, _ enabled: Bool, for directory: String, paths: Paths = .standard) throws {
        let root = projectRoot(of: directory)
        try locked(paths.stateFile) {
            guard let data = try? Data(contentsOf: paths.stateFile),
                  var state = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw Failure.invalid }
            let key = projectKey(root, in: state)
            var projects = state["projects"] as? [String: Any] ?? [:]
            var project = projects[key] as? [String: Any] ?? [:]
            var disabled = project["disabledMcpServers"] as? [String] ?? []
            disabled.removeAll { $0 == name }
            if !enabled { disabled.append(name) }
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
    private static func pluginServers(root: String, paths: Paths) -> [(String, [String])] {
        var enabled: [String: Bool] = [:]
        let claude = URL(fileURLWithPath: root).appendingPathComponent(".claude")
        for file in [paths.configDir.appendingPathComponent("settings.json"),
                     claude.appendingPathComponent("settings.json"),
                     claude.appendingPathComponent("settings.local.json")] {
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
    private static func locked(_ file: URL, _ body: () throws -> Void) throws {
        let lock = file.path + ".lock"
        let deadline = Date().addingTimeInterval(3)
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
