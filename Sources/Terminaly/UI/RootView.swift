import SwiftUI

struct RootView: View {
    @Environment(AppStore.self) private var store
    @State private var renameText = ""

    var body: some View {
        @Bindable var store = store
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 200, ideal: 250, max: 380)
        } detail: {
            Group {
                if let zoomed = store.zoomedLeafID, store.layout.leafIDs.contains(zoomed) {
                    PaneView(leafID: zoomed, sessionID: store.layout.sessionID(inLeaf: zoomed))
                        .transition(.opacity.combined(with: .scale(scale: 0.98)))
                } else {
                    PaneTreeView(node: store.layout)
                }
            }
            .animation(.smooth(duration: 0.22), value: store.zoomedLeafID)
            .padding(6)
                .background(Theme.ground)
                .toolbar { toolbar }
        }
        .preferredColorScheme(.dark)
        .tint(store.accent.color)
        .environment(\.workspaceAccent, store.accent.color)
        .overlay {
            if store.showPalette {
                CommandPaletteView()
            }
        }
        .alert("Rename Session", isPresented: Binding(
            get: { store.renamingSessionID != nil },
            set: { if !$0 { store.renamingSessionID = nil } }
        )) {
            TextField("Title", text: $renameText)
            Button("Rename") {
                if let id = store.renamingSessionID { store.rename(id, to: renameText) }
            }
            Button("Cancel", role: .cancel) {}
        }
        .onChange(of: store.renamingSessionID) { _, id in
            renameText = store.session(id)?.title ?? ""
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            HStack(spacing: 4) {
                Text(store.currentWorkspace?.name ?? "")
                if let p = store.currentProject {
                    Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold))
                    Text(p.name)
                }
            }
            .font(Theme.Font.label)
            .foregroundStyle(Theme.secondaryText)
            .padding(.horizontal, 6)
        }
        ToolbarItemGroup(placement: .primaryAction) {
            HStack(spacing: 2) {
                Button {
                    if let p = store.presets.first { store.newSession(preset: p) }
                } label: {
                    Label("New Session", systemImage: "plus").labelStyle(.titleAndIcon)
                }
                .buttonStyle(PrimaryButtonStyle(compact: true))
                .environment(\.workspaceAccent, store.accent.color)
                .help("New \(store.presets.first?.label ?? "") in \(store.currentProject?.name ?? "") (⌘T)")
                PopoverMenuButton(width: 280, accent: store.accent.color) {
                    Image(systemName: "chevron.down")
                } content: {
                    MenuSectionLabel(title: "New session in \(store.currentProject?.name ?? "project")")
                    ForEach(Array(store.presets.enumerated()), id: \.element.id) { i, preset in
                        MenuRow(title: "\(preset.label)", icon: preset.symbol,
                                subtitle: preset.command.isEmpty ? String(localized: "login shell") : preset.command,
                                shortcut: i == 0 ? "⌘T" : nil) {
                            store.newSession(preset: preset)
                        }
                    }
                }
                .buttonStyle(IconButtonStyle(size: 28))
                .help("Choose preset")
            }

            Button { store.split(.horizontal) } label: { Image(systemName: "rectangle.split.2x1") }
                .buttonStyle(IconButtonStyle())
                .help("Split Right (⌘D)")
                .accessibilityLabel("Split Right")
            Button { store.split(.vertical) } label: { Image(systemName: "rectangle.split.1x2") }
                .buttonStyle(IconButtonStyle())
                .help("Split Down (⇧⌘D)")
                .accessibilityLabel("Split Down")
            Button { store.showPalette = true } label: {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                    Text("Search")
                    Text("⌘K").foregroundStyle(Theme.tertiaryText)
                }
                .fixedSize()
            }
            .buttonStyle(SecondaryButtonStyle(compact: true))
            .help("Command Palette (⌘K)")
        }
    }
}
