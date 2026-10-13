import AppKit
import SwiftUI
import UserNotifications

@main
struct TerminalyApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @State private var store = AppStore.shared

    var body: some Scene {
        Window("Terminaly", id: "main") {
            RootView()
                .environment(store)
                .frame(minWidth: 760, minHeight: 460)
        }
        .windowStyle(.hiddenTitleBar)
        .commands { AppCommands(store: store) }

        Settings {
            SettingsView()
                .environment(store)
                .preferredColorScheme(.dark)
        }
    }
}

struct AppCommands: Commands {
    let store: AppStore
    @Environment(\.openURL) private var openURL

    var body: some Commands {
        CommandGroup(after: .appInfo) {
            Button("Check for Updates…") { Updater.shared.checkForUpdates() }
                .disabled(!Updater.shared.canCheckForUpdates)
            Button("Buy Me a Coffee ☕") { openURL(Links.buyMeACoffee) }
        }
        CommandGroup(replacing: .help) {
            Button("Terminaly on GitHub") { openURL(Links.repository) }
            Button("Buy Me a Coffee ☕") { openURL(Links.buyMeACoffee) }
        }
        CommandGroup(replacing: .newItem) {
            Menu("New Session") {
                ForEach(store.presets) { preset in
                    Button(preset.label) { store.newSession(preset: preset) }
                }
            }
            Button("New Session (Default Preset)") {
                if let p = store.presets.first { store.newSession(preset: p) }
            }
            .keyboardShortcut("t")
            Button("Add Project…") { store.addProjectWithPanel() }
                .keyboardShortcut("o")
        }
        CommandMenu("Session") {
            Button("Command Palette") { store.showPalette.toggle() }
                .keyboardShortcut("k")
            Divider()
            Button("Next Session") { store.cycleSession(by: 1) }
                .keyboardShortcut("]")
            Button("Previous Session") { store.cycleSession(by: -1) }
                .keyboardShortcut("[")
            Divider()
            Button("Rename Session…") { store.renamingSessionID = store.selectedSessionID }
                .disabled(store.selectedSessionID == nil)
            Button("Restart Session") { store.selectedSessionID.map(store.restart) }
                .disabled(store.selectedSessionID == nil)
            Button("Archive Session") { store.selectedSessionID.map(store.archive) }
                .keyboardShortcut(.delete, modifiers: [.command, .shift])
                .disabled(store.selectedSessionID == nil)
            Divider()
            Button("Stop All Sessions…") { store.confirmStopAll() }
        }
        CommandMenu("Workspace") {
            Button("New Workspace") { store.addWorkspace() }
                .keyboardShortcut("n", modifiers: [.command, .shift])
            Button("Rename Workspace…") { store.renamingWorkspaceID = store.selectedWorkspaceID }
            Divider()
            Button("Next Workspace") { store.cycleWorkspace(by: 1) }
                .keyboardShortcut(.rightArrow, modifiers: [.command, .option])
            Button("Previous Workspace") { store.cycleWorkspace(by: -1) }
                .keyboardShortcut(.leftArrow, modifiers: [.command, .option])
            Divider()
            ForEach(Array(store.workspaces.prefix(9).enumerated()), id: \.element.id) { i, ws in
                Button(ws.name) { store.selectWorkspace(at: i) }
                    .keyboardShortcut(KeyEquivalent(Character(String(i + 1))), modifiers: [.command, .option])
            }
        }
        CommandMenu("Pane") {
            Button("Split Right") { store.split(.horizontal) }
                .keyboardShortcut("d")
            Button("Split Down") { store.split(.vertical) }
                .keyboardShortcut("d", modifiers: [.command, .shift])
            Button(store.zoomedLeafID == nil ? LocalizedStringKey("Zoom Pane") : LocalizedStringKey("Unzoom Pane")) { store.toggleZoom() }
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(store.layout.leafIDs.count < 2)
            Button("Close Pane") { store.closePane() }
                .keyboardShortcut("w")
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        if !CommandLine.arguments.contains("--selftest") {
            MainActor.assumeIsolated { AppStore.shared.connectToHost() }
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        _ = MainActor.assumeIsolated { Updater.shared }  // starts scheduled update checks
        NSApp.activate()
        if CommandLine.arguments.contains("--selftest") {
            MainActor.assumeIsolated { SelfTest.run() }
            return
        }
        MainActor.assumeIsolated { Snapshot.runIfRequested() }
        if Notifier.available {
            UNUserNotificationCenter.current().delegate = self
            Notifier.requestAuthorization()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // Sessions keep running in the `tly` host; they reattach on next launch.
        MainActor.assumeIsolated { AppStore.shared.saveNow() }
        return .terminateNow
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        guard let raw = response.notification.request.content.userInfo["sessionID"] as? String,
              let id = UUID(uuidString: raw) else { return }
        await MainActor.run {
            NSApp.activate()
            AppStore.shared.show(id)
        }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
}
