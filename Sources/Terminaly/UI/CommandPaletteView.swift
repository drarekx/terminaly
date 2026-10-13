import SwiftUI

struct CommandPaletteView: View {
    @Environment(AppStore.self) private var store
    @State private var query = ""
    @State private var index = 0
    @FocusState private var focused: Bool

    private struct Item: Identifiable {
        let id: String
        let title: String
        let subtitle: String
        let symbol: String
        var status: SessionStatus? = nil
        let action: () -> Void
    }

    private var items: [Item] {
        var all: [Item] = []
        for ws in store.workspaces where ws.id != store.selectedWorkspaceID {
            all.append(Item(id: "w\(ws.id)", title: "Go to \(ws.name)", subtitle: "Workspace",
                            symbol: ws.symbol) { store.selectWorkspace(ws.id) })
        }
        for s in store.sessions where !s.archived {
            let project = store.project(s.projectID)?.name ?? ""
            let ws = store.workspace(of: s.id).map { "\($0.name) › " } ?? ""
            all.append(Item(id: "s\(s.id)", title: s.title, subtitle: "\(ws)\(project)",
                            symbol: s.symbol, status: s.status) { store.show(s.id) })
        }
        for p in store.visibleProjects {
            for preset in store.presets {
                all.append(Item(id: "n\(p.id)\(preset.id)", title: "New \(preset.label)", subtitle: p.name,
                                symbol: "plus") { store.newSession(preset: preset, in: p) })
            }
        }
        all.append(Item(id: "split-h", title: "Split Right", subtitle: "Pane", symbol: "rectangle.split.2x1") { store.split(.horizontal) })
        all.append(Item(id: "split-v", title: "Split Down", subtitle: "Pane", symbol: "rectangle.split.1x2") { store.split(.vertical) })
        all.append(Item(id: "new-ws", title: "New Workspace", subtitle: "Workspace", symbol: "plus.rectangle.on.rectangle") { store.addWorkspace() })
        all.append(Item(id: "add", title: "Add Project…", subtitle: "Project", symbol: "folder.badge.plus") { store.addProjectWithPanel() })
        for s in store.archivedSessions {
            all.append(Item(id: "a\(s.id)", title: "Restore \(s.title)", subtitle: "Archived",
                            symbol: "archivebox") { store.show(s.id) })
        }

        let q = query.lowercased().split(separator: " ")
        guard !q.isEmpty else { return all }
        return all.filter { item in
            let hay = (item.title + " " + item.subtitle).lowercased()
            return q.allSatisfy { hay.contains($0) }
        }
    }

    var body: some View {
        let results = items
        ZStack(alignment: .top) {
            Color.black.opacity(0.35)
                .ignoresSafeArea()
                .onTapGesture { close() }
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Theme.text.opacity(0.6))
                    TextField("Search sessions, presets, actions…", text: $query)
                        .textFieldStyle(.plain)
                        .font(.system(size: 15))
                        .focused($focused)
                        .onSubmit { run(results) }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
                Rectangle().fill(Theme.hairline).frame(height: 1)
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(Array(results.enumerated()), id: \.element.id) { i, item in
                                HStack(spacing: 10) {
                                    if let status = item.status {
                                        Circle().fill(status.dot).frame(width: 8, height: 8).frame(width: 18)
                                    } else {
                                        Image(systemName: item.symbol)
                                            .font(.system(size: 12, weight: .semibold))
                                            .foregroundStyle(Theme.text.opacity(0.6))
                                            .frame(width: 18)
                                    }
                                    Text(item.title)
                                        .font(.system(size: 13, weight: i == index ? .semibold : .regular))
                                    Spacer()
                                    Text(item.subtitle)
                                        .font(.system(size: 11))
                                        .foregroundStyle(Theme.text.opacity(0.6))
                                }
                                .padding(.horizontal, 10)
                                .padding(.vertical, 9)
                                .background(RoundedRectangle(cornerRadius: 8)
                                    .fill(i == index ? store.accent.color.opacity(0.22) : .clear))
                                .contentShape(Rectangle())
                                .onTapGesture { index = i; run(results) }
                                .id(i)
                            }
                        }
                    }
                    .padding(6)
                    .frame(maxHeight: 340)
                    .onChange(of: index) { _, i in proxy.scrollTo(i) }
                }
            }
            .frame(width: 580)
            .background(RoundedRectangle(cornerRadius: 14).fill(Theme.elevated))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.white.opacity(0.10), lineWidth: 1))
            .shadow(color: .black.opacity(0.5), radius: 30, y: 18)
            .padding(.top, 80)
        }
        .onAppear { focused = true }
        .onChange(of: query) { _, _ in index = 0 }
        .onKeyPress(.downArrow) { index = min(index + 1, max(results.count - 1, 0)); return .handled }
        .onKeyPress(.upArrow) { index = max(index - 1, 0); return .handled }
        .onKeyPress(.escape) { close(); return .handled }
    }

    private func run(_ results: [Item]) {
        guard results.indices.contains(index) else { return }
        let action = results[index].action
        close()
        action()
    }

    private func close() {
        store.showPalette = false
        if let id = store.selectedSessionID { store.terminals.focus(id) }
    }
}
