import SwiftUI

/// Horizontal strip of workspace pills at the top of the sidebar.
/// Click to switch, double-click to rename, drop a project on a pill to move it there.
struct WorkspaceBar: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        HStack(spacing: 6) {
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(store.workspaces) { ws in
                            WorkspacePill(workspace: ws).id(ws.id)
                        }
                    }
                    .padding(.horizontal, 2)
                    .padding(.vertical, 4)
                }
                .onChange(of: store.selectedWorkspaceID) { _, id in
                    withAnimation(.snappy) { proxy.scrollTo(id, anchor: .center) }
                }
            }
            Button { store.addWorkspace() } label: {
                Image(systemName: "plus")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 24, height: 24)
                    .background(Circle().fill(.quaternary))
            }
            .buttonStyle(.plain)
            .help("New Workspace (⇧⌘N)")
        }
        .padding(.horizontal, 10)
        .padding(.top, 6)
    }
}

private struct WorkspacePill: View {
    @Environment(AppStore.self) private var store
    let workspace: Workspace
    @State private var draft = ""
    @State private var isDropTarget = false
    @State private var hovering = false
    @FocusState private var fieldFocused: Bool

    private var selected: Bool { store.selectedWorkspaceID == workspace.id }
    private var renaming: Bool { store.renamingWorkspaceID == workspace.id }
    private var attention: Int { store.attentionCount(in: workspace) }

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: workspace.symbol)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(selected ? .white : workspace.color.color)
            if renaming {
                TextField("Name", text: $draft)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: max(60, CGFloat(draft.count) * 7.5))
                    .focused($fieldFocused)
                    .onSubmit(commit)
                    .onExitCommand { store.renamingWorkspaceID = nil }
                    .onAppear {
                        draft = workspace.name
                        fieldFocused = true
                    }
                    .onChange(of: fieldFocused) { _, focused in if !focused { commit() } }
            } else {
                Text(workspace.name)
                    .font(.system(size: 12, weight: selected ? .semibold : .medium))
                    .lineLimit(1)
            }
            if attention > 0 {
                Text("\(attention)")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 4)
                    .frame(minWidth: 15, minHeight: 15)
                    .background(Capsule().fill(.orange))
                    .help("\(attention) session\(attention == 1 ? "" : "s") need input")
            }
        }
        .foregroundStyle(selected ? .white : .primary)
        .padding(.horizontal, 10)
        .frame(height: 26)
        .background(
            Capsule().fill(selected ? AnyShapeStyle(workspace.color.color.gradient)
                                    : AnyShapeStyle(Color.primary.opacity(hovering ? 0.10 : 0.05)))
        )
        .overlay(
            Capsule().strokeBorder(isDropTarget ? workspace.color.color : .clear, lineWidth: 2)
        )
        .scaleEffect(isDropTarget ? 1.08 : 1)
        .animation(.snappy(duration: 0.2), value: isDropTarget)
        .animation(.snappy(duration: 0.2), value: selected)
        .contentShape(Capsule())
        .onHover { hovering = $0 }
        .onTapGesture(count: 2) { store.renamingWorkspaceID = workspace.id }
        .onTapGesture { withAnimation(.snappy) { store.selectWorkspace(workspace.id) } }
        .dropDestination(for: String.self) { items, _ in
            let ids = items.compactMap { $0.hasPrefix("project:") ? UUID(uuidString: String($0.dropFirst(8))) : nil }
            for id in ids { store.moveProject(id, to: workspace.id) }
            return !ids.isEmpty
        } isTargeted: { isDropTarget = $0 }
        .help("\(workspace.name) — \(store.projects(in: workspace).count) projects")
        .contextMenu { menu }
    }

    private func commit() {
        guard renaming else { return }
        store.renameWorkspace(workspace.id, to: draft)
        store.renamingWorkspaceID = nil
    }

    @ViewBuilder
    private var menu: some View {
        Button("Rename…") { store.renamingWorkspaceID = workspace.id }
        Menu("Icon") {
            ForEach(Workspace.symbols, id: \.self) { symbol in
                Button { store.setWorkspaceStyle(workspace.id, symbol: symbol) } label: {
                    Label(symbol, systemImage: symbol)
                }
            }
        }
        Menu("Color") {
            ForEach(FolderColor.allCases, id: \.self) { c in
                Button(c.rawValue.capitalized) { store.setWorkspaceStyle(workspace.id, color: c) }
            }
        }
        Divider()
        Button("Move Left") { store.moveWorkspace(workspace.id, by: -1) }
            .disabled(store.workspaces.first?.id == workspace.id)
        Button("Move Right") { store.moveWorkspace(workspace.id, by: 1) }
            .disabled(store.workspaces.last?.id == workspace.id)
        Divider()
        Button("Delete Workspace", role: .destructive) { confirmDelete() }
            .disabled(store.workspaces.count <= 1)
    }

    private func confirmDelete() {
        let count = store.projects(in: workspace).count
        guard count > 0 else { return store.deleteWorkspace(workspace.id) }
        let alert = NSAlert()
        alert.messageText = "Delete “\(workspace.name)”?"
        alert.informativeText = "Its \(count) project\(count == 1 ? "" : "s") will move to another workspace. Sessions keep running."
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn { store.deleteWorkspace(workspace.id) }
    }
}
