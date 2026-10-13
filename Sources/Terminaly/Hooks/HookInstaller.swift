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
        var errorDescription: String? { "~/.claude/settings.json is not valid JSON; left untouched." }
    }

    /// Idempotent: removes previous Terminaly entries, then adds current ones. Backs up the original file.
    static func install() throws {
        try rewrite { hooks in
            for event in events {
                var entry: [String: Any] = ["hooks": [["type": "command", "command": command(for: event)]]]
                if toolEvents.contains(event) { entry["matcher"] = "*" }
                hooks[event] = (hooks[event] as? [Any] ?? []) + [entry]
            }
        }
    }

    static func uninstall() throws {
        try rewrite { _ in }
    }

    private static func rewrite(_ add: (inout [String: Any]) -> Void) throws {
        let fm = FileManager.default
        var root: [String: Any] = [:]
        if let data = try? Data(contentsOf: settingsURL) {
            guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw InstallError.invalidJSON
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
