//
// Copyright © Agulhas Labs
//

import Foundation
import SiftCore

/// `~/.sift/server.jsonl` — one line when a server starts, one when it stops, and the reason it stopped.
///
/// **Why this exists.** An MCP server that drops mid-session leaves no other trace anywhere on the machine. `~/.sift/` holds the usage log, the run log, the roots registry and the advice ledger, and not one of them says anything about a server: `usage.jsonl` stops dead at the moment of a drop, which makes it a witness to *when* but never to *why*. With nothing written down, "did it crash, time out, or get reaped?" has no answer that is not a guess — and a `pkill -f "sift mcp"` from a subagent clearing an unrelated hung process is exactly the kind of thing a line in a file settles in one second and inference never settles at all.
///
/// Bounded on purpose: this is written by a long-lived process, and a diagnostic that grows without limit is a defect of its own. Two lines per server run and a cap of ``entryCap`` keeps a day or more of history in a file small enough to read whole, and a trim keeps the start line of every server still running.
///
/// Nothing here may raise, block, or reach stdout — the same contract as ``SiftCore/JSONLineLog``, and for the stronger reason that this process's stdout is the protocol stream.
public struct ServerLifecycleLog: Sendable {
    /// Entries kept before a trim, which leaves ``entryKeep``.
    ///
    /// Both are counts of whole lines, so a partly written last line cannot cost more than itself.
    static let entryCap = 400
    static let entryKeep = 200

    public let fileURL: URL
    private let log: JSONLineLog

    public init(fileURL: URL, note: @escaping @Sendable (String) -> Void = { _ in }) {
        self.fileURL = fileURL
        log = JSONLineLog(fileURL: fileURL, subject: "server log", note: note)
    }

    /// The shared per-user log, beside the usage log whose gaps it explains.
    public static func standard(note: @escaping @Sendable (String) -> Void = { _ in }) -> ServerLifecycleLog {
        ServerLifecycleLog(fileURL: standardFileURL(), note: note)
    }

    /// `~/.sift/server.jsonl`, or the file `SIFT_SERVER_LOG` names.
    ///
    /// The override is narrow and it earns its place: the one property worth pinning about this file's owner — that the process ends when its input does — is only observable from outside the process, and the test that observes it must not append to the record a human reads to diagnose a real drop. `SIFT_NO_ADVICE` is the existing precedent for reaching the tool this way.
    static func standardFileURL(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        if let path = environment["SIFT_SERVER_LOG"], !path.isEmpty {
            return URL(fileURLWithPath: path)
        }
        return SiftPaths.home.appendingPathComponent("server.jsonl")
    }

    /// Records that a server is now serving, which conversation and directory it is serving, and which process it will end with.
    ///
    /// `parent` is the pid the server's parent watch is armed on, which it must have read before this line exists: an observer takes the line as the sign the server is up, and a parent that dies after that has to be one the server already knew to watch.
    public func recordStart(pid: Int32, session: String?, root: String, parent: Int32? = nil, now: Date = Date()) {
        var entry: [String: Any] = [
            "event": "start",
            "pid": Int(pid),
            "ts": Self.stamp(now),
            "root": root,
            "version": SiftVersion.current,
        ]
        entry["session"] = session
        entry["parent"] = parent.map { Int($0) }
        append(entry)
    }

    /// Records that a server has replaced its own image with the binary now on disk and is serving on from it — the same process, so neither a stop nor a start.
    ///
    /// Written by the new image, once it is running: a line the old image wrote on its way into the exec would claim a replacement that might then fail. The start line stays the one that opened this process, which is also what ``ServerLifecycleReport`` checks the kernel's start time against, and an exec keeps that time. `version` is the new image's, so the line says what the process is running now; `seconds` is how long it had been up.
    public func recordReexec(pid: Int32, startedAt: Date, now: Date = Date()) {
        append([
            "event": "reexec",
            "pid": Int(pid),
            "ts": Self.stamp(now),
            "version": SiftVersion.current,
            "seconds": Int(now.timeIntervalSince(startedAt).rounded()),
        ])
    }

    /// Records that a server has stopped, and why.
    ///
    /// `startedAt` is carried rather than looked up so the entry can say how long the server lasted without a reader having to pair it with its start line — a stop after eleven seconds and one after eleven hours are different findings, and the pairing is the part that goes wrong when pids are reused.
    public func recordStop(pid: Int32, reason: ServerStop, startedAt: Date, now: Date = Date()) {
        var entry: [String: Any] = [
            "event": "stop",
            "pid": Int(pid),
            "ts": Self.stamp(now),
            "reason": reason.reason,
            "seconds": Int(now.timeIntervalSince(startedAt).rounded()),
        ]
        entry["detail"] = reason.detail
        append(entry)
    }

    private func append(_ entry: [String: Any]) {
        log.append(entry)
        trimIfNeeded()
    }

    /// Rewrites the file with its most recent ``entryKeep`` lines, after the start lines of servers still running, once it passes ``entryCap``.
    ///
    /// **The lock is the whole of this, not a precaution.** Once the file is past the cap — which on a busy machine is permanent after a couple of hundred server runs — this read-modify-write runs on *every* append, from every process. Unlocked, a concurrent appender writes at an offset the trim has just invalidated and leaves a NUL hole in the file, and a concurrent reader sees the file half-rewritten and reports no servers running while two are.
    ///
    /// Rewritten in place under the lock rather than through an atomic replace: a rename would put the new bytes on a *different inode*, which every other process's lock is not held on, so the atomicity would be bought by giving up the exclusion. Readers take the shared lock instead (``ServerLifecycleReport/entries(in:)``), which is what makes an in-place rewrite invisible to them.
    ///
    /// Best-effort in the same sense as the append: a log that cannot be trimmed is not a reason to fail a server start, so every failure here is simply dropped.
    private func trimIfNeeded() {
        let descriptor = open(fileURL.path, O_RDWR | O_CLOEXEC)
        guard descriptor >= 0 else { return }
        defer { close(descriptor) }
        // Fails *open*, exactly as the append does. Refusing to trim without a lock would quietly abandon the
        // bound this whole method exists to keep, on the one kind of filesystem where nothing can take a lock;
        // trimming unserialised risks losing entries appended during it, which is a smaller harm in a file
        // whose contents are already a rolling window.
        FileLock.take(descriptor, .exclusive)
        defer { FileLock.release(descriptor) }

        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
        guard let data = try? handle.readToEnd() else { return }
        let lines = data.split(separator: 0x0A, omittingEmptySubsequences: true)
        guard lines.count > Self.entryCap else { return }
        var trimmed = Data()
        for line in Self.liveStarts(among: lines.dropLast(Self.entryKeep), keeping: lines.suffix(Self.entryKeep)) + lines.suffix(Self.entryKeep) {
            trimmed.append(contentsOf: line)
            trimmed.append(0x0A)
        }
        // Written first, truncated after. Truncating first opens a window in which the file is *empty* — and
        // a crash or a full disk inside it destroys every entry rather than the prefix being dropped. This
        // branch makes that window reachable: `recordStop` trims, the signal handler calls `recordStop`, and
        // by then `SIG_DFL` is restored — so a second `pkill` at a hung server could otherwise zero the one
        // file this whole type exists to produce. In this order the worst case is a stale tail.
        guard (try? handle.seek(toOffset: 0)) != nil, (try? handle.write(contentsOf: trimmed)) != nil else { return }
        ftruncate(descriptor, off_t(trimmed.count))
    }

    /// The start lines among `dropped` whose server is still running, oldest first: the newest per pid, and none for a pid a start line in `kept` already names.
    ///
    /// A trim that dropped them would leave a server running with no record of where it was launched or what spawned it, and the `PreToolUse` hook finds the server answering its caller by exactly that line (``CallerRoot/serverDirectory(session:environment:)``); on a busy day the newest ``entryKeep`` lines are little more than a day, and a session can run for days. One per pid keeps the bound: only so many servers run at once.
    static func liveStarts(
        among dropped: ArraySlice<Data.SubSequence>,
        keeping kept: ArraySlice<Data.SubSequence>,
        isRunning: (ServerLifecycleEntry) -> Bool = ServerLifecycleReport.isStillRunning
    ) -> [Data.SubSequence] {
        var named = Set(kept.compactMap { ServerLifecycleReport.entry(from: Data($0)) }.filter { $0.event == "start" }.map(\.pid))
        var live: [Data.SubSequence] = []
        for line in dropped.reversed() {
            guard let entry = ServerLifecycleReport.entry(from: Data(line)), entry.event == "start",
                  !named.contains(entry.pid), isRunning(entry) else { continue }
            named.insert(entry.pid)
            live.append(line)
        }
        return live.reversed()
    }

    /// The one timestamp spelling these entries use, matching the usage log's so the two read side by side.
    static func stamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter.string(from: date)
    }
}
