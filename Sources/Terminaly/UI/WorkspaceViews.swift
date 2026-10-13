import SwiftUI

/// Big workspace name at the top of its sidebar page. Double-click to rename.
struct WorkspaceTitle: View {
    @Environment(AppStore.self) private var store
    let workspace: Workspace
    @State private var draft = ""
    @FocusState private var focused: Bool

    private var renaming: Bool { store.renamingWorkspaceID == workspace.id }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: workspace.symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 26, height: 26)
                .background(RoundedRectangle(cornerRadius: 7).fill(workspace.color.color.gradient))
            if renaming {
                TextField("Workspace name", text: $draft)
                    .textFieldStyle(.plain)
                    .font(.system(size: 17, weight: .bold))
                    .focused($focused)
                    .onSubmit(commit)
                    .onExitCommand { store.renamingWorkspaceID = nil }
                    .onAppear {
                        draft = workspace.name
                        focused = true
                    }
                    .onChange(of: focused) { _, f in if !f { commit() } }
            } else {
                Text(workspace.name)
                    .font(.system(size: 17, weight: .bold))
                    .lineLimit(1)
                    .onTapGesture(count: 2) { store.renamingWorkspaceID = workspace.id }
            }
            Spacer(minLength: 4)
            Menu {
                WorkspaceMenu(workspace: workspace)
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .frame(height: 30)
        .contextMenu { WorkspaceMenu(workspace: workspace) }
    }

    private func commit() {
        guard renaming else { return }
        store.renameWorkspace(workspace.id, to: draft)
        store.renamingWorkspaceID = nil
    }
}

/// Bottom of the sidebar: add project · workspace icon dots · new workspace · settings.
struct SidebarFooter: View {
    @Environment(AppStore.self) private var store
    @Namespace private var selection

    var body: some View {
        HStack(spacing: 6) {
            Button { store.addProjectWithPanel() } label: {
                Image(systemName: "folder.badge.plus").font(.system(size: 13))
            }
            .buttonStyle(.borderless)
            .help("Add Project (⌘O)")

            Spacer(minLength: 2)
            ScrollView(.horizontal) {
                HStack(spacing: 4) {
                    ForEach(store.workspaces) { ws in
                        WorkspaceDot(workspace: ws, namespace: selection)
                    }
                }
                .padding(.horizontal, 4)
                .frame(minHeight: 34)
            }
            .scrollIndicators(.never)
            .fixedSize(horizontal: store.workspaces.count <= 6, vertical: false)
            Spacer(minLength: 2)

            Button { withAnimation(.smooth) { _ = store.addWorkspace() } } label: {
                Image(systemName: "plus").font(.system(size: 12, weight: .semibold))
            }
            .buttonStyle(.borderless)
            .help("New Workspace (⇧⌘N)")
            SettingsLink { Image(systemName: "gearshape").font(.system(size: 13)) }
                .buttonStyle(.borderless)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.ultraThinMaterial)
        .overlay(alignment: .top) { Divider().opacity(0.5) }
    }
}

/// One workspace in the footer: its icon in a circle. The selected one grows and fills with
/// its color; the highlight slides between dots.
private struct WorkspaceDot: View {
    @Environment(AppStore.self) private var store
    let workspace: Workspace
    let namespace: Namespace.ID
    @State private var hovering = false
    @State private var dropTarget = false

    private var selected: Bool { store.selectedWorkspaceID == workspace.id }
    private var attention: Int { store.attentionCount(in: workspace) }

    var body: some View {
        ZStack {
            if selected {
                Circle()
                    .fill(workspace.color.color.gradient)
                    .matchedGeometryEffect(id: "selected", in: namespace)
                    .shadow(color: workspace.color.color.opacity(0.5), radius: 4, y: 1)
            } else {
                Circle().fill(workspace.color.color.opacity(hovering || dropTarget ? 0.30 : 0.16))
            }
            Image(systemName: workspace.symbol)
                .font(.system(size: selected ? 12 : 10, weight: .semibold))
                .foregroundStyle(selected ? Color.white : workspace.color.color)
        }
        .frame(width: selected ? 28 : 22, height: selected ? 28 : 22)
        .overlay(alignment: .topTrailing) {
            if attention > 0 {
                Circle().fill(.orange)
                    .frame(width: 8, height: 8)
                    .overlay(Circle().stroke(.background, lineWidth: 1.5))
                    .offset(x: 1, y: -1)
            }
        }
        .overlay { if dropTarget { Circle().strokeBorder(workspace.color.color, lineWidth: 2).padding(-3) } }
        .scaleEffect(hovering && !selected ? 1.12 : 1)
        .frame(width: 30, height: 30)
        .contentShape(Circle())
        .animation(.spring(response: 0.32, dampingFraction: 0.72), value: selected)
        .animation(.snappy(duration: 0.15), value: hovering)
        .onHover { hovering = $0 }
        .onTapGesture(count: 2) {
            store.selectWorkspace(workspace.id)
            store.renamingWorkspaceID = workspace.id
        }
        .onTapGesture {
            withAnimation(.spring(response: 0.32, dampingFraction: 0.72)) { store.selectWorkspace(workspace.id) }
        }
        .dropDestination(for: String.self) { items, _ in
            let ids = items.compactMap { $0.hasPrefix("project:") ? UUID(uuidString: String($0.dropFirst(8))) : nil }
            for id in ids { store.moveProject(id, to: workspace.id) }
            return !ids.isEmpty
        } isTargeted: { dropTarget = $0 }
        .help(workspace.name + (attention > 0 ? " — \(attention) need input" : ""))
        .contextMenu { WorkspaceMenu(workspace: workspace) }
    }
}

/// Shared workspace actions (title menu, dot context menu).
struct WorkspaceMenu: View {
    @Environment(AppStore.self) private var store
    let workspace: Workspace

    var body: some View {
        Button("Rename…") {
            store.selectWorkspace(workspace.id)
            store.renamingWorkspaceID = workspace.id
        }
        Menu("Icon") {
            ForEach(Workspace.symbols, id: \.self) { symbol in
                Button { store.setWorkspaceStyle(workspace.id, symbol: symbol) } label: {
                    Label(symbol, systemImage: symbol)
                }
            }
        }
        Menu("Color") {
            ForEach(FolderColor.allCases, id: \.self) { c in
                Button(c.rawValue.capitalized) {
                    withAnimation(.smooth) { store.setWorkspaceStyle(workspace.id, color: c) }
                }
            }
        }
        Divider()
        Button("Move Left") { withAnimation(.smooth) { store.moveWorkspace(workspace.id, by: -1) } }
            .disabled(store.workspaces.first?.id == workspace.id)
        Button("Move Right") { withAnimation(.smooth) { store.moveWorkspace(workspace.id, by: 1) } }
            .disabled(store.workspaces.last?.id == workspace.id)
        Divider()
        Button("New Workspace") { withAnimation(.smooth) { _ = store.addWorkspace() } }
        Button("Delete Workspace", role: .destructive) { confirmDelete() }
            .disabled(store.workspaces.count <= 1)
    }

    private func confirmDelete() {
        let count = store.projects(in: workspace).count
        guard count > 0 else { return withAnimation(.smooth) { store.deleteWorkspace(workspace.id) } }
        let alert = NSAlert()
        alert.messageText = "Delete “\(workspace.name)”?"
        alert.informativeText = "Its \(count) project\(count == 1 ? "" : "s") will move to another workspace. Sessions keep running."
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn { withAnimation(.smooth) { store.deleteWorkspace(workspace.id) } }
    }
}
