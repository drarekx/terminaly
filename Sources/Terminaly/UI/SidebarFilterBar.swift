import SwiftUI

/// Compact search field + status filter at the top of a workspace page's session list.
struct SidebarFilterBar: View {
    @Environment(AppStore.self) private var store
    @Environment(\.workspaceAccent) private var accent
    let workspace: Workspace
    @Bindable private var state = SidebarFilterState.shared
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.tertiaryText)
            TextField("Filter sessions", text: $state.filter.query)
                .textFieldStyle(.plain)
                .font(Theme.Font.body)
                .focused($focused)
                .onExitCommand { state.clear() }
                .frame(maxWidth: .infinity)
            if !state.filter.query.isEmpty {
                Button { state.filter.query = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(IconButtonStyle(size: 20))
                .help("Clear search")
                .accessibilityLabel("Clear search")
            }
            PopoverMenuButton(width: 220) {
                Image(systemName: state.filter.status == .all
                      ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill")
                    .foregroundStyle(state.filter.status == .all ? Theme.text.opacity(0.8) : accent)
            } content: {
                MenuSectionLabel(title: "Show")
                ForEach(SessionFilter.Status.allCases, id: \.self) { status in
                    MenuRow(title: status.title, checked: state.filter.status == status) {
                        state.filter.status = status
                    }
                }
            }
            .buttonStyle(IconButtonStyle(size: 22))
            .help("Filter by status")
            .accessibilityLabel("Filter by status")
            .accessibilityValue(Text(state.filter.status.title))
        }
        .padding(.leading, 8)
        .padding(.trailing, 3)
        .frame(height: 28)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.06)))
        .overlay(RoundedRectangle(cornerRadius: 8)
            .strokeBorder(focused ? Theme.ring(workspace.color) : Color.white.opacity(0.10), lineWidth: 1))
        .onChange(of: state.focusRequests) { _, _ in
            if workspace.id == store.selectedWorkspaceID { focused = true }
        }
        .onAppear {
            // AppKit makes the window's first text field the first responder when it opens; the
            // keyboard belongs to the terminal unless the user asks for the filter.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                guard focused, state.focusRequests == 0, state.filter.query.isEmpty else { return }
                focused = false
                if let id = store.selectedSessionID { store.terminals.focus(id) }
            }
        }
    }
}

/// Shown instead of the project list when the filter leaves nothing.
struct SidebarNoMatches: View {
    var body: some View {
        VStack(spacing: 8) {
            Text("No sessions match")
                .font(Theme.Font.body)
                .foregroundStyle(Theme.secondaryText)
            Button("Clear") { SidebarFilterState.shared.clear() }
                .buttonStyle(SecondaryButtonStyle(compact: true))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
    }
}

extension SessionFilter.Status {
    /// Same words as the session rows' status line.
    var title: LocalizedStringKey {
        switch self {
        case .all: "All"
        case .needsInput: "Needs input"
        case .working: "Working"
        case .idle: "Ready"
        }
    }
}
