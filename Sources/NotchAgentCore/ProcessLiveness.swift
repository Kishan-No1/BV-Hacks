import Darwin
import Foundation

/// A process pinned by pid AND start time, so a recycled pid never looks like the same process.
public struct ProcessIdentity: Sendable, Equatable {
    public var pid: Int32
    /// Start time in microseconds since 1970.
    public var startedAt: UInt64

    public init(pid: Int32, startedAt: UInt64) {
        self.pid = pid; self.startedAt = startedAt
    }
}

/// Finds the Claude Code process behind a hook and tells whether it is still running. Uses sysctl only.
public enum ProcessLiveness {
    /// Shells Claude Code may run the hook command through. The first ancestor that is not one of them
    /// is the Claude Code process.
    static let shells: Set<String> = ["sh", "bash", "zsh", "dash", "fish", "env", "notch-agent-hook.sh"]

    struct Info { var ppid: Int32; var name: String; var startedAt: UInt64 }

    static func info(_ pid: Int32) -> Info? {
        guard pid > 0 else { return nil }
        var kinfo = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &kinfo, &size, nil, 0) == 0, size > 0, kinfo.kp_proc.p_pid == pid else { return nil }
        let start = kinfo.kp_proc.p_un.__p_starttime
        let name = withUnsafeBytes(of: kinfo.kp_proc.p_comm) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
        return Info(ppid: kinfo.kp_eproc.e_ppid, name: name,
                    startedAt: UInt64(start.tv_sec) * 1_000_000 + UInt64(start.tv_usec))
    }

    /// The Claude Code process for a hook whose parent pid is `hookParentPID`: that process, or the
    /// nearest ancestor that is not a shell. nil when it cannot be read.
    public static func claudeProcess(fromHookParent hookParentPID: Int32) -> ProcessIdentity? {
        var pid = hookParentPID
        for _ in 0..<6 {
            guard let i = info(pid) else { return nil }
            if !shells.contains(i.name) {
                // Never pin launchd or the kernel: that would keep a session forever.
                return pid > 1 ? ProcessIdentity(pid: pid, startedAt: i.startedAt) : nil
            }
            pid = i.ppid
        }
        return nil
    }

    /// The process and its ancestors, nearest first, stopping before launchd.
    public static func ancestry(of pid: Int32, limit: Int = 12) -> [Int32] {
        var out: [Int32] = []
        var p = pid
        while p > 1, out.count < limit, let i = info(p) {
            out.append(p)
            p = i.ppid
        }
        return out
    }

    /// true while the exact process (same pid, same start time) is running.
    public static func isAlive(_ identity: ProcessIdentity) -> Bool {
        guard let i = info(identity.pid) else { return false }
        return i.startedAt == identity.startedAt
    }
}
