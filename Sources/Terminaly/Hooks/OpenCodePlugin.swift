import Foundation

/// Installs the Terminaly plugin for opencode 2 (~/.config/opencode/plugins/terminaly): its TUI part
/// reports status, permission requests and the final answer of a turn to the session host, as the
/// Claude Code hooks do. The TUI part, because it runs in the session's own process and sees
/// TERMINALY_*; opencode's server is one background service shared by every window.
enum OpenCodePluginInstaller {
    enum State { case missing, outdated, current }

    static var defaultPluginsDir: URL {
        let config = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config")
        return config.appendingPathComponent("opencode/plugins")
    }

    private static func folder(in pluginsDir: URL) -> URL { pluginsDir.appendingPathComponent("terminaly") }

    static func state(in pluginsDir: URL = defaultPluginsDir) -> State {
        let dir = folder(in: pluginsDir)
        let found = files.map { try? String(contentsOf: dir.appendingPathComponent($0.name), encoding: .utf8) }
        if found.allSatisfy({ $0 == nil }) { return .missing }
        return zip(found, files).allSatisfy { $0 == $1.content } ? .current : .outdated
    }

    static func install(in pluginsDir: URL = defaultPluginsDir) throws {
        let dir = folder(in: pluginsDir)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for file in files {
            try Data(file.content.utf8).write(to: dir.appendingPathComponent(file.name), options: .atomic)
        }
    }

    /// Removes our files, and the folder only if nothing else is in it.
    static func uninstall(in pluginsDir: URL = defaultPluginsDir) throws {
        let fm = FileManager.default
        let dir = folder(in: pluginsDir)
        for file in files where fm.fileExists(atPath: dir.appendingPathComponent(file.name).path) {
            try fm.removeItem(at: dir.appendingPathComponent(file.name))
        }
        if (try? fm.contentsOfDirectory(atPath: dir.path))?.isEmpty == true { try? fm.removeItem(at: dir) }
    }

    /// A package with a server part (which does nothing) so opencode loads the TUI part by itself.
    static let files: [(name: String, content: String)] = [
        ("package.json", #"""
        {
          "name": "terminaly-opencode",
          "version": "1.0.0",
          "type": "module",
          "exports": { ".": "./server.js", "./tui": "./tui.js" }
        }
        """# + "\n"),
        ("server.js", #"""
        // Terminaly: the status reporting lives in the TUI part (tui.js); this part only makes it load.
        import { Plugin } from "@opencode/plugin"

        export default Plugin.define({ id: "terminaly", setup() {} })
        """# + "\n"),
        ("tui.js", #"""
        // Terminaly: reports this session's status, permission requests and final answer to the
        // Terminaly session host. Does nothing outside Terminaly.
        import { Plugin } from "@opencode/plugin/tui"

        export default Plugin.define({
          id: "terminaly.tui",
          setup(ctx) {
            const env = globalThis.process?.env ?? {}
            const { TERMINALY_SESSION_ID: session, TERMINALY_HOOK_PORT: port, TERMINALY_HOOK_TOKEN: token } = env
            if (!session || !port) return

            const post = (event, body = {}) =>
              fetch(`http://127.0.0.1:${port}/hook/${session}/${event}`, {
                method: "POST",
                headers: { "X-Terminaly-Token": token ?? "" },
                body: JSON.stringify(body),
              }).catch(() => {})

            // The server is shared by every opencode window: only the session open in this one counts.
            const root = () => {
              const route = ctx.ui.router.current()
              return route.type === "session" ? ctx.data.session.root(route.sessionID) : undefined
            }
            const isRoot = (id) => id !== undefined && id === root()
            const inFamily = (id) => {
              const r = root()
              return id !== undefined && r !== undefined && ctx.data.session.root(id) === r
            }

            let answer = ""
            post("SessionStart")
            return ctx.data.listen(({ details: e }) => {
              const id = e.data?.sessionID
              switch (e.type) {
                case "session.execution.started":
                  if (!isRoot(id)) return
                  answer = ""
                  return post("UserPromptSubmit", { session_id: id })
                case "session.text.ended":
                  if (isRoot(id)) answer = e.data.text ?? answer
                  return
                case "session.execution.succeeded":
                case "session.execution.failed":
                case "session.execution.interrupted":
                  if (!isRoot(id)) return
                  return post("Stop", { session_id: id, last_assistant_message: answer })
                case "permission.asked":
                  if (!inFamily(id)) return
                  return post("PermissionRequest", { message: e.data.message ?? `Permission: ${e.data.action}` })
                case "permission.replied":
                  if (inFamily(id)) return post("PostToolUse")
              }
            })
          },
        })
        """# + "\n"),
    ]
}
