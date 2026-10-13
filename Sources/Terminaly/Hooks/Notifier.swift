import AppKit
import UserNotifications

@MainActor
enum Notifier {
    /// UNUserNotificationCenter needs a real app bundle; `swift run` binaries have none.
    static var available: Bool { Bundle.main.bundleIdentifier != nil && Bundle.main.bundlePath.hasSuffix(".app") }

    static func requestAuthorization() {
        guard available else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }

    static func post(session: Session, project: Project?, status: SessionStatus, detail: String?) {
        guard available, UserDefaults.standard.object(forKey: "notificationsEnabled") as? Bool ?? true else { return }
        let content = UNMutableNotificationContent()
        content.title = session.title + (project.map { " · \($0.name)" } ?? "")
        content.body = detail ?? (status == .needsInput ? String(localized: "Needs your input") : String(localized: "Finished"))
        content.sound = .default
        content.userInfo = ["sessionID": session.id.uuidString]
        let req = UNNotificationRequest(identifier: session.id.uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req)
    }

    static func updateBadge(count: Int) {
        NSApp.dockTile.badgeLabel = count > 0 ? String(count) : nil
    }
}
