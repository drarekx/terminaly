import Foundation

/// One-line summary of the tool an agent is running ("Edit AppStore.swift", "Bash: npm test"),
/// built from a PreToolUse hook so a swarm can be watched without opening every terminal.
public enum ToolActivity {
    static let maxArgument = 60

    public static func summary(toolName rawName: String?, input: [String: Any]?) -> String? {
        guard var name = rawName?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else { return nil }
        // MCP tools arrive as mcp__<server>__<tool>; the server name only adds noise.
        if name.hasPrefix("mcp__"), let range = name.range(of: "__", options: .backwards), range.lowerBound > name.index(name.startIndex, offsetBy: 4) {
            name = String(name[range.upperBound...])
        }
        // A file reads as the object of the verb ("Edit AppStore.swift"); anything else is an argument ("Bash: npm test").
        return name + (argument(input: input ?? [:]) ?? "")
    }

    private static func argument(input: [String: Any]) -> String? {
        func string(_ key: String) -> String? { (input[key] as? String).flatMap(firstLine) }
        func file(_ path: String) -> String {
            let base = (path as NSString).lastPathComponent
            return " " + clip(base.isEmpty ? path : base)
        }
        if let path = string("file_path") ?? string("notebook_path") { return file(path) }
        // Grep and Glob also carry a `path`: the pattern says more.
        if let arg = string("command") ?? string("cmd") ?? string("pattern") ?? string("query") ?? string("url")
            ?? string("description") ?? string("prompt") {
            return ": " + clip(arg)
        }
        if let path = string("path") { return file(path) }
        // Codex may send `command` as an argv array (["bash", "-lc", "npm test"]).
        if let argv = input["command"] as? [String], !argv.isEmpty {
            let shell = argv.count >= 3 && ["bash", "sh", "zsh"].contains((argv[0] as NSString).lastPathComponent) && argv[1].hasPrefix("-")
            return firstLine((shell ? Array(argv[2...]) : argv).joined(separator: " ")).map { ": " + clip($0) }
        }
        return nil
    }

    private static func firstLine(_ s: String) -> String? {
        s.split(whereSeparator: \.isNewline).lazy.map { $0.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty }
    }

    private static func clip(_ s: String) -> String {
        s.count > maxArgument ? String(s.prefix(maxArgument - 1)) + "…" : s
    }
}
