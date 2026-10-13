import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            PresetsSettings().tabItem { Label("Presets", systemImage: "list.bullet") }
            IntegrationsSettings().tabItem { Label("Agents", systemImage: "sparkles") }
            TerminalSettings().tabItem { Label("Terminal", systemImage: "terminal") }
            UpdatesSettings().tabItem { Label("Updates", systemImage: "arrow.down.circle") }
        }
        .frame(width: 560, height: 380)
    }
}

private struct PresetsSettings: View {
    @Environment(AppStore.self) private var store
    @State private var selection: UUID?

    var body: some View {
        @Bindable var store = store
        VStack(alignment: .leading) {
            Table($store.presets, selection: $selection) {
                TableColumn("Label") { $p in TextField("", text: $p.label) }
                    .width(110)
                TableColumn("Command") { $p in
                    TextField("(login shell)", text: $p.command).font(.system(.body, design: .monospaced))
                }
                TableColumn("Symbol") { $p in TextField("", text: $p.symbol) }
                    .width(110)
            }
            HStack {
                Button { store.presets.append(Preset(label: "New", command: "")) } label: { Image(systemName: "plus") }
                Button {
                    store.presets.removeAll { $0.id == selection }
                } label: { Image(systemName: "minus") }
                    .disabled(selection == nil || store.presets.count <= 1)
                Spacer()
                Text("First preset is the ⌘T default. Commands run in your login shell.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding()
        .onChange(of: store.presets) { _, _ in store.scheduleSave() }
    }
}

private struct IntegrationsSettings: View {
    @State private var installed = ClaudeHookInstaller.isInstalled
    @State private var error: String?

    var body: some View {
        Form {
            Section("Claude Code") {
                LabeledContent("Status hooks") {
                    Text(installed ? "Installed" : "Not installed")
                        .foregroundStyle(installed ? .green : .secondary)
                }
                Text("Adds hooks to ~/.claude/settings.json so sessions report Working / Ready / Needs input and trigger notifications. Hooks do nothing outside Terminaly. A backup is saved as settings.json.terminaly-backup.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button(installed ? "Reinstall Hooks" : "Install Hooks") {
                        run(ClaudeHookInstaller.install)
                    }
                    if installed {
                        Button("Remove Hooks") { run(ClaudeHookInstaller.uninstall) }
                    }
                }
                if let error { Text(error).foregroundStyle(.red).font(.caption) }
            }
            Section("Other agents") {
                Text("Sessions without hooks use output activity: Working while output flows, Ready after 2 s of silence. Notifications are only sent for hook-driven sessions.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func run(_ op: () throws -> Void) {
        do {
            try op()
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
        installed = ClaudeHookInstaller.isInstalled
    }
}

private struct TerminalSettings: View {
    @AppStorage("terminalFontSize") private var fontSize = 13.0
    @AppStorage("optionAsMeta") private var optionAsMeta = true
    @AppStorage("notificationsEnabled") private var notifications = true

    var body: some View {
        Form {
            Stepper("Font size: \(Int(fontSize)) pt", value: $fontSize, in: 9...24)
            Toggle("Option key sends Meta (Esc+)", isOn: $optionAsMeta)
            Toggle("Desktop notifications", isOn: $notifications)
        }
        .formStyle(.grouped)
        .onChange(of: fontSize) { _, _ in AppStore.shared.terminals.applyPrefs() }
        .onChange(of: optionAsMeta) { _, _ in AppStore.shared.terminals.applyPrefs() }
    }
}

private struct UpdatesSettings: View {
    @State private var updater = Updater.shared
    @Environment(\.openURL) private var openURL

    var body: some View {
        Form {
            LabeledContent("Version", value: Updater.currentVersion)
            if updater.isAvailable {
                Toggle("Check for updates automatically", isOn: Binding(
                    get: { updater.automaticallyChecksForUpdates },
                    set: { updater.automaticallyChecksForUpdates = $0 }
                ))
                Toggle("Download and install updates automatically", isOn: Binding(
                    get: { updater.automaticallyDownloadsUpdates },
                    set: { updater.automaticallyDownloadsUpdates = $0 }
                ))
                Button("Check for Updates…") { updater.checkForUpdates() }
                    .disabled(!updater.canCheckForUpdates)
                Text("Running sessions keep going during an update; they live in the tly host.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Text("Updates are only available in the bundled app (scripts/bundle.sh).")
                    .foregroundStyle(.secondary)
            }
            Section {
                Button("Buy Me a Coffee ☕") { openURL(Links.buyMeACoffee) }
            }
        }
        .formStyle(.grouped)
    }
}
