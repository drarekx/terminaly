import Darwin
import Foundation
import Observation
import SystemConfiguration
import TerminalyKit

/// Settings → Web: turns `tly web` on and off. The bridge runs as its own detached process so it
/// keeps serving while the app is closed; the app only edits `web.json` and (re)starts or stops it.
@MainActor
@Observable
final class WebAccess {
    static let shared = WebAccess()

    private(set) var config: WebConfig
    private(set) var isRunning = false
    private(set) var error: String?

    private init() {
        config = WebConfig.load() ?? WebConfig()
        isRunning = WebConfig.runningPID != nil
    }

    /// At launch: a bridge left running by an older version is replaced so it serves the current files.
    func startIfEnabled() {
        guard config.enabled else { return }
        restart()
    }

    func setEnabled(_ on: Bool) {
        config.enabled = on
        save()
        if on { restart() } else { stop() }
    }

    func setPort(_ port: Int) {
        guard port != config.port, (1024...65535).contains(port) else { return }
        config.port = port
        save()
        if config.enabled { restart() }
    }

    /// Open browsers are signed out: the bridge only reads the token at start.
    func regenerateToken() {
        config.token = WebConfig.newToken()
        save()
        if config.enabled { restart() }
    }

    private func save() {
        do {
            try config.save()
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func stop() {
        if let pid = WebConfig.runningPID { terminate(pid) }
        isRunning = false
    }

    private func restart() {
        if let pid = WebConfig.runningPID { terminate(pid) }
        do {
            let pid = try DaemonLauncher.spawnDetached(tlyPath: DaemonClient.tlyPath, arguments: ["web"], log: WebConfig.logPath)
            reap(pid)
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
        // The bridge exits right away if the port is taken; check once it had time to bind.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            guard let self else { return }
            self.isRunning = WebConfig.runningPID != nil
            if !self.isRunning && self.config.enabled && self.error == nil {
                self.error = String(localized: "The web server did not start. Is port \(String(self.config.port)) in use?")
            }
        }
    }

    /// Waits for the old bridge to release the port and its lock before a new one starts.
    private func terminate(_ pid: pid_t) {
        kill(pid, SIGTERM)
        for _ in 0..<40 where kill(pid, 0) == 0 {
            _ = waitpid(pid, nil, WNOHANG)
            usleep(25_000)
        }
    }

    /// The bridge is our child when we started it; collect it when it exits so it doesn't linger as a zombie.
    private func reap(_ pid: pid_t) {
        DispatchQueue.global(qos: .utility).async {
            var status: Int32 = 0
            _ = waitpid(pid, &status, 0)
        }
    }

    /// Addresses other machines can use: IPv4 on active non-loopback interfaces (LAN and VPN tunnels).
    var urls: [String] {
        var out: [String] = []
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return [] }
        defer { freeifaddrs(ifaddr) }
        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let ifa = ptr.pointee
            guard let addr = ifa.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET),
                  ifa.ifa_flags & UInt32(IFF_UP) != 0, ifa.ifa_flags & UInt32(IFF_LOOPBACK) == 0 else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(addr, socklen_t(addr.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                let ip = String(cString: host)
                if !ip.hasPrefix("169.254.") { out.append("http://\(ip):\(config.port)") }
            }
        }
        return Array(Set(out)).sorted()
    }

    /// The Bonjour name works on most LANs and survives DHCP changes (not always through a VPN).
    var bonjourURL: String? {
        guard let name = SCDynamicStoreCopyLocalHostName(nil) as String? else { return nil }
        return "http://\(name).local:\(config.port)"
    }
}
