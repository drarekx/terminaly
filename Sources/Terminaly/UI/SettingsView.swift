import SwiftUI

struct SettingsView: View {
    @State private var tab = ProcessInfo.processInfo.environment["TERMINALY_SETTINGS_TAB"] ?? "presets"

    var body: some View {
        TabView(selection: $tab) {
            PresetsSettings().tabItem { Label("Presets", systemImage: "list.bullet") }.tag("presets")
            IntegrationsSettings().tabItem { Label("Agents", systemImage: "sparkles") }.tag("agents")
            TerminalSettings().tabItem { Label("Terminal", systemImage: "terminal") }.tag("terminal")
            GeneralSettings().tabItem { Label("General", systemImage: "gearshape") }.tag("general")
        }
        .frame(width: 600, height: 520)
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
                    Text(installed ? LocalizedStringKey("Installed") : LocalizedStringKey("Not installed"))
                        .foregroundStyle(installed ? .green : .secondary)
                }
                Text("Adds hooks to ~/.claude/settings.json so sessions report Working / Ready / Needs input and trigger notifications. Hooks do nothing outside Terminaly. A backup is saved as settings.json.terminaly-backup.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button(installed ? LocalizedStringKey("Reinstall Hooks") : LocalizedStringKey("Install Hooks")) {
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
    @AppStorage("terminalTheme") private var themeID = "graphite"
    @AppStorage("terminalFontFamily") private var fontFamily = ""
    @AppStorage("terminalFontSize") private var fontSize = 13.0
    @AppStorage("optionAsMeta") private var optionAsMeta = true
    @AppStorage("notificationsEnabled") private var notifications = true
    @State private var families: [String] = []

    var body: some View {
        Form {
            Section("Theme") {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 10)], spacing: 10) {
                    ForEach(TerminalTheme.all) { theme in
                        ThemeCard(theme: theme, selected: theme.id == themeID) { themeID = theme.id }
                    }
                }
                .padding(.vertical, 4)
            }
            Section("Font") {
                Picker("Family", selection: $fontFamily) {
                    Text("SF Mono (system)").tag("")
                    ForEach(families, id: \.self) { Text($0).tag($0) }
                }
                Stepper("Size: \(Int(fontSize)) pt", value: $fontSize, in: 9...24)
                Text("The quick brown fox → 0O 1lI {}[]")
                    .font(SwiftUI.Font(TerminalFont.make(family: fontFamily, size: fontSize)))
                    .foregroundStyle(SwiftUI.Color(hex: TerminalTheme.named(themeID).foreground))
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 8).fill(TerminalTheme.named(themeID).backgroundColor))
            }
            Section("Behavior") {
                Toggle("Option key sends Meta (Esc+)", isOn: $optionAsMeta)
                Toggle("Desktop notifications", isOn: $notifications)
            }
        }
        .formStyle(.grouped)
        .onAppear { if families.isEmpty { families = TerminalFont.families } }
        .onChange(of: themeID) { _, _ in AppStore.shared.terminals.applyPrefs() }
        .onChange(of: fontFamily) { _, _ in AppStore.shared.terminals.applyPrefs() }
        .onChange(of: fontSize) { _, _ in AppStore.shared.terminals.applyPrefs() }
        .onChange(of: optionAsMeta) { _, _ in AppStore.shared.terminals.applyPrefs() }
    }
}

/// Theme preview: background, a prompt line and the 8 normal ANSI colors.
private struct ThemeCard: View {
    let theme: TerminalTheme
    let selected: Bool
    let pick: () -> Void

    var body: some View {
        Button(action: pick) {
            VStack(alignment: .leading, spacing: 8) {
                Text("~/dev ❯ ls")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(SwiftUI.Color(hex: theme.foreground))
                HStack(spacing: 3) {
                    ForEach(Array(theme.ansi.prefix(8).enumerated()), id: \.offset) { _, c in
                        RoundedRectangle(cornerRadius: 2).fill(SwiftUI.Color(hex: c)).frame(width: 14, height: 10)
                    }
                }
                Text(theme.name)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(SwiftUI.Color(hex: theme.foreground))
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8).fill(theme.backgroundColor))
            .overlay(RoundedRectangle(cornerRadius: 8)
                .strokeBorder(selected ? SwiftUI.Color.white : .white.opacity(0.12), lineWidth: selected ? 2 : 1))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(theme.name)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

private struct GeneralSettings: View {
    @State private var updater = Updater.shared
    @State private var language = AppLanguage.current
    @State private var languageChanged = false
    @Environment(\.openURL) private var openURL

    var body: some View {
        Form {
            Section("Language") {
                Picker("Language", selection: $language) {
                    ForEach(AppLanguage.allCases) { Text($0.displayName).tag($0) }
                }
                .onChange(of: language) { _, l in
                    AppLanguage.set(l)
                    languageChanged = true
                }
                if languageChanged {
                    HStack {
                        Text("The language changes after restarting. Sessions keep running.")
                            .font(Theme.Font.caption)
                            .foregroundStyle(Theme.secondaryText)
                        Spacer()
                        Button("Restart Terminaly") { AppLanguage.relaunch() }
                            .buttonStyle(PrimaryButtonStyle(compact: true))
                    }
                }
            }
            Section("Updates") {
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
                if FileManager.default.fileExists(atPath: UpdateDiagnostics.logURL.path) {
                    Button("Show Update Log") {
                        NSWorkspace.shared.activateFileViewerSelecting([UpdateDiagnostics.logURL])
                    }
                }
            } else {
                Text("Updates are only available in the bundled app (scripts/bundle.sh).")
                    .foregroundStyle(.secondary)
            }
            }
            Section {
                Button("Buy Me a Coffee ☕") { openURL(Links.buyMeACoffee) }
            }
        }
        .formStyle(.grouped)
    }
}
