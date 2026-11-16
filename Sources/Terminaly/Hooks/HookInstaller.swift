import Foundation

/// Adds Terminaly status hooks to Claude Code's user settings (~/.claude/settings.json).
/// Hooks are no-ops outside Terminaly because they require TERMINALY_SESSION_ID.
enum ClaudeHookInstaller {
    static let marker = "TERMINALY_SESSION_ID"
    static let events = ["SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse",
                         "Notification", "PermissionRequest", "Stop", "SubagentStop", "SessionEnd"]
    /// Events whose hook entries take a tool matcher.
    static let toolEvents: Set<String> = ["PreToolUse", "PostToolUse", "PermissionRequest"]

    static var settingsURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/settings.json")
    }

    static func command(for event: String) -> String {
        """
        [ -n "$TERMINALY_SESSION_ID" ] && curl -s -m 2 -X POST -H "X-Terminaly-Token: $TERMINALY_HOOK_TOKEN" \
        --data-binary @- "http://127.0.0.1:$TERMINALY_HOOK_PORT/hook/$TERMINALY_SESSION_ID/\(event)" >/dev/null 2>&1; exit 0
        """
    }

    static var isInstalled: Bool {
        guard let data = try? Data(contentsOf: settingsURL),
              let text = String(data: data, encoding: .utf8) else { return false }
        return text.contains(marker)
    }

    enum InstallError: LocalizedError {
        case invalidJSON
        var errorDescription: String? { String(localized: "~/.claude/settings.json is not valid JSON; left untouched.") }
    }

    /// Idempotent: removes previous Terminaly entries, then adds current ones. Backs up the original file.
    static func install() throws {
        try rewrite(settingsURL, invalid: InstallError.invalidJSON) { hooks in
            for event in events {
                var entry: [String: Any] = ["hooks": [["type": "command", "command": command(for: event)]]]
                if toolEvents.contains(event) { entry["matcher"] = "*" }
                hooks[event] = (hooks[event] as? [Any] ?? []) + [entry]
            }
        }
    }

    static func uninstall() throws {
        try rewrite(settingsURL, invalid: InstallError.invalidJSON) { _ in }
    }

    /// Rewrites the `hooks` table of a JSON settings file, keeping everything that is not Terminaly's.
    static func rewrite(_ settingsURL: URL, invalid: Error, _ add: (inout [String: Any]) -> Void) throws {
        let fm = FileManager.default
        var root: [String: Any] = [:]
        if let data = try? Data(contentsOf: settingsURL) {
            guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw invalid
            }
            root = obj
            let backup = settingsURL.appendingPathExtension("terminaly-backup")
            try? fm.removeItem(at: backup)
            try fm.copyItem(at: settingsURL, to: backup)
        } else {
            try fm.createDirectory(at: settingsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        }

        var hooks = root["hooks"] as? [String: Any] ?? [:]
        for (event, value) in hooks {
            guard let entries = value as? [Any] else { continue }
            let kept = entries.filter { !String(describing: $0).contains(marker) }
            hooks[event] = kept.isEmpty ? nil : kept
        }
        add(&hooks)
        root["hooks"] = hooks.isEmpty ? nil : hooks

        let data = try JSONSerialization.data(withJSONObject: root,
                                              options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try data.write(to: settingsURL, options: .atomic)
    }
}

/// Adds the same status hooks to Codex (`~/.codex/hooks.json`): its hook events and payloads follow
/// Claude Code's. Codex skips new or changed hooks until the user trusts them with `/hooks`.
enum CodexHookInstaller {
    /// No `Notification` in Codex; `SubagentStop` says nothing about the turn.
    static let events = ["SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse",
                         "PermissionRequest", "Stop", "SessionEnd"]

    static var defaultHome: URL {
        ProcessInfo.processInfo.environment["CODEX_HOME"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")
    }

    static func isInstalled(in home: URL = defaultHome) -> Bool {
        (try? String(contentsOf: file(in: home), encoding: .utf8))?.contains(ClaudeHookInstaller.marker) ?? false
    }

    enum InstallError: LocalizedError {
        case invalidJSON
        var errorDescription: String? { String(localized: "~/.codex/hooks.json is not valid JSON; left untouched.") }
    }

    static func install(in home: URL = defaultHome) throws {
        try ClaudeHookInstaller.rewrite(file(in: home), invalid: InstallError.invalidJSON) { hooks in
            for event in events {
                // Without a timeout Codex would wait up to 10 minutes for a hook.
                let hook: [String: Any] = ["type": "command", "command": ClaudeHookInstaller.command(for: event), "timeout": 5]
                hooks[event] = (hooks[event] as? [Any] ?? []) + [["hooks": [hook]]]
            }
        }
    }

    static func uninstall(in home: URL = defaultHome) throws {
        try ClaudeHookInstaller.rewrite(file(in: home), invalid: InstallError.invalidJSON) { _ in }
    }

    private static func file(in home: URL) -> URL { home.appendingPathComponent("hooks.json") }
}
