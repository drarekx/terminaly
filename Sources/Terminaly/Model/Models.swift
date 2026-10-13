import Foundation
import SwiftUI

/// Named group of projects with its own pane layout.
struct Workspace: Identifiable, Codable, Hashable {
    var id = UUID()
    var name: String
    var symbol: String = "square.stack.3d.up.fill"
    var color: FolderColor = .blue
    var layout: PaneNode = .empty()

    static let symbols = [
        "square.stack.3d.up.fill", "briefcase.fill", "house.fill", "hammer.fill", "flask.fill",
        "graduationcap.fill", "gamecontroller.fill", "paintbrush.fill", "leaf.fill", "bolt.fill",
        "star.fill", "heart.fill", "globe", "server.rack", "cpu", "book.fill",
    ]
}

struct Project: Identifiable, Codable, Hashable {
    var id = UUID()
    var name: String
    var path: String
    var color: FolderColor = .blue
    var collapsed = false
    /// nil only in state files written before workspaces existed; fixed on load.
    var workspaceID: UUID?
}

enum FolderColor: String, Codable, CaseIterable {
    case blue, purple, pink, red, orange, yellow, green, gray

    var color: Color {
        switch self {
        case .blue: .blue
        case .purple: .purple
        case .pink: .pink
        case .red: .red
        case .orange: .orange
        case .yellow: .yellow
        case .green: .green
        case .gray: .gray
        }
    }
}

struct Preset: Identifiable, Codable, Hashable {
    var id = UUID()
    var label: String
    /// Command run inside the user's login shell. Empty = plain shell.
    var command: String
    var symbol: String = "terminal"

    static let defaults: [Preset] = [
        Preset(label: "Shell", command: "", symbol: "terminal"),
        Preset(label: "Claude", command: "claude", symbol: "sparkles"),
        Preset(label: "Codex", command: "codex", symbol: "chevron.left.forwardslash.chevron.right"),
    ]
}

/// What the agent inside a session is doing, as reported by hooks or inferred from output.
enum SessionStatus: String, Codable {
    case starting
    case working       // agent busy / output flowing
    case idle          // agent finished its turn, waiting for a new prompt
    case needsInput    // agent asks for permission or input
    case exited

    var label: String {
        switch self {
        case .starting: "Starting"
        case .working: "Working"
        case .idle: "Ready"
        case .needsInput: "Needs input"
        case .exited: "Exited"
        }
    }

    var tint: Color {
        switch self {
        case .starting: .gray
        case .working: .blue
        case .idle: .green
        case .needsInput: .orange
        case .exited: .secondary
        }
    }
}

struct Session: Identifiable, Codable, Hashable {
    var id = UUID()
    var projectID: UUID
    var title: String
    var command: String
    var symbol: String
    var createdAt = Date()
    var archived = false
    var pinned = false
    var userTitled = false
    /// Runtime-only state, not persisted.
    var status: SessionStatus = .starting
    var unread = false
    var exitCode: Int32?

    enum CodingKeys: String, CodingKey {
        case id, projectID, title, command, symbol, createdAt, archived, pinned, userTitled
    }
}

/// Recursive split layout. A leaf shows one session (or nothing).
indirect enum PaneNode: Codable, Hashable, Identifiable {
    case leaf(id: UUID, sessionID: UUID?)
    case split(id: UUID, axis: SplitAxis, children: [PaneNode])

    var id: UUID {
        switch self {
        case .leaf(let id, _), .split(let id, _, _): id
        }
    }

    static func empty() -> PaneNode { .leaf(id: UUID(), sessionID: nil) }

    var leafIDs: [UUID] {
        switch self {
        case .leaf(let id, _): [id]
        case .split(_, _, let children): children.flatMap(\.leafIDs)
        }
    }

    var sessionIDs: [UUID] {
        switch self {
        case .leaf(_, let sid): sid.map { [$0] } ?? []
        case .split(_, _, let children): children.flatMap(\.sessionIDs)
        }
    }

    func sessionID(inLeaf leafID: UUID) -> UUID? {
        switch self {
        case .leaf(let id, let sid): id == leafID ? sid : nil
        case .split(_, _, let children): children.lazy.compactMap { $0.sessionID(inLeaf: leafID) }.first
        }
    }

    func leaf(showing sessionID: UUID) -> UUID? {
        switch self {
        case .leaf(let id, let sid): sid == sessionID ? id : nil
        case .split(_, _, let children): children.lazy.compactMap { $0.leaf(showing: sessionID) }.first
        }
    }

    /// Returns a copy with `transform` applied to the leaf with `leafID`.
    func mapLeaf(_ leafID: UUID, _ transform: (PaneNode) -> PaneNode) -> PaneNode {
        switch self {
        case .leaf(let id, _):
            return id == leafID ? transform(self) : self
        case .split(let id, let axis, let children):
            return .split(id: id, axis: axis, children: children.map { $0.mapLeaf(leafID, transform) })
        }
    }

    /// Clears `sessionID` from any leaf that shows it.
    func clearing(_ sessionID: UUID) -> PaneNode {
        switch self {
        case .leaf(let id, let sid):
            return sid == sessionID ? .leaf(id: id, sessionID: nil) : self
        case .split(let id, let axis, let children):
            return .split(id: id, axis: axis, children: children.map { $0.clearing(sessionID) })
        }
    }

    /// Removes a leaf; collapses splits left with one child. Returns nil if nothing remains.
    func removing(_ leafID: UUID) -> PaneNode? {
        switch self {
        case .leaf(let id, _):
            return id == leafID ? nil : self
        case .split(let id, let axis, let children):
            let kept = children.compactMap { $0.removing(leafID) }
            if kept.isEmpty { return nil }
            if kept.count == 1 { return kept[0] }
            return .split(id: id, axis: axis, children: kept)
        }
    }
}

enum SplitAxis: String, Codable {
    case horizontal  // side by side
    case vertical    // stacked
}

struct PersistedState: Codable {
    var projects: [Project] = []
    var sessions: [Session] = []
    var presets: [Preset] = Preset.defaults
    /// Layout before workspaces existed; migrated into the first workspace.
    var layout: PaneNode = .empty()
    var selectedSessionID: UUID?
    // Optional so older state files still decode.
    var workspaces: [Workspace]?
    var selectedWorkspaceID: UUID?
}
