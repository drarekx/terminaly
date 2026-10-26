import Darwin
import Foundation

/// Memory and CPU time of a process tree, read from libproc (no polling, just a snapshot).
public enum ProcessStats {
    public struct Usage: Codable, Hashable, Sendable {
        /// Physical footprint (what Activity Monitor shows as "Memory").
        public var memory: UInt64 = 0
        /// User + system CPU time since launch, in nanoseconds.
        public var cpuTime: UInt64 = 0
        public var processes: Int = 0

        public init(memory: UInt64 = 0, cpuTime: UInt64 = 0, processes: Int = 0) {
            self.memory = memory
            self.cpuTime = cpuTime
            self.processes = processes
        }

        public static func + (a: Usage, b: Usage) -> Usage {
            Usage(memory: a.memory + b.memory, cpuTime: a.cpuTime + b.cpuTime, processes: a.processes + b.processes)
        }
    }

    /// rusage times are mach absolute units, which are not nanoseconds on Apple silicon.
    private static let timebase: (numer: UInt64, denom: UInt64) = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return (UInt64(info.numer), UInt64(max(info.denom, 1)))
    }()

    public static func usage(of pid: pid_t) -> Usage? {
        var info = rusage_info_v2()
        let ok = withUnsafeMutablePointer(to: &info) { ptr in
            ptr.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(pid, RUSAGE_INFO_V2, $0)
            }
        }
        guard ok == 0 else { return nil }
        let ticks = info.ri_user_time + info.ri_system_time
        return Usage(memory: info.ri_phys_footprint, cpuTime: ticks * timebase.numer / timebase.denom, processes: 1)
    }

    /// Parent of every live process, from one pass over the process table.
    public static func parentMap() -> [pid_t: pid_t] {
        let capacity = Int(proc_listallpids(nil, 0)) + 64
        guard capacity > 64 else { return [:] }
        var pids = [pid_t](repeating: 0, count: capacity)
        let n = Int(proc_listallpids(&pids, Int32(capacity * MemoryLayout<pid_t>.size)))
        var parents: [pid_t: pid_t] = [:]
        parents.reserveCapacity(n)
        for pid in pids.prefix(max(n, 0)) where pid > 0 {
            var bsd = proc_bsdinfo()
            let size = Int32(MemoryLayout<proc_bsdinfo>.size)
            if proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &bsd, size) == size {
                parents[pid] = pid_t(bsd.pbi_ppid)
            }
        }
        return parents
    }

    /// `root` followed by all its descendants, parents before children.
    public static func tree(of root: pid_t, parents: [pid_t: pid_t]) -> [pid_t] {
        var children: [pid_t: [pid_t]] = [:]
        for (pid, ppid) in parents { children[ppid, default: []].append(pid) }
        var out = [root]
        var i = 0
        while i < out.count {
            out.append(contentsOf: children[out[i]] ?? [])
            i += 1
        }
        return out
    }

    public static func treeUsage(of root: pid_t, parents: [pid_t: pid_t]) -> Usage {
        tree(of: root, parents: parents).compactMap(usage(of:)).reduce(Usage(), +)
    }
}
