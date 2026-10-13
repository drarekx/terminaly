import AppKit

/// Debug aid: `TERMINALY_SNAPSHOT_DIR=/tmp/x Terminaly` renders the main window into PNGs
/// (one per workspace, max 3) and quits. The app draws its own window, so no screen-recording
/// permission is needed.
@MainActor
enum Snapshot {
    static func runIfRequested() {
        guard let dir = ProcessInfo.processInfo.environment["TERMINALY_SNAPSHOT_DIR"] else { return }
        let url = URL(fileURLWithPath: dir)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        Task {
            try? await Task.sleep(for: .seconds(2.5))
            let store = AppStore.shared
            for i in 0..<min(store.workspaces.count, 3) {
                store.selectWorkspace(at: i)
                try? await Task.sleep(for: .seconds(1.2))
                capture(to: url.appendingPathComponent("workspace-\(i).png"))
            }
            exit(0)
        }
    }

    private static func capture(to url: URL) {
        guard let window = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil }),
              let view = window.contentView?.superview ?? window.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }
}
