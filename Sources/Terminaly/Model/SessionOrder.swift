import Foundation

/// Sidebar order, also used by ⌘] / ⌘[. Pure so the self-test can check it.
enum SessionOrder {
    /// Pinned first, then oldest first.
    static func precedes(_ a: Session, _ b: Session) -> Bool {
        (a.pinned ? 0 : 1, a.createdAt) < (b.pinned ? 0 : 1, b.createdAt)
    }

    /// Sessions `id` started that are listed with it: same project, not archived. A worker's own
    /// workers are not nested under it.
    static func workers(of id: UUID, in sessions: [Session]) -> [Session] {
        guard let parent = sessions.first(where: { $0.id == id }) else { return [] }
        if let grand = parent.parentID, sessions.first(where: { $0.id == grand })?.projectID == parent.projectID {
            return []
        }
        return sessions
            .filter { $0.parentID == id && !$0.archived && $0.projectID == parent.projectID }
            .sorted(by: precedes)
    }

    /// Every session of the project followed by its workers. Pinning a worker only moves it among
    /// its siblings. A worker whose parent is gone, archived or in another project is listed on its own.
    static func sidebar(_ sessions: [Session], project: UUID) -> [(session: Session, isWorker: Bool)] {
        let all = sessions.filter { $0.projectID == project && !$0.archived }.sorted(by: precedes)
        let nested = Set(all.flatMap { workers(of: $0.id, in: sessions) }.map(\.id))
        return all.filter { !nested.contains($0.id) }.flatMap { s in
            [(s, false)] + (s.workersCollapsed == true ? [] : workers(of: s.id, in: sessions).map { ($0, true) })
        }
    }
}
