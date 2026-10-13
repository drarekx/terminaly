import Darwin
import Foundation

enum Pty {
    /// forkpty + execve. All C strings are prepared before fork; the child only makes
    /// async-signal-safe calls until exec.
    static func spawn(executable: String, args: [String], env: [String], cwd: String,
                      cols: Int, rows: Int) -> (pid: pid_t, master: Int32)? {
        let cArgs = CStringArray(args)
        let cEnv = CStringArray(env)
        let cExe = strdup(executable)!
        let cCwd = strdup(cwd)!
        defer { free(cExe); free(cCwd) }

        var defaultAction = sigaction()
        defaultAction.__sigaction_u.__sa_handler = SIG_DFL
        sigemptyset(&defaultAction.sa_mask)
        var emptyMask = sigset_t()
        sigemptyset(&emptyMask)

        var ws = winsize(ws_row: UInt16(clamping: rows), ws_col: UInt16(clamping: cols), ws_xpixel: 0, ws_ypixel: 0)
        var master: Int32 = -1
        let pid = forkpty(&master, nil, nil, &ws)
        if pid < 0 { return nil }
        if pid == 0 {
            // Child: reset inherited signal dispositions (the daemon ignores SIGPIPE/SIGHUP).
            var sig: Int32 = 1
            while sig < NSIG {
                if sig != SIGKILL && sig != SIGSTOP { _ = sigaction(sig, &defaultAction, nil) }
                sig += 1
            }
            _ = sigprocmask(SIG_SETMASK, &emptyMask, nil)
            _ = chdir(cCwd)
            _ = execve(cExe, cArgs.pointer, cEnv.pointer)
            _exit(127)
        }
        _ = fcntl(master, F_SETFD, FD_CLOEXEC)
        return (pid, master)
    }

    static func resize(_ master: Int32, cols: Int, rows: Int) {
        var ws = winsize(ws_row: UInt16(clamping: rows), ws_col: UInt16(clamping: cols), ws_xpixel: 0, ws_ypixel: 0)
        _ = ioctl(master, TIOCSWINSZ, &ws)
    }
}

/// NULL-terminated char* array that owns its strings.
final class CStringArray {
    let pointer: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>
    private let count: Int

    init(_ strings: [String]) {
        count = strings.count
        pointer = .allocate(capacity: count + 1)
        for (i, s) in strings.enumerated() { pointer[i] = strdup(s) }
        pointer[count] = nil
    }

    deinit {
        for i in 0..<count { free(pointer[i]) }
        pointer.deallocate()
    }
}
