import AppKit
import SwiftUI

extension AppStore {
    /// "Show Changes" is offered for sessions whose folder is a git checkout.
    func canShowChanges(_ s: Session) -> Bool {
        s.worktreePath != nil || gitProjects.contains(s.projectID)
    }
}

/// "Show Changes": files the agent changed in its folder and, on a branch, its commits not yet in
/// the main checkout's branch. For reviewing a worker before merging it.
struct ChangesView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let session: Session
    /// Snapshot mode passes made-up changes instead of running git.
    var preview: GitChanges? = nil
    @State private var changes: GitChanges?
    @State private var error: String?
    @State private var loading = false

    private var directory: String? { store.workingDirectory(for: session) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            Divider().overlay(Theme.hairline)
            content
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .frame(height: 380)
            HStack {
                Button {
                    if let directory { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: directory)]) }
                } label: {
                    Label("Reveal in Finder", systemImage: "folder")
                }
                .buttonStyle(SecondaryButtonStyle(compact: true))
                Spacer()
                Button("Close") { dismiss() }
                    .buttonStyle(PrimaryButtonStyle())
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(width: 560)
        .background(Theme.elevated)
        .preferredColorScheme(.dark)
        .environment(\.workspaceAccent, store.accent.color)
        .onAppear {
            if let preview { changes = preview } else { load() }
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "plusminus")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(store.accent.color)
            VStack(alignment: .leading, spacing: 3) {
                Text("Changes in “\(session.title)”").font(Theme.Font.title).lineLimit(1)
                if let directory {
                    Text(directory)
                        .font(Theme.Font.mono)
                        .foregroundStyle(Theme.tertiaryText)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer()
            Button(action: load) { Image(systemName: "arrow.clockwise") }
                .buttonStyle(IconButtonStyle(size: 28))
                .help("Refresh")
                .accessibilityLabel("Refresh")
                .disabled(loading || preview != nil)
        }
    }

    @ViewBuilder
    private var content: some View {
        if let error {
            VStack(alignment: .leading, spacing: 6) {
                Text("Could not read the changes").font(Theme.Font.bodyStrong)
                Text(error)
                    .font(Theme.Font.mono)
                    .foregroundStyle(Theme.removed)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } else if let changes {
            if changes.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "checkmark.circle")
                        .font(.system(size: 22))
                        .foregroundStyle(Theme.tertiaryText)
                    Text("No changes").font(Theme.Font.bodyMedium)
                    Text("The folder matches its last commit.")
                        .font(Theme.Font.caption)
                        .foregroundStyle(Theme.tertiaryText)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        if !changes.files.isEmpty { filesSection(changes.files) }
                        if let branch = changes.branch, let base = changes.base, !changes.commits.isEmpty {
                            commitsSection(changes, branch: branch, base: base)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        } else {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Reading changes…").font(Theme.Font.body).foregroundStyle(Theme.secondaryText)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func filesSection(_ files: [GitChanges.File]) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            sectionLabel("Uncommitted (\(files.count))")
            ForEach(files) { file in
                ChangedFileRow(file: file) { open(file) }
            }
        }
    }

    private func commitsSection(_ changes: GitChanges, branch: String, base: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                sectionLabel("Commits on \(branch) not in \(base) (\(changes.commits.count))")
                Spacer()
                if let stat = changes.branchStat {
                    Text("\(stat.files) files").font(Theme.Font.caption).foregroundStyle(Theme.tertiaryText)
                    LineCounts(added: stat.insertions, removed: stat.deletions)
                }
            }
            ForEach(changes.commits) { commit in
                HStack(spacing: 10) {
                    Text(commit.sha).font(Theme.Font.mono).foregroundStyle(Theme.tertiaryText)
                    Text(commit.subject).font(Theme.Font.body).lineLimit(1).truncationMode(.tail)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
            }
        }
    }

    private func sectionLabel(_ text: LocalizedStringKey) -> some View {
        Text(text).font(Theme.Font.label).foregroundStyle(Theme.secondaryText).lineLimit(1)
    }

    private func open(_ file: GitChanges.File) {
        guard let directory, !file.isDeleted else { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: directory).appendingPathComponent(file.path))
    }

    private func load() {
        guard preview == nil else { return }
        guard let directory else {
            error = String(localized: "The session has no folder.")
            return
        }
        loading = true
        let branch = session.branch, isWorktree = session.worktreePath != nil
        Task.detached {
            let result = Result { try GitChanges.load(directory: directory, branch: branch, isWorktree: isWorktree) }
            await MainActor.run {
                loading = false
                switch result {
                case .success(let found): changes = found; error = nil
                case .failure(let failure): error = failure.localizedDescription
                }
            }
        }
    }
}

private struct ChangedFileRow: View {
    let file: GitChanges.File
    let open: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: open) {
            HStack(spacing: 10) {
                Text(file.status)
                    .font(Theme.Font.mono.weight(.semibold))
                    .foregroundStyle(statusColor)
                    .frame(width: 14)
                VStack(alignment: .leading, spacing: 1) {
                    Text(file.path)
                        .font(Theme.Font.mono)
                        .foregroundStyle(file.isDeleted ? Theme.secondaryText : Theme.text)
                        .strikethrough(file.isDeleted)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if let old = file.oldPath {
                        Text("from \(old)")
                            .font(Theme.Font.caption)
                            .foregroundStyle(Theme.tertiaryText)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                Spacer(minLength: 8)
                if file.added != nil || file.removed != nil {
                    LineCounts(added: file.added ?? 0, removed: file.removed ?? 0)
                } else if file.status != "D" {
                    Text("binary").font(Theme.Font.caption).foregroundStyle(Theme.tertiaryText)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(hovering && !file.isDeleted ? 0.07 : 0)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(file.isDeleted)
        .onHover { hovering = $0 }
        .help(file.isDeleted ? Text("Deleted") : Text("Open \(file.path)"))
    }

    private var statusColor: Color {
        switch file.status {
        case "A", "?": Theme.added
        case "D": Theme.removed
        default: Theme.secondaryText
        }
    }
}

private struct LineCounts: View {
    let added: Int
    let removed: Int

    var body: some View {
        HStack(spacing: 6) {
            Text(verbatim: "+\(added)").foregroundStyle(Theme.added)
            Text(verbatim: "−\(removed)").foregroundStyle(Theme.removed)
        }
        .font(Theme.Font.mono)
        .monospacedDigit()
    }
}
