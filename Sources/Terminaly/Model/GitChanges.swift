import Foundation
import TerminalyKit

/// What an agent changed in its folder: uncommitted files, and for a branch session the commits
/// the main checkout's branch doesn't have yet. `load` blocks on git: call it off the main thread.
struct GitChanges: Equatable {
    struct File: Identifiable, Equatable {
        /// Relative to the session's folder.
        var path: String
        var oldPath: String? = nil
        /// One letter: M, A, D, R, C, T, U (unmerged) or ? (untracked).
        var status: String
        var added: Int? = nil
        var removed: Int? = nil
        var id: String { path }
        var isDeleted: Bool { status == "D" }
    }

    struct Commit: Identifiable, Equatable {
        var sha: String
        var subject: String
        var id: String { sha }
    }

    struct ShortStat: Equatable {
        var files = 0
        var insertions = 0
        var deletions = 0
    }

    var files: [File] = []
    var branch: String? = nil
    /// The main checkout's current branch the commits are compared with.
    var base: String? = nil
    var commits: [Commit] = []
    var branchStat: ShortStat? = nil

    var isEmpty: Bool { files.isEmpty && commits.isEmpty }

    // MARK: Parsing (pure, checked in self-test step 0)

    /// `git status --porcelain=v1 -z`: `XY path\0`, and `XY new\0old\0` for renames and copies.
    static func parseStatus(_ output: String) -> [File] {
        var fields = output.split(separator: "\0", omittingEmptySubsequences: true).map(String.init)[...]
        var files: [File] = []
        while let entry = fields.popFirst() {
            guard entry.count > 3 else { continue }
            let xy = Array(entry.prefix(2))
            let path = String(entry.dropFirst(3))
            var file = File(path: path, status: letter(x: xy[0], y: xy[1]))
            if xy[0] == "R" || xy[0] == "C" || xy[1] == "R" || xy[1] == "C" { file.oldPath = fields.popFirst() }
            files.append(file)
        }
        return files
    }

    private static func letter(x: Character, y: Character) -> String {
        if x == "?" { return "?" }
        if x == "U" || y == "U" || (x == "A" && y == "A") || (x == "D" && y == "D") { return "U" }
        return String(x != " " ? x : y)
    }

    /// `git diff --numstat -z`: `added\tremoved\tpath\0`, or `added\tremoved\t\0old\0new\0` for a rename.
    /// Binary files have `-` counts (nil here). Keyed by the new path.
    static func parseNumstat(_ output: String) -> [String: (added: Int?, removed: Int?)] {
        var fields = output.split(separator: "\0", omittingEmptySubsequences: false).map(String.init)[...]
        var result: [String: (added: Int?, removed: Int?)] = [:]
        while let entry = fields.popFirst() {
            let parts = entry.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
            guard parts.count == 3 else { continue }
            var path = String(parts[2])
            if path.isEmpty {
                _ = fields.popFirst()
                path = fields.popFirst() ?? ""
            }
            guard !path.isEmpty else { continue }
            result[path] = (Int(parts[0]), Int(parts[1]))
        }
        return result
    }

    /// `git log --oneline`: `sha subject` per line.
    static func parseLog(_ output: String) -> [Commit] {
        output.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: " ", maxSplits: 1)
            guard let sha = parts.first else { return nil }
            return Commit(sha: String(sha), subject: parts.count > 1 ? String(parts[1]) : "")
        }
    }

    /// `git diff --shortstat`: ` 3 files changed, 10 insertions(+), 2 deletions(-)` (either count may be missing).
    static func parseShortstat(_ output: String) -> ShortStat? {
        var stat = ShortStat()
        var found = false
        for part in output.split(separator: ",") {
            let words = part.split(separator: " ")
            guard words.count >= 2, let n = Int(words[0]) else { continue }
            found = true
            if words[1].hasPrefix("file") { stat.files = n }
            else if words[1].hasPrefix("insertion") { stat.insertions = n }
            else if words[1].hasPrefix("deletion") { stat.deletions = n }
        }
        return found ? stat : nil
    }

    // MARK: Loading

    /// Untracked files are counted as added lines up to this many files and this size each.
    private static let maxCountedFiles = 300
    private static let maxCountedBytes = 2 << 20

    static func load(directory: String, branch sessionBranch: String?, isWorktree: Bool) throws -> GitChanges {
        var changes = GitChanges()
        // Scoped to the folder; status paths stay relative to the repo root, numstat with --relative doesn't.
        let prefix = try git(["rev-parse", "--show-prefix"], in: directory).trimmingCharacters(in: .whitespacesAndNewlines)
        var files = parseStatus(try git(["status", "--porcelain=v1", "-z", "-uall", "--", "."], in: directory))
        // A repo without commits has no HEAD to diff against.
        let counts = (try? git(["diff", "--numstat", "-z", "--relative", "HEAD"], in: directory)).map(parseNumstat) ?? [:]
        var counted = 0
        for i in files.indices {
            if files[i].path.hasPrefix(prefix) { files[i].path.removeFirst(prefix.count) }
            if let old = files[i].oldPath, old.hasPrefix(prefix) { files[i].oldPath = String(old.dropFirst(prefix.count)) }
            if let c = counts[files[i].path] {
                files[i].added = c.added
                files[i].removed = c.removed
            } else if files[i].status == "?", counted < maxCountedFiles {
                counted += 1
                files[i].added = lineCount(URL(fileURLWithPath: directory).appendingPathComponent(files[i].path))
                files[i].removed = files[i].added == nil ? nil : 0
            }
        }
        changes.files = files

        let branch = sessionBranch ?? (isWorktree ? (try? Git.runSync(["branch", "--show-current"], in: directory)) : nil)
        guard let branch, !branch.isEmpty,
              let main = try? Git.mainRepository(of: directory),
              let base = try? Git.runSync(["branch", "--show-current"], in: main), !base.isEmpty,
              base != branch else { return changes }
        changes.branch = branch
        changes.base = base
        changes.commits = parseLog(try git(["log", "--oneline", "--no-decorate", "\(base)..\(branch)"], in: directory))
        changes.branchStat = parseShortstat(try git(["diff", "--shortstat", "\(base)...\(branch)"], in: directory))
        return changes
    }

    /// Lines of a text file; nil for binary or large files.
    private static func lineCount(_ url: URL) -> Int? {
        guard let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize, size <= maxCountedBytes,
              let data = try? Data(contentsOf: url) else { return nil }
        if data.prefix(8000).contains(0) { return nil }
        let newlines = data.reduce(0) { $0 + ($1 == 0x0A ? 1 : 0) }
        return newlines + (data.last.map { $0 == 0x0A ? 0 : 1 } ?? 0)
    }

    /// Like `Git.runSync`, but keeps the output as is: porcelain lines start with a space.
    private static func git(_ args: [String], in dir: String) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        p.arguments = ["-C", dir] + args
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        try p.run()
        let o = out.fileHandleForReading.readDataToEndOfFile()
        let e = err.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            let msg = String(decoding: e, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw Git.Failure(message: msg.isEmpty ? "git \(args.first ?? "") failed" : msg)
        }
        return String(decoding: o, as: UTF8.self)
    }
}
