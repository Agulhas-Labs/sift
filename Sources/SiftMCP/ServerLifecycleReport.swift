//
// Copyright © Agulhas Labs
//

import Foundation
import SiftCore

/// Turns the server lifecycle log into the line `sift status` prints.
///
/// This is the half of the lifecycle log that pays off at the point of use. An agent whose index tools have vanished has one question — *is there a server, and if not, what happened to it?* — and without a record the only honest answer is a shrug. Three states are worth telling apart, and the log distinguishes all three: a start with no stop whose process is alive, which is a server serving; a start with no stop whose process is **gone**, which is what `SIGKILL` and a hard crash look like and nothing else does; and a stop, whose entry says whether the client hung up, the pipe failed, or something on this machine signalled it.
///
/// **A pid is not an identity, so a pid alone is not the check.** `kill(pid, 0)` says only that *something* holds that number, and pids are recycled: weeks later an unrelated process inherits one and this line tells an agent whose four tools have just vanished that its server is healthy — the exact failure the line exists to prevent, now carrying the tool's endorsement. So a pid must clear three things before it is called running: the kernel must hold a record for it, that record must not be a zombie, and its start time must agree with the time the entry was written. What this reports is therefore what it checked.
public struct ServerLifecycleReport {
    /// How far the kernel's start time may sit from the recorded one and still be the same process.
    ///
    /// The entry is written by the first statement of the command, so the true gap is milliseconds; the stamp's one-second granularity and a loaded machine's launch are the whole of what this has to absorb. Generous against a false alarm, and far tighter than any plausible pid recycle.
    static let startTimeTolerance: TimeInterval = 30

    /// The status line for the log at `fileURL`, or `nil` when it holds nothing to say.
    public static func text(
        fileURL: URL,
        bootedAt: Date? = bootTime(),
        isRunning: (ServerLifecycleEntry) -> Bool = isStillRunning
    ) -> String? {
        text(entries: entries(in: fileURL), bootedAt: bootedAt, isRunning: isRunning)
    }

    public static func text(
        entries: [ServerLifecycleEntry],
        bootedAt: Date?,
        isRunning: (ServerLifecycleEntry) -> Bool
    ) -> String? {
        guard !entries.isEmpty else { return nil }

        let unclosed = unclosedStarts(in: entries)
        let running = unclosed.filter { isRunning($0) }
        let vanished = unclosed.filter { !isRunning($0) && survivedThisBoot($0, bootedAt: bootedAt) }
        let lastStop = entries.last { $0.event == "stop" }

        var parts: [String] = [runningPhrase(running)]
        if let phrase = vanishedPhrase(vanished) {
            parts.append(phrase)
        }
        if let lastStop {
            parts.append("last stop \(lastStop.stamp) pid \(lastStop.pid)\(lasted(lastStop)) — \(describe(lastStop))")
        }
        return "mcp servers — " + parts.joined(separator: "; ")
    }

    /// The starts in this log that no stop ever closed, oldest first — every server this machine believes is still going.
    ///
    /// Pairing is by pid and closes the *most recent* matching start, so a recycled pid closes its own rather than an older one still open. Here rather than beside either of its two callers because the status line and the roster (``ServerRoster``) must agree exactly about what "still running" means: two readings of one log that disagreed would have `sift status` naming a server the reap says is not there.
    public static func unclosedStarts(in entries: [ServerLifecycleEntry]) -> [ServerLifecycleEntry] {
        var unclosed: [ServerLifecycleEntry] = []
        for entry in entries {
            switch entry.event {
            case "start":
                unclosed.append(entry)
            case "stop":
                if let index = unclosed.lastIndex(where: { $0.pid == entry.pid }) {
                    unclosed.remove(at: index)
                }
            default:
                continue
            }
        }

        return unclosed
    }

    private static func runningPhrase(_ running: [ServerLifecycleEntry]) -> String {
        guard !running.isEmpty else { return "none running" }
        let plural = running.count == 1 ? "" : "s"
        return "\(running.count) running (pid\(plural) \(running.map { String($0.pid) }.joined(separator: ", ")))"
    }

    /// The finding that matters most and reads least like one.
    ///
    /// A server that started, never recorded a stop, and is not there any more: nothing but an uncatchable death leaves that shape.
    private static func vanishedPhrase(_ vanished: [ServerLifecycleEntry]) -> String? {
        guard let newest = vanished.last else { return nil }
        let plural = vanished.count == 1 ? "" : "s"
        let subject = vanished.count == 1 ? "its process is" : "their processes are"
        let pids = vanished.map { String($0.pid) }.joined(separator: ", ")
        return "\(vanished.count) started and never recorded a stop and \(subject) gone"
            + " (pid\(plural) \(pids), newest \(newest.stamp))"
            + " — killed outright, or died without reaching its exit path"
    }

    /// Whether an unclosed start belongs to *this* boot, which is the only thing that makes its silence a finding.
    ///
    /// A reboot never lets a server record a stop, so every start it interrupted stays unclosed forever and would otherwise put a permanent alarm into `sift status`. An age window instead would be wrong in the direction that costs: measured from the *start* stamp, a server that ran thirty hours and was killed a minute ago falls outside it — dead, so not running; filtered, so not vanished; absent from the report entirely, in the one case this branch exists to make visible.
    ///
    /// Boot time answers the actual question — *was this process killed, or did the machine simply go away underneath it?* — exactly rather than by proxy, and takes an arbitrary constant out of the tool. A start with no readable stamp, or a kernel that will not say when it booted, is reported rather than swallowed: this may only ever suppress a finding it is certain about.
    private static func survivedThisBoot(_ entry: ServerLifecycleEntry, bootedAt: Date?) -> Bool {
        guard let bootedAt, let date = entry.date else { return true }
        return date >= bootedAt
    }

    private static func lasted(_ entry: ServerLifecycleEntry) -> String {
        guard let seconds = entry.seconds else { return "" }
        return " after \(duration(seconds))"
    }

    /// A rough age in one unit — seconds, minutes, then hours.
    ///
    /// Shared with the roster's listing (``ServerRosterReport``) so the two faces over this log say "6h" the same way; a second spelling of an age is a second thing a reader has to reconcile between two outputs about the same server.
    static func duration(_ seconds: Int) -> String {
        if seconds < 90 {
            return "\(seconds)s"
        }
        if seconds < 5400 {
            return "\(seconds / 60)m"
        }
        return "\(seconds / 3600)h"
    }

    private static func describe(_ entry: ServerLifecycleEntry) -> String {
        let reason = entry.reason ?? "unknown"
        guard let detail = entry.detail else { return reason }
        return "\(reason) (\(detail))"
    }

    /// Every entry the log holds, oldest first; unreadable lines are skipped rather than failing the read.
    ///
    /// Read under a shared lock, which is the other half of the trim in ``ServerLifecycleLog``: that rewrite happens in place, so an unlocked reader can catch the file truncated and report no servers running while two are.
    public static func entries(in fileURL: URL) -> [ServerLifecycleEntry] {
        let descriptor = open(fileURL.path, O_RDONLY | O_CLOEXEC)
        guard descriptor >= 0 else { return [] }
        defer { close(descriptor) }
        FileLock.take(descriptor, .shared)
        defer { FileLock.release(descriptor) }

        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
        guard let data = try? handle.readToEnd() else { return [] }
        return data.split(separator: 0x0A, omittingEmptySubsequences: true).compactMap { entry(from: Data($0)) }
    }

    /// One line of the log read back as an entry, or `nil` for a line that is not one.
    static func entry(from line: Data) -> ServerLifecycleEntry? {
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let event = object["event"] as? String,
              let pid = object["pid"] as? Int,
              let stamp = object["ts"] as? String
        else { return nil }
        return ServerLifecycleEntry(
            event: event,
            pid: Int32(pid),
            stamp: stamp,
            reason: object["reason"] as? String,
            detail: object["detail"] as? String,
            seconds: object["seconds"] as? Int,
            root: object["root"] as? String,
            session: object["session"] as? String,
            parent: (object["parent"] as? Int).flatMap { Int32(exactly: $0) }
        )
    }

    /// Whether the process this entry recorded is the one holding that pid now.
    ///
    /// Both halves are required: a pid nothing holds is gone, and a pid something else has since been given is *also* gone as far as this entry is concerned.
    public static func isStillRunning(_ entry: ServerLifecycleEntry) -> Bool {
        guard entry.pid > 0, let recorded = entry.date, let started = startTime(of: entry.pid) else { return false }
        return abs(started.timeIntervalSince(recorded)) <= startTimeTolerance
    }

    /// When the process holding `pid` was launched, straight from the kernel, or `nil` if nothing *live* holds it.
    ///
    /// **A zombie is not a running server, and it is the case that matters here.** A process that has exited but has not been reaped still has a kernel record, a matching pid and a perfectly valid start time — its record reads `p_stat=5 (SZOMB)`. That is the shape a `pkill -9 -f "sift mcp"` leaves: the server dies, and the parent `claude` never reaps it because the parent being wedged is *why* somebody reached for `pkill` in the first place. Without this check `sift status` would tell the next agent `1 running (pid N)` about a corpse whose start time agrees to the second — the false endorsement this whole check exists to remove.
    static func startTime(of pid: Int32) -> Date? {
        guard let record = kernelRecord(of: pid), record.kp_proc.p_stat != SZOMB else { return nil }
        let launched = record.kp_proc.p_un.__p_starttime
        return Date(timeIntervalSince1970: Double(launched.tv_sec) + Double(launched.tv_usec) / 1_000_000)
    }

    /// The pid that spawned this one, straight from the kernel, or `nil` where nothing holds it.
    ///
    /// Read through ``KernelProcess``, the one place in the codebase that reads a kernel process record: a second `sysctl` shaped slightly differently is how two answers about the same process come to disagree.
    public static func parent(of pid: Int32) -> Int32? {
        kernelRecord(of: pid).map(\.kp_eproc.e_ppid)
    }

    /// The state the kernel holds for this pid — `SZOMB` for one that has exited and not been reaped.
    static func processState(of pid: Int32) -> Int32? {
        kernelRecord(of: pid).map { Int32($0.kp_proc.p_stat) }
    }

    private static func kernelRecord(of pid: Int32) -> kinfo_proc? {
        KernelProcess.record(of: pid)
    }

    /// When this machine last booted, which is what separates a killed server from one the machine took with it.
    public static func bootTime() -> Date? {
        var name: [Int32] = [CTL_KERN, KERN_BOOTTIME]
        var booted = timeval()
        var size = MemoryLayout<timeval>.stride
        guard sysctl(&name, UInt32(name.count), &booted, &size, nil, 0) == 0, size > 0 else { return nil }
        return Date(timeIntervalSince1970: Double(booted.tv_sec) + Double(booted.tv_usec) / 1_000_000)
    }
}
