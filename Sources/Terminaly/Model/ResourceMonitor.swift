import AppKit
import Foundation
import Observation
import TerminalyKit

/// Memory and CPU of every session, the session host and the app. Sampled only while a view
/// that shows it is on screen (`run(every:)`), so nothing polls when nobody is looking.
@MainActor
@Observable
final class ResourceMonitor {
    struct Sample: Equatable {
        var memory: UInt64 = 0
        /// Percent of one core over the last interval; nil until there are two samples.
        var cpu: Double?
        var processes = 0
    }

    private(set) var sessions: [UUID: Sample] = [:]
    private(set) var host = Sample()
    private(set) var app = Sample()

    var totalMemory: UInt64 { sessions.values.reduce(host.memory + app.memory) { $0 + $1.memory } }
    var totalCPU: Double? {
        guard let h = host.cpu, let a = app.cpu else { return nil }
        return sessions.values.reduce(h + a) { $0 + ($1.cpu ?? 0) }
    }

    @ObservationIgnored weak var client: DaemonClient?
    @ObservationIgnored private var previous: [UUID: (time: UInt64, at: Date)] = [:]
    @ObservationIgnored private var previousHost: (time: UInt64, at: Date)?
    @ObservationIgnored private var previousApp: (time: UInt64, at: Date)?
    @ObservationIgnored private var lastRefresh = Date.distantPast

    /// Refreshes until the calling task is cancelled (use from `.task`).
    func run(every interval: Duration) async {
        refresh()
        while !Task.isCancelled {
            try? await Task.sleep(for: interval)
            // Nobody reads the numbers while the app is in the background.
            if NSApp.isActive { refresh() }
        }
    }

    func refresh() {
        // Several views can run loops at once; one sample per second is plenty.
        guard Date().timeIntervalSince(lastRefresh) > 0.9 else { return }
        lastRefresh = Date()
        let now = Date()
        if let own = ProcessStats.usage(of: getpid()) {
            app = sample(own, now: now, previous: &previousApp)
        }
        guard let client, client.isConnected else { return }
        client.request(Message(type: "stats")) { [weak self] reply in
            guard let self, reply.error == nil else { return }
            if let h = reply.hostUsage { self.host = self.sample(h, now: now, previous: &self.previousHost) }
            var next: [UUID: Sample] = [:]
            var nextPrevious: [UUID: (time: UInt64, at: Date)] = [:]
            for entry in reply.usage ?? [] {
                var prev = self.previous[entry.id]
                next[entry.id] = self.sample(entry.usage, now: now, previous: &prev)
                nextPrevious[entry.id] = prev
            }
            self.sessions = next
            self.previous = nextPrevious
        }
    }

    private func sample(_ u: ProcessStats.Usage, now: Date, previous: inout (time: UInt64, at: Date)?) -> Sample {
        var cpu: Double?
        if let p = previous, now.timeIntervalSince(p.at) > 0.1 {
            // A child that exited takes its CPU time with it, so the sum can go down.
            let used = u.cpuTime >= p.time ? Double(u.cpuTime - p.time) : 0
            cpu = used / 1e9 / now.timeIntervalSince(p.at) * 100
        }
        previous = (u.cpuTime, now)
        return Sample(memory: u.memory, cpu: cpu, processes: u.processes)
    }

    static func format(memory: UInt64) -> String {
        let f = ByteCountFormatter()
        f.countStyle = .memory
        f.allowedUnits = [.useMB, .useGB]
        return f.string(fromByteCount: Int64(memory))
    }

    static func format(cpu: Double?) -> String {
        guard let cpu else { return "–" }
        return "\(Int(cpu.rounded())) %"
    }
}
