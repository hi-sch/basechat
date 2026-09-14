import Darwin
import Foundation

/// Stops inference children (`basert-serve`, `edge0`) including process groups
/// and leftovers from `basert serve` handing off and exiting.
enum ProcessTree {
    static func detach(_ process: Process) {
        let pid = process.processIdentifier
        guard pid > 1 else { return }
        _ = setpgid(pid, pid)
    }

    static func stop(_ process: Process) {
        let pid = process.processIdentifier
        if pid > 1 {
            _ = setpgid(pid, pid)
            terminateTree(pid)
        }
        if process.isRunning { process.interrupt() }
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) {
            if pid > 1 {
                terminateTree(pid, signal: SIGKILL)
                _ = killpg(pid, SIGKILL)
            }
            if process.isRunning { process.terminate() }
            process.waitUntilExit()
        }
    }

    /// Kill stray serve processes from earlier launches (PPID 1 orphans).
    static func reapOrphans() {
        let selfPID = getpid()
        var seen = Set<pid_t>([selfPID])
        let queries: [[String]] = [
            ["-x", "basert-serve"],
            ["-f", "basert serve"],
            ["-f", "-m edge0 serve"],
            ["-f", "edge0 serve"],
        ]
        for query in queries {
            for pid in pgrep(query) where pid > 1 && seen.insert(pid).inserted {
                terminateTree(pid)
                DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) {
                    terminateTree(pid, signal: SIGKILL)
                }
            }
        }
    }

    private static func terminateTree(_ pid: pid_t, signal: Int32 = SIGTERM) {
        for child in children(of: pid) {
            terminateTree(child, signal: signal)
        }
        _ = kill(pid, signal)
    }

    private static func children(of pid: pid_t) -> [pid_t] {
        pgrep(["-P", String(pid)])
    }

    private static func pgrep(_ args: [String]) -> [pid_t] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        process.arguments = args
        let out = Pipe()
        process.standardOutput = out
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return []
        }
        let text = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return text.split(whereSeparator: \.isNewline).compactMap { pid_t($0) }
    }
}
