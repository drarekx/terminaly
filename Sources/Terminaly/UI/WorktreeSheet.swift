import SwiftUI

/// "New Session in Worktree": branch name + preset, then `git worktree add`.
struct WorktreeSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let project: Project
    @State private var branch = ""
    @State private var presetID: UUID?
    @State private var error: String?
    @State private var working = false

    private var cleanBranch: String { Git.sanitizeBranch(branch) }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                Image(systemName: "arrow.triangle.branch")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(store.accent.color)
                Text("New Session in Worktree").font(Theme.Font.title)
            }
            Text("Runs the agent on its own branch and folder, so several agents can work on \(project.name) without stepping on each other.")
                .font(Theme.Font.body)
                .foregroundStyle(Theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 6) {
                Text("Branch").font(Theme.Font.label).foregroundStyle(Theme.secondaryText)
                TextField("feature/my-change", text: $branch)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 13, design: .monospaced))
                    .onSubmit(create)
                if !cleanBranch.isEmpty {
                    Text(Git.worktreePath(repo: project.path, branch: cleanBranch))
                        .font(Theme.Font.mono)
                        .foregroundStyle(Theme.tertiaryText)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            Picker("Preset", selection: $presetID) {
                ForEach(store.presets) { p in Text(p.label).tag(Optional(p.id)) }
            }

            if let error {
                Text(error)
                    .font(Theme.Font.caption)
                    .foregroundStyle(Color(hex: 0xFF6B6B))
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .buttonStyle(SecondaryButtonStyle())
                    .keyboardShortcut(.cancelAction)
                Button(action: create) {
                    if working { ProgressView().controlSize(.small) } else { Text("Create") }
                }
                .buttonStyle(PrimaryButtonStyle())
                .keyboardShortcut(.defaultAction)
                .disabled(cleanBranch.isEmpty || working)
            }
        }
        .padding(22)
        .frame(width: 460)
        .background(Theme.elevated)
        .preferredColorScheme(.dark)
        .environment(\.workspaceAccent, store.accent.color)
        .onAppear {
            presetID = presetID ?? store.presets.first?.id
            if branch.isEmpty { branch = "agent-\(Int.random(in: 100...999))" }
        }
    }

    private func create() {
        guard !cleanBranch.isEmpty, !working,
              let preset = store.presets.first(where: { $0.id == presetID }) ?? store.presets.first else { return }
        working = true
        error = nil
        Task {
            do {
                try await store.newWorktreeSession(preset: preset, in: project, branch: branch)
                dismiss()
            } catch {
                self.error = error.localizedDescription
            }
            working = false
        }
    }
}
