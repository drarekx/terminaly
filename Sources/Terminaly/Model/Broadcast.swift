import Foundation
import TerminalyKit

/// `@name` mentions in a prompt sent to several sessions (Send to Sessions…).
enum BroadcastParser {
    /// A mention starts a word: "a@b" (an email, a decorator in code) is not one.
    private static let mention = try! NSRegularExpression(pattern: #"(?<![^\s])@([\p{L}\p{N}_-]+)[,:]?"#)

    /// Case- and accent-insensitive, with spaces as dashes so "@api-fix" names "API fix".
    static func normalize(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .split(whereSeparator: \.isWhitespace).joined(separator: "-")
    }

    /// A mention selects every session whose title, or one of its words, starts with it.
    static func matches(_ token: String, title: String) -> Bool {
        let t = normalize(token)
        guard !t.isEmpty else { return false }
        let name = normalize(title)
        return name.hasPrefix(t) || name.split(separator: "-").contains { $0.hasPrefix(t) }
    }

    /// The text without the mentions that named a session, and those sessions. A mention that
    /// names none stays in the text: it may be meant for the agent.
    static func parse(text: String, sessions: [(id: UUID, title: String)]) -> (cleanText: String, matchedIDs: Set<UUID>) {
        let ns = text as NSString
        var matched = Set<UUID>()
        var removals: [NSRange] = []
        for m in mention.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let token = ns.substring(with: m.range(at: 1))
            let ids = sessions.filter { matches(token, title: $0.title) }.map(\.id)
            guard !ids.isEmpty else { continue }
            matched.formUnion(ids)
            var r = m.range
            // Take one space with it, so "@a fix it" leaves "fix it", not " fix it".
            if r.upperBound < ns.length, ns.character(at: r.upperBound) == 0x20 { r.length += 1 }
            else if r.location > 0, ns.character(at: r.location - 1) == 0x20 { r.location -= 1; r.length += 1 }
            removals.append(r)
        }
        let clean = NSMutableString(string: text)
        for r in removals.reversed() { clean.deleteCharacters(in: r) }
        return ((clean as String).trimmingCharacters(in: .whitespacesAndNewlines), matched)
    }
}

/// Whether Send to Sessions… is open. View state, like the sidebar filter.
@MainActor @Observable
final class BroadcastState {
    static let shared = BroadcastState()
    var isPresented = false
    /// Snapshot mode only: lists stopped sessions as if they were running, to draw the sheet.
    var previewStoppedSessions = false
    var previewText = ""
}

extension AppStore {
    /// Sessions a prompt can go to: running in the host. Paused ones drop their input.
    func canReceiveBroadcast(_ s: Session) -> Bool {
        terminals.isRunning(s.id) && s.status != .exited && s.status != .paused
    }

    /// Sends the text with Enter to each session. One showing a permission dialog is skipped:
    /// Enter would accept it. Working agents get it too; they queue it for after their turn.
    @discardableResult
    func broadcast(_ text: String, to ids: [UUID]) -> (sent: [UUID], skipped: [UUID]) {
        var sent: [UUID] = [], skipped: [UUID] = []
        for id in ids {
            guard let s = session(id), canReceiveBroadcast(s), !s.permissionPending else { skipped.append(id); continue }
            terminals.sendLine(id, text)
            sent.append(id)
        }
        return (sent, skipped)
    }
}
