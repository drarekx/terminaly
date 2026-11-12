import Foundation

/// Minimal git plumbing for worktree sessions. The async calls run /usr/bin/git off the caller's thread.
public enum Git {
    public struct Failure: LocalizedError {
        public let message: String
        public var errorDescription: String? { message }

        public init(message: String) { self.message = message }
    }

    /// Blocks until git exits: for the CLI, never for the main thread or the daemon queue.
    @discardableResult
    public static func runSync(_ args: [String], in dir: String) throws -> String {
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
            throw Failure(message: msg.isEmpty ? "git \(args.first ?? "") failed" : msg)
        }
        return String(decoding: o, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    @discardableResult
    public static func run(_ args: [String], in dir: String) async throws -> String {
        try await withCheckedThrowingContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                cont.resume(with: Result { try runSync(args, in: dir) })
            }
        }
    }

    public static func isRepository(_ path: String) async -> Bool {
        (try? await run(["rev-parse", "--is-inside-work-tree"], in: path)) == "true"
    }

    /// The main checkout of the repository holding `path`, also when `path` is inside one of its worktrees
    /// (so a worktree made from a worktree lands next to the others, not nested).
    public static func mainRepository(of path: String) throws -> String {
        let common = try runSync(["rev-parse", "--path-format=absolute", "--git-common-dir"], in: path)
        let url = URL(fileURLWithPath: common)
        if url.lastPathComponent == ".git" { return url.deletingLastPathComponent().path }
        return try runSync(["rev-parse", "--show-toplevel"], in: path)
    }

    /// Branch names: letters, digits, `. _ / -`; anything else becomes `-`.
    public static func sanitizeBranch(_ name: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._/-"))
        let mapped = name.trimmingCharacters(in: .whitespaces).unicodeScalars
            .map { allowed.contains($0) ? Character($0) : "-" }
        return String(mapped).trimmingCharacters(in: CharacterSet(charactersIn: "-/."))
    }

    /// Worktrees live next to the repo, in `<repo>.worktrees/<branch>`, so the repo stays clean.
    public static func worktreePath(repo: String, branch: String) -> String {
        let url = URL(fileURLWithPath: repo)
        return url.deletingLastPathComponent()
            .appendingPathComponent(url.lastPathComponent + ".worktrees")
            .appendingPathComponent(branch.replacingOccurrences(of: "/", with: "-"))
            .path
    }

    /// Creates the worktree on a new branch from `base` (HEAD of `repo` when nil), or checks out an existing branch.
    public static func addWorktreeSync(repo: String, branch: String, base: String? = nil) throws -> String {
        let path = worktreePath(repo: repo, branch: branch)
        try runSync(["check-ref-format", "--branch", branch], in: repo)
        let exists = (try? runSync(["show-ref", "--verify", "--quiet", "refs/heads/\(branch)"], in: repo)) != nil
        try FileManager.default.createDirectory(at: URL(fileURLWithPath: path).deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        if exists {
            try runSync(["worktree", "add", path, branch], in: repo)
        } else {
            try runSync(["worktree", "add", "-b", branch, path] + (base.map { [$0] } ?? []), in: repo)
        }
        return path
    }

    public static func addWorktree(repo: String, branch: String) async throws -> String {
        try await withCheckedThrowingContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                cont.resume(with: Result { try addWorktreeSync(repo: repo, branch: branch) })
            }
        }
    }

    /// Fails (and keeps the files) when the worktree has uncommitted changes. The branch is kept.
    public static func removeWorktree(repo: String, path: String) async throws {
        try await run(["worktree", "remove", path], in: repo)
    }
}
