import AppKit
import SwiftTerm
import TerminalyKit

/// Terminal view for one hosted session. The process lives in the `tly` daemon;
/// this view only renders output and forwards input/resizes.
final class AgentTerminalView: TerminalView {
    let sessionID: UUID
    fileprivate lazy var bridge = TerminalBridge(view: self)

    init(sessionID: UUID) {
        self.sessionID = sessionID
        super.init(frame: NSRect(x: 0, y: 0, width: 800, height: 500))
        terminalDelegate = bridge
        font = NSFont.monospacedSystemFont(ofSize: TerminalPrefs.fontSize, weight: .regular)
        nativeBackgroundColor = Theme.paneNS
        nativeForegroundColor = Theme.textNS
        caretColor = .systemTeal
        optionAsMetaKey = TerminalPrefs.optionAsMeta
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Last grid size reported by SwiftTerm through `sizeChanged`.
    var gridSize: (cols: Int, rows: Int) = (80, 24)

    /// Visible screen + scrollback as plain text.
    func screenText() -> String {
        selectAll()
        defer { selectNone() }
        return getSelection() ?? ""
    }
}

/// Separate delegate object to avoid clashing with TerminalView's own public methods.
@MainActor
final class TerminalBridge: TerminalViewDelegate {
    weak var view: AgentTerminalView?
    weak var registry: TerminalRegistry?

    init(view: AgentTerminalView) { self.view = view }

    nonisolated func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
        MainActor.assumeIsolated {
            guard let view else { return }
            view.gridSize = (newCols, newRows)
            registry?.resize(view.sessionID, cols: newCols, rows: newRows)
        }
    }

    nonisolated func setTerminalTitle(source: TerminalView, title: String) {
        MainActor.assumeIsolated {
            guard let view else { return }
            registry?.store?.terminalTitleChanged(view.sessionID, title: title)
        }
    }

    nonisolated func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

    nonisolated func send(source: TerminalView, data: ArraySlice<UInt8>) {
        MainActor.assumeIsolated {
            guard let view else { return }
            registry?.client.sendInput(view.sessionID, data)
        }
    }

    nonisolated func scrolled(source: TerminalView, position: Double) {}

    nonisolated func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
        if let url = URL(string: link) {
            DispatchQueue.main.async { NSWorkspace.shared.open(url) }
        }
    }

    nonisolated func bell(source: TerminalView) {
        DispatchQueue.main.async { NSSound.beep() }
    }

    nonisolated func clipboardCopy(source: TerminalView, content: Data) {
        guard let s = String(data: content, encoding: .utf8) else { return }
        DispatchQueue.main.async {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(s, forType: .string)
        }
    }

    nonisolated func clipboardRead(source: TerminalView) -> Data? { nil }

    nonisolated func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}

    nonisolated func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
}

enum TerminalPrefs {
    static var fontSize: CGFloat {
        let v = UserDefaults.standard.double(forKey: "terminalFontSize")
        return v > 0 ? v : 13
    }
    static var optionAsMeta: Bool {
        UserDefaults.standard.object(forKey: "optionAsMeta") as? Bool ?? true
    }
}

/// Maps sessions to terminal views and talks to the session host.
@MainActor
final class TerminalRegistry {
    weak var store: AppStore?
    let client = DaemonClient()
    fileprivate var views: [UUID: AgentTerminalView] = [:]
    fileprivate var running: Set<UUID> = []

    init() {
        client.onOutput = { [weak self] id, bytes in
            guard let self, let view = self.views[id] else { return }
            view.feed(byteArray: bytes)
            self.store?.outputReceived(id)
        }
        client.onEvent = { [weak self] msg in self?.handle(msg) }
        client.onDisconnect = { [weak self] in
            guard let self else { return }
            for id in self.running { self.store?.applyStatus(id, status: "exited", detail: nil, notify: false, exitCode: nil) }
            self.running.removeAll()
        }
    }

    func view(for id: UUID) -> AgentTerminalView? { views[id] }

    func isRunning(_ id: UUID) -> Bool { running.contains(id) }

    /// Connects to the host and re-attaches sessions that survived an app restart.
    func connect(completion: @escaping ([SessionInfo]) -> Void) {
        do {
            try client.connect()
        } catch {
            NSLog("Terminaly: session host unavailable: \(error)")
            completion([])
            return
        }
        client.request(Message(type: "list")) { [weak self] reply in
            guard let self else { return }
            let list = reply.sessions ?? []
            for info in list where info.running {
                self.running.insert(info.id)
                self.attach(info.id)
            }
            completion(list)
        }
    }

    private func makeView(_ id: UUID) -> AgentTerminalView {
        if let v = views[id] { return v }
        let v = AgentTerminalView(sessionID: id)
        v.bridge.registry = self
        views[id] = v
        return v
    }

    func start(_ session: Session, cwd: String) {
        let view = makeView(session.id)
        var m = Message(type: "create", id: session.id)
        m.command = session.command
        m.cwd = cwd
        (m.cols, m.rows) = view.gridSize
        client.request(m) { [weak self] reply in
            guard let self else { return }
            if let error = reply.error {
                view.feed(text: "\r\n[Terminaly] could not start session: \(error)\r\n")
                self.store?.applyStatus(session.id, status: "exited", detail: nil, notify: false, exitCode: nil)
                return
            }
            self.running.insert(session.id)
            self.attach(session.id)
        }
    }

    private func attach(_ id: UUID) {
        let view = makeView(id)
        client.request(Message(type: "attach", id: id)) { [weak self] reply in
            guard let self, reply.error == nil else { return }
            if let info = reply.sessions?.first {
                self.store?.applyStatus(id, status: info.status, detail: nil, notify: false, exitCode: info.exitCode)
            }
            // Nudge the size so full-screen programs repaint after the replay.
            let (cols, rows) = view.gridSize
            self.resize(id, cols: max(cols - 1, 2), rows: rows)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
                let (c, r) = view.gridSize
                self?.resize(id, cols: c, rows: r)
            }
        }
    }

    func resize(_ id: UUID, cols: Int, rows: Int) {
        guard running.contains(id) else { return }
        var m = Message(type: "resize", id: id)
        m.cols = cols
        m.rows = rows
        client.request(m)
    }

    /// Kills the process and forgets it in the host.
    func stop(_ id: UUID) {
        client.request(Message(type: "remove", id: id))
        running.remove(id)
        views.removeValue(forKey: id)?.removeFromSuperview()
    }

    func stopAll() {
        for id in Array(running) { stop(id) }
    }

    private func handle(_ msg: Message) {
        guard let id = msg.id else { return }
        switch msg.type {
        case "status":
            if msg.status == "exited" { running.remove(id) }
            store?.applyStatus(id, status: msg.status ?? "idle", detail: msg.detail,
                               notify: msg.notify ?? false, exitCode: msg.exitCode)
        case "removed":
            running.remove(id)
        default:
            break
        }
    }

    func focus(_ id: UUID) {
        guard let view = views[id] else { return }
        DispatchQueue.main.async {
            view.window?.makeFirstResponder(view)
        }
    }

    func applyPrefs() {
        for v in views.values {
            v.font = NSFont.monospacedSystemFont(ofSize: TerminalPrefs.fontSize, weight: .regular)
            v.optionAsMetaKey = TerminalPrefs.optionAsMeta
        }
    }
}

extension TerminalRegistry {
    /// Self-test helper: drops the connection and all views as if the app had quit, then reconnects.
    func simulateRelaunch(completion: @escaping ([SessionInfo]) -> Void) {
        client.disconnect()
        for v in views.values { v.removeFromSuperview() }
        views.removeAll()
        running.removeAll()
        connect(completion: completion)
    }
}
