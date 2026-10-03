import Foundation
import Darwin

struct RunningProcess: Identifiable, Hashable {
    let pid: pid_t
    let path: String
    let cpu: Double
    let isOwn: Bool

    var id: pid_t { pid }
    var name: String { (path as NSString).lastPathComponent }
}

enum ProcessLister {
    /// Enumerate processes with their executable path, %CPU and ownership.
    /// Pure and thread-safe — call it off the main thread via `listAllAsync()`.
    static func listAll() -> [RunningProcess] {
        let entries = allProcs()
        let cpuMap = cpuByPID()
        let myUID = getuid()

        var result: [RunningProcess] = []
        result.reserveCapacity(entries.count)
        var buf = [CChar](repeating: 0, count: 4096)   // PROC_PIDPATHINFO_MAXSIZE
        for (pid, ruid) in entries {
            let n = proc_pidpath(pid, &buf, UInt32(buf.count))
            guard n > 0 else { continue }              // kernel / pathless procs
            // The buffer is reused across iterations; terminate at the
            // returned length rather than trusting a NUL from the kernel,
            // or a shorter path could pick up a longer predecessor's tail.
            if Int(n) < buf.count { buf[Int(n)] = 0 }
            let path = String(cString: buf)
            result.append(RunningProcess(pid: pid,
                                         path: path,
                                         cpu: cpuMap[pid] ?? 0,
                                         isOwn: ruid == myUID))
        }
        return result
    }

    /// Runs the blocking enumeration off the main thread.
    static func listAllAsync() async -> [RunningProcess] {
        await Task.detached(priority: .utility) { listAll() }.value
    }

    /// Every process — (pid, real uid) — via `sysctl(KERN_PROC_ALL)`, the same
    /// mechanism `ps` uses. `proc_listallpids()` silently under-reports on
    /// recent macOS (it returned ~150 of ~600 processes in testing), so it
    /// must not be used here.
    private static func allProcs() -> [(pid_t, uid_t)] {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        for _ in 0..<5 {
            var size = 0
            guard sysctl(&mib, 4, nil, &size, nil, 0) == 0, size > 0 else {
                return []
            }
            // Slack — the process count can grow between sizing and reading.
            let capacity = size / MemoryLayout<kinfo_proc>.stride + 32
            var procs = [kinfo_proc](repeating: kinfo_proc(), count: capacity)
            var filled = capacity * MemoryLayout<kinfo_proc>.stride
            let rc = sysctl(&mib, 4, &procs, &filled, nil, 0)
            if rc != 0 {
                if errno == ENOMEM { continue }        // grew — retry larger
                return []
            }
            let n = filled / MemoryLayout<kinfo_proc>.stride
            return procs.prefix(n).compactMap { (kp) -> (pid_t, uid_t)? in
                let pid = kp.kp_proc.p_pid
                guard pid > 0 else { return nil }
                return (pid, kp.kp_eproc.e_pcred.p_ruid)
            }
        }
        return []
    }

    /// %CPU per PID from one `ps` invocation.
    private static func cpuByPID() -> [pid_t: Double] {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/ps")
        task.arguments = ["-Ao", "pid=,%cpu="]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        do {
            try task.run()
        } catch {
            return [:]
        }
        // Drain the pipe BEFORE waiting. `ps` can emit more than the pipe
        // buffer holds; waiting first would deadlock.
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()

        let out = String(decoding: data, as: UTF8.self)
        var map = [pid_t: Double](minimumCapacity: 1024)
        for line in out.split(separator: "\n") {
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            guard parts.count >= 2,
                  let pid = pid_t(parts[0]),
                  let cpu = Double(parts[1]) else { continue }
            map[pid] = cpu
        }
        return map
    }
}
