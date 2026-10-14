import Foundation
import Observation
import Sparkle

/// Sparkle auto-update. Feed: appcast.xml attached to the latest GitHub release
/// (see scripts/release.sh). Inactive when not running from an .app bundle (e.g. `swift run`).
@MainActor
@Observable
final class Updater {
    static let shared = Updater()

    @ObservationIgnored private let controller: SPUStandardUpdaterController?
    @ObservationIgnored private let diagnostics = UpdateDiagnostics()
    @ObservationIgnored private var observation: NSKeyValueObservation?
    private(set) var canCheckForUpdates = false

    var isAvailable: Bool { controller != nil }

    var automaticallyDownloadsUpdates: Bool {
        get { controller?.updater.automaticallyDownloadsUpdates ?? false }
        set { controller?.updater.automaticallyDownloadsUpdates = newValue }
    }

    var automaticallyChecksForUpdates: Bool {
        get { controller?.updater.automaticallyChecksForUpdates ?? false }
        set { controller?.updater.automaticallyChecksForUpdates = newValue }
    }

    private init() {
        let bundled = Bundle.main.bundlePath.hasSuffix(".app")
            && Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") != nil
            && !CommandLine.arguments.contains("--selftest")
        controller = bundled
            ? SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: diagnostics, userDriverDelegate: nil)
            : nil
        observation = controller?.updater.observe(\.canCheckForUpdates, options: [.initial, .new]) { [weak self] updater, _ in
            let value = updater.canCheckForUpdates
            DispatchQueue.main.async { self?.canCheckForUpdates = value }
        }
    }

    func checkForUpdates() {
        controller?.checkForUpdates(nil)
    }

    static var currentVersion: String {
        let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
        let b = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
        return "\(v) (\(b))"
    }
}

/// Writes the full cause of update failures (Sparkle's dialog only says "an error occurred")
/// to ~/Library/Logs/Terminaly/update.log.
final class UpdateDiagnostics: NSObject, SPUUpdaterDelegate {
    static var logURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Terminaly/update.log")
    }

    func updater(_ updater: SPUUpdater, failedToDownloadUpdate item: SUAppcastItem, error: Error) {
        Self.log("download failed for \(item.displayVersionString) (\(item.fileURL?.absoluteString ?? "-"))", error)
    }

    func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        let ns = error as NSError
        // "No update available" is reported as an abort too; it is not a failure.
        if ns.domain == SUSparkleErrorDomain && ns.code == Int(SUError.noUpdateError.rawValue) { return }
        Self.log("update aborted", error)
    }

    static func log(_ what: String, _ error: Error) {
        var lines = ["\(ISO8601DateFormatter().string(from: Date())) \(Updater.currentVersion) \(what)"]
        var current: NSError? = error as NSError
        while let e = current {
            lines.append("  \(e.domain) \(e.code): \(e.localizedDescription)")
            if let url = e.userInfo[NSURLErrorFailingURLErrorKey] { lines.append("    url: \(url)") }
            current = e.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        let text = lines.joined(separator: "\n") + "\n"
        let url = logURL
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(Data(text.utf8))
            try? handle.close()
        } else {
            try? Data(text.utf8).write(to: url)
        }
    }
}

enum Links {
    static let buyMeACoffee = URL(string: "https://buymeacoffee.com/drarek")!
    static let repository = URL(string: "https://github.com/drarekx/terminaly")!
}
