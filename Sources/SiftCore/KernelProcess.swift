//
// Copyright © Agulhas Labs
//

import Darwin
import Foundation

/// A process as the kernel records it, read by pid.
///
/// **The one place in the codebase that reads a kernel process record**, because two readings shaped slightly differently are how two answers about one process come to disagree: the server report decides from it whether a recorded server is still running, and a set-aside decides from it whether a pid still names the process it started.
public struct KernelProcess: Sendable {
    private init() {}
}

public extension KernelProcess {
    /// The kernel's record for `pid` — a zombie's included — or `nil` where nothing holds the pid.
    static func record(of pid: Int32) -> kinfo_proc? {
        guard pid > 0 else {
            return nil
        }
        var name: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        guard sysctl(&name, UInt32(name.count), &info, &size, nil, 0) == 0, size > 0, info.kp_proc.p_pid == pid else {
            return nil
        }
        return info
    }

    /// The name the kernel gives the process holding `pid` — the first sixteen bytes of its executable's file name, never its `argv[0]` — or `nil` where nothing holds the pid or the name is empty or not UTF-8.
    ///
    /// A harness can name itself anything here: Claude Code's process is named for its version (`2.1.292`), so a reader asking which program a process runs can rely on a short list of names it knows, never on recognising every other.
    static func name(of pid: Int32) -> String? {
        guard let command = record(of: pid)?.kp_proc.p_comm else {
            return nil
        }
        let name = withUnsafeBytes(of: command) { bytes in
            String(bytes: bytes.prefix { $0 != 0 }, encoding: .utf8)
        }
        guard let name, !name.isEmpty else {
            return nil
        }
        return name
    }

    /// When the process holding `pid` was started, in microseconds since 1970 — a zombie's included — or `nil` where nothing holds the pid.
    ///
    /// Exact rather than rounded, because it is compared for identity: a pid is reused, and the start time is what a process that reuses it cannot share.
    static func startMicroseconds(of pid: Int32) -> UInt64? {
        guard let started = record(of: pid)?.kp_proc.p_un.__p_starttime, started.tv_sec >= 0 else {
            return nil
        }
        return UInt64(started.tv_sec) * 1_000_000 + UInt64(max(0, started.tv_usec))
    }
}
