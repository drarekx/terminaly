import SwiftUI

/// Footer line with the live session count, total memory and CPU; opens `ResourcesPopover`.
struct ResourcesButton: View {
    @Environment(AppStore.self) private var store
    @Environment(\.workspaceAccent) private var accent
    @State private var open = false

    private var live: [Session] { store.sessions.filter { !$0.archived && $0.status != .exited } }

    var body: some View {
        let monitor = store.resources
        Button { open.toggle() } label: {
            Hover { hovering in
                HStack(spacing: 6) {
                    Image(systemName: "memorychip").font(.system(size: 12, weight: .semibold))
                    Text(verbatim: summary(monitor))
                        .monospacedDigit()
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
                .font(Theme.Font.caption)
                .foregroundStyle(hovering ? Theme.text : Theme.secondaryText)
                .padding(.horizontal, 8)
                .frame(height: 26)
                .background(RoundedRectangle(cornerRadius: 7).fill(Color.white.opacity(hovering ? 0.08 : 0)))
                .contentShape(RoundedRectangle(cornerRadius: 7))
            }
        }
        .buttonStyle(.plain)
        .help("Sessions and resource usage")
        .accessibilityLabel("Sessions and resource usage")
        .task { await monitor.run(every: .seconds(10)) }
        .popover(isPresented: $open, arrowEdge: .top) {
            ResourcesPopover()
                .environment(store)
                .environment(\.workspaceAccent, accent)
        }
    }
}

extension ResourcesButton {
    private func summary(_ monitor: ResourceMonitor) -> String {
        let n = live.count
        let sessions = n == 1 ? String(localized: "1 session") : String(localized: "\(n) sessions")
        return "\(sessions) · \(ResourceMonitor.format(memory: monitor.totalMemory)) · CPU \(ResourceMonitor.format(cpu: monitor.totalCPU))"
    }
}

/// Memory and CPU per running session, plus the app and the session host. Pause/continue per row.
struct ResourcesPopover: View {
    @Environment(AppStore.self) private var store

    private var live: [Session] {
        let monitor = store.resources
        return store.sessions
            .filter { !$0.archived && $0.status != .exited }
            .sorted { (monitor.sessions[$0.id]?.memory ?? 0) > (monitor.sessions[$1.id]?.memory ?? 0) }
    }

    var body: some View {
        let monitor = store.resources
        let sessions = live
        let paused = sessions.filter { $0.status == .paused }.count
        let idle = sessions.filter { $0.status == .idle }
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("Resources").font(Theme.Font.title).foregroundStyle(Theme.text)
                Spacer()
                Text("\(sessions.count) running · \(paused) paused")
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.secondaryText)
            }
            HStack(spacing: 8) {
                SummaryTile(title: "Memory", value: ResourceMonitor.format(memory: monitor.totalMemory))
                SummaryTile(title: "CPU", value: ResourceMonitor.format(cpu: monitor.totalCPU))
            }

            VStack(spacing: 1) {
                if sessions.isEmpty {
                    Text("No running sessions")
                        .font(Theme.Font.body)
                        .foregroundStyle(Theme.tertiaryText)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 8)
                }
                ForEach(sessions) { s in
                    SessionUsageRow(session: s, sample: monitor.sessions[s.id])
                }
                Divider().padding(.vertical, 4)
                UsageRow(icon: "macwindow", title: Text(verbatim: "Terminaly"), subtitle: nil, sample: monitor.app)
                UsageRow(icon: "server.rack", title: Text("Session host (tly)"), subtitle: nil, sample: monitor.host)
            }

            Text("Pausing stops all CPU use and keeps the session as it is; its memory stays allocated. To free memory, stop the session: Claude conversations can be resumed later.")
                .font(Theme.Font.caption)
                .foregroundStyle(Theme.tertiaryText)
                .fixedSize(horizontal: false, vertical: true)

            if !idle.isEmpty {
                Button("Pause Idle Sessions (\(idle.count))") {
                    for s in idle { store.pause(s.id) }
                }
                .buttonStyle(SecondaryButtonStyle(compact: true))
            }
        }
        .padding(14)
        .frame(width: 380)
        .preferredColorScheme(.dark)
        .task { await monitor.run(every: .seconds(2)) }
    }
}

private struct SummaryTile: View {
    let title: LocalizedStringKey
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(Theme.Font.caption).foregroundStyle(Theme.secondaryText)
            Text(verbatim: value).font(Theme.Font.title).monospacedDigit().foregroundStyle(Theme.text)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.05)))
    }
}

private struct SessionUsageRow: View {
    @Environment(AppStore.self) private var store
    let session: Session
    let sample: ResourceMonitor.Sample?

    var body: some View {
        HStack(spacing: 8) {
            UsageRow(icon: session.symbol, title: Text(verbatim: session.title),
                     subtitle: store.project(session.projectID)?.name, sample: sample, status: session.status)
            Button {
                if session.status == .paused { store.unpause(session.id) } else { store.pause(session.id) }
            } label: {
                Image(systemName: session.status == .paused ? "play.fill" : "pause.fill")
            }
            .buttonStyle(IconButtonStyle(size: 26))
            .help(session.status == .paused ? LocalizedStringKey("Continue") : LocalizedStringKey("Pause"))
            .accessibilityLabel(session.status == .paused ? LocalizedStringKey("Continue") : LocalizedStringKey("Pause"))
        }
        .contentShape(Rectangle())
        .onTapGesture { store.show(session.id) }
    }
}

private struct UsageRow: View {
    let icon: String
    let title: Text
    let subtitle: String?
    let sample: ResourceMonitor.Sample?
    var status: SessionStatus? = nil

    var body: some View {
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 6)
                .fill(status?.tile ?? Color.white.opacity(0.06))
                .frame(width: 24, height: 24)
                .overlay {
                    Image(systemName: icon)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(status?.dot ?? Theme.secondaryText)
                }
            VStack(alignment: .leading, spacing: 0) {
                title.font(Theme.Font.body).foregroundStyle(Theme.text).lineLimit(1)
                if let subtitle {
                    Text(verbatim: subtitle).font(Theme.Font.caption).foregroundStyle(Theme.tertiaryText).lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            Text(verbatim: sample.map { ResourceMonitor.format(memory: $0.memory) } ?? "–")
                .frame(width: 70, alignment: .trailing)
            Text(verbatim: ResourceMonitor.format(cpu: status == .paused ? 0 : sample?.cpu))
                .frame(width: 44, alignment: .trailing)
        }
        .font(Theme.Font.mono)
        .foregroundStyle(Theme.secondaryText)
        .padding(.vertical, 4)
    }
}
