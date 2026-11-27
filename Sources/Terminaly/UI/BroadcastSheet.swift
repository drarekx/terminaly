import SwiftUI

/// Send to Sessions…: one prompt to several running sessions of the workspace, picked by
/// checkbox or with `@name` in the text.
struct BroadcastSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var checked: Set<UUID> = []
    /// Until the person ticks a box, mentions replace the default pick (the selected session).
    @State private var touched = false
    @State private var lastMatched: Set<UUID> = []
    /// After sending, the sessions that were skipped (permission dialog showing).
    @State private var skipped: [String]?
    @State private var sentCount = 0
    @FocusState private var editorFocused: Bool

    private struct Row: Identifiable {
        let session: Session
        let indented: Bool
        var id: UUID { session.id }
    }

    /// Live sessions of the workspace in sidebar order, collapsed workers included.
    private var groups: [(project: Project, rows: [Row])] {
        store.visibleProjects.compactMap { project in
            let rows = store.sidebarGroups(in: project).flatMap { group -> [Row] in
                let lead = isLive(group.session)
                let workers = group.workers.filter(isLive).map { Row(session: $0, indented: lead) }
                return (lead ? [Row(session: group.session, indented: false)] : []) + workers
            }
            return rows.isEmpty ? nil : (project, rows)
        }
    }

    private func isLive(_ s: Session) -> Bool {
        BroadcastState.shared.previewStoppedSessions || store.canReceiveBroadcast(s)
    }

    var body: some View {
        let groups = groups
        let listed = groups.flatMap { $0.rows.map(\.session) }
        let parsed = BroadcastParser.parse(text: text, sessions: listed.map { ($0.id, $0.title) })
        let targets = listed.filter { checked.contains($0.id) }
        let receiving = targets.filter { !$0.permissionPending }.count

        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                Image(systemName: "paperplane")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(store.accent.color)
                Text("Send to Sessions").font(Theme.Font.title)
            }

            VStack(alignment: .leading, spacing: 6) {
                TextEditor(text: $text)
                    .font(Theme.Font.body)
                    .scrollContentBackground(.hidden)
                    .focused($editorFocused)
                    .padding(8)
                    .frame(height: 120)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.05)))
                    .overlay(RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(editorFocused ? store.accent.color.opacity(0.7) : Theme.hairline, lineWidth: 1))
                Text("Type @name to pick sessions; mentions are left out of the message.")
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.tertiaryText)
            }

            if listed.isEmpty {
                Text("No running sessions in this workspace.")
                    .font(Theme.Font.body)
                    .foregroundStyle(Theme.secondaryText)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(groups, id: \.project.id) { group in
                            MenuSectionLabel(title: "\(group.project.name)")
                            ForEach(group.rows) { row in rowView(row) }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 260)
                .fixedSize(horizontal: false, vertical: true)
            }

            if let skipped {
                Text("Sent to \(sentCount). Skipped, waiting for permission: \(skipped.joined(separator: ", "))")
                    .font(Theme.Font.caption)
                    .foregroundStyle(SessionStatus.needsInput.text)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                if skipped != nil {
                    Button("Done") { dismiss() }
                        .buttonStyle(PrimaryButtonStyle())
                        .keyboardShortcut(.defaultAction)
                } else {
                    Button("Cancel") { dismiss() }
                        .buttonStyle(SecondaryButtonStyle())
                        .keyboardShortcut(.cancelAction)
                    Button { send(parsed.cleanText, targets) } label: {
                        Text("Send to \(receiving)")
                    }
                    .buttonStyle(PrimaryButtonStyle())
                    .keyboardShortcut(.return, modifiers: .command)
                    .help("Send (⌘↩)")
                    .disabled(parsed.cleanText.isEmpty || receiving == 0)
                }
            }
        }
        .padding(22)
        .frame(width: 520)
        .background(Theme.elevated)
        .preferredColorScheme(.dark)
        .tint(store.accent.color)
        .environment(\.workspaceAccent, store.accent.color)
        .onAppear {
            if let id = store.selectedSessionID, listed.contains(where: { $0.id == id }) { checked = [id] }
            if text.isEmpty { text = BroadcastState.shared.previewText }
            editorFocused = true
        }
        .onChange(of: parsed.matchedIDs) { _, matched in
            if !touched {
                let selected = store.selectedSessionID.flatMap { id in listed.contains { $0.id == id } ? id : nil }
                checked = matched.isEmpty ? Set([selected].compactMap { $0 }) : matched
            } else {
                checked.formUnion(matched.subtracting(lastMatched))
            }
            lastMatched = matched
        }
    }

    private func rowView(_ row: Row) -> some View {
        let s = row.session
        return Toggle(isOn: Binding(
            get: { checked.contains(s.id) },
            set: { on in
                touched = true
                if on { checked.insert(s.id) } else { checked.remove(s.id) }
            }
        )) {
            HStack(spacing: 8) {
                Circle().fill(s.status.dot).frame(width: 7, height: 7)
                Text(s.title)
                    .font(Theme.Font.body)
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if s.permissionPending {
                    Text("Waiting for permission: skipped")
                        .font(Theme.Font.caption)
                        .foregroundStyle(SessionStatus.needsInput.text)
                } else if s.status == .working || s.status == .starting {
                    Text("Busy: gets it after its turn")
                        .font(Theme.Font.caption)
                        .foregroundStyle(Theme.tertiaryText)
                }
                Spacer(minLength: 0)
            }
        }
        .toggleStyle(.checkbox)
        .padding(.horizontal, 10)
        .padding(.leading, row.indented ? 20 : 0)
        .padding(.vertical, 3)
    }

    private func send(_ message: String, _ targets: [Session]) {
        guard !message.isEmpty else { return }
        let result = store.broadcast(message, to: targets.map(\.id))
        guard !result.skipped.isEmpty else { return dismiss() }
        sentCount = result.sent.count
        skipped = result.skipped.compactMap { store.session($0)?.title }
    }
}
