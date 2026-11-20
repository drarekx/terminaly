import Foundation

/// What the sidebar filter keeps: text (session name, project name or branch) and a status.
/// View state only: never persisted, and ⌘] / ⌘[ keep walking the unfiltered order.
struct SessionFilter: Equatable {
    enum Status: CaseIterable {
        case all, needsInput, working, idle

        func matches(_ status: SessionStatus) -> Bool {
            switch self {
            case .all: true
            case .needsInput: status == .needsInput
            // A session that is starting is already busy for whoever is scanning the list.
            case .working: status == .working || status == .starting
            case .idle: status == .idle
            }
        }
    }

    var query = ""
    var status: Status = .all

    var isActive: Bool { !terms.isEmpty || status != .all }

    /// Every word must appear somewhere, so "api main" finds the `main` branch of the api project.
    private var terms: [String] {
        query.split(whereSeparator: \.isWhitespace).map(String.init)
    }

    func matches(_ session: Session, projectName: String) -> Bool {
        guard status.matches(session.status) else { return false }
        let fields = [session.title, projectName, session.branch ?? ""]
        return terms.allSatisfy { term in
            fields.contains { $0.range(of: term, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
        }
    }

    /// Filters one project's sidebar groups (a session and the workers listed under it) into
    /// sidebar rows. A matching worker keeps its parent visible; a matching parent keeps all its
    /// workers. Collapsed workers stay hidden unless one of them matches.
    func rows(_ groups: [(session: Session, workers: [Session], collapsed: Bool)],
              projectName: String) -> [(session: Session, isWorker: Bool)] {
        groups.flatMap { group -> [(session: Session, isWorker: Bool)] in
            let parentMatches = matches(group.session, projectName: projectName)
            let matchingWorkers = group.workers.filter { matches($0, projectName: projectName) }
            guard isActive else {
                return [(group.session, false)] + (group.collapsed ? [] : group.workers.map { ($0, true) })
            }
            guard parentMatches || !matchingWorkers.isEmpty else { return [] }
            let shown = parentMatches ? (group.collapsed ? [] : group.workers) : matchingWorkers
            return [(group.session, false)] + shown.map { ($0, true) }
        }
    }
}

extension AppStore {
    /// `sidebarSessions(in:)` grouped by parent, with collapsed workers included, for the filter.
    func sidebarGroups(in project: Project) -> [(session: Session, workers: [Session], collapsed: Bool)] {
        sidebarSessions(in: project).filter { !$0.isWorker }.map {
            ($0.session, workers(of: $0.session.id), $0.session.workersCollapsed == true)
        }
    }
}

/// The sidebar filter shared by every workspace page of the window.
@MainActor @Observable
final class SidebarFilterState {
    static let shared = SidebarFilterState()

    var filter = SessionFilter()
    /// Bumped by Session → Filter Sessions (⇧⌘F); the visible page focuses its field.
    private(set) var focusRequests = 0

    func requestFocus() { focusRequests += 1 }
    func clear() { filter = SessionFilter() }
}
