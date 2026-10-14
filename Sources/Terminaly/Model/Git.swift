import Foundation

/// Minimal git plumbing for worktree sessions. Runs /usr/bin/git off the main thread.
enum Git {
    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    @discardableResult
    static func run(_ args: [String], in dir: String) async throws -> String {
        try await withCheckedThrowingContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
                p.arguments = ["-C", dir] + args
                let out = Pipe(), err = Pipe()
                p.standardOutput = out
                p.standardError = err
                do {
                    try p.run()
                    let o = out.fileHandleForReading.readDataToEndOfFile()
                    let e = err.fileHandleForReading.readDataToEndOfFile()
                    p.waitUntilExit()
                    if p.terminationStatus == 0 {
                        cont.resume(returning: String(decoding: o, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
                    } else {
                        let msg = String(decoding: e, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                        cont.resume(throwing: Failure(message: msg.isEmpty ? "git \(args.first ?? "") failed" : msg))
                    }
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }
    }

    static func isRepository(_ path: String) async -> Bool {
        (try? await run(["rev-parse", "--is-inside-work-tree"], in: path)) == "true"
    }

    /// Branch names: letters, digits, `. _ / -`; anything else becomes `-`.
    static func sanitizeBranch(_ name: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._/-"))
        let mapped = name.trimmingCharacters(in: .whitespaces).unicodeScalars
            .map { allowed.contains($0) ? Character($0) : "-" }
        return String(mapped).trimmingCharacters(in: CharacterSet(charactersIn: "-/."))
    }

    /// Worktrees live next to the repo, in `<repo>.worktrees/<branch>`, so the repo stays clean.
    static func worktreePath(repo: String, branch: String) -> String {
        let url = URL(fileURLWithPath: repo)
        return url.deletingLastPathComponent()
            .appendingPathComponent(url.lastPathComponent + ".worktrees")
            .appendingPathComponent(branch.replacingOccurrences(of: "/", with: "-"))
            .path
    }

    /// Creates the worktree on a new branch from HEAD, or checks out an existing branch.
    static func addWorktree(repo: String, branch: String) async throws -> String {
        let path = worktreePath(repo: repo, branch: branch)
        try await run(["check-ref-format", "--branch", branch], in: repo)
        let exists = (try? await run(["show-ref", "--verify", "--quiet", "refs/heads/\(branch)"], in: repo)) != nil
        try FileManager.default.createDirectory(at: URL(fileURLWithPath: path).deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        if exists {
            try await run(["worktree", "add", path, branch], in: repo)
        } else {
            try await run(["worktree", "add", "-b", branch, path], in: repo)
        }
        return path
    }

    /// Fails (and keeps the files) when the worktree has uncommitted changes. The branch is kept.
    static func removeWorktree(repo: String, path: String) async throws {
        try await run(["worktree", "remove", path], in: repo)
    }
}
