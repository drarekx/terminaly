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
            PaneTreeView(node: store.layout)
                .background(Color(nsColor: NSColor(calibratedRed: 0.07, green: 0.07, blue: 0.09, alpha: 1)))
                .environment(\.colorScheme, .dark)  // terminal area is always dark
                .toolbar { toolbar }
        }
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
        ToolbarItemGroup(placement: .primaryAction) {
            Menu {
                ForEach(store.presets) { preset in
                    Button {
                        store.newSession(preset: preset)
                    } label: {
                        Label(preset.label, systemImage: preset.symbol)
                    }
                }
            } label: {
                Label("New Session", systemImage: "plus")
            } primaryAction: {
                if let p = store.presets.first { store.newSession(preset: p) }
            }
            .help("New session in \(store.currentProject?.name ?? "project")")

            Button { store.split(.horizontal) } label: {
                Label("Split Right", systemImage: "rectangle.split.2x1")
            }
            Button { store.split(.vertical) } label: {
                Label("Split Down", systemImage: "rectangle.split.1x2")
            }
            Button { store.showPalette = true } label: {
                Label("Command Palette", systemImage: "magnifyingglass")
            }
        }
    }
}
