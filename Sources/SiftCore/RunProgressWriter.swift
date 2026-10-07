//
// Copyright © Agulhas Labs
//

import Foundation

/// Keeps one run's file in `.sift/progress/` current while that wrapped run goes on: throttled, written whole, kept fresh by a heartbeat, and ended exactly once.
///
/// Every method takes one lock and may be called from any thread, a signal source's handler on a dispatch queue included, so a cancelled run can record its outcome from the queue that saw the signal; nothing here assumes Swift concurrency. None of it is async-signal-safe: it allocates and locks, so it is never called from a raw `sigaction` handler.
///
/// A write is best-effort: one that fails is dropped and the run goes on, since the file is a view of the run and never the point of it.
public final class RunProgressWriter: @unchecked Sendable {
    /// The shortest gap between two writes that carry only changed counts.
    public static let throttle: TimeInterval = 0.5

    /// How often an unchanged live snapshot is rewritten, so `updatedAt` stays fresh through a silent link step or a quiet test.
    public static let heartbeat: TimeInterval = 2

    /// How old a live snapshot's `updatedAt` may be before a reader takes its run for dead; well clear of ``heartbeat``.
    public static let staleAfter: TimeInterval = 5

    /// How many run files ``prune(in:keeping:now:)`` leaves when a run begins.
    public static let keptRuns = 5

    /// How fresh a live run's file must be for pruning to spare it whatever its age by name.
    public static let liveWithin: TimeInterval = 10

    /// How often the writer's own timer looks for a held-back change or a due heartbeat.
    static let tickInterval: TimeInterval = 0.25

    private let directory: URL
    private let now: @Sendable () -> Date
    private let runsTimer: Bool
    private let lock = NSLock()
    private var snapshot: RunProgressSnapshot?
    private var runFile: URL?
    private var lastWrite: Date?
    private var dirty = false
    private var phaseEntered: Date?
    private var buildTime: TimeInterval?
    private var testTime: TimeInterval?
    private var timer: (any DispatchSourceTimer)?
    private var writeCount = 0

    /// A writer of run files in `directory` (``RunProgressPaths/directory(in:writesUnder:)``), on the wall clock, with its own timer for held-back changes and the heartbeat.
    public convenience init(directory: URL) {
        self.init(directory: directory, now: { Date() }, runsTimer: true)
    }

    /// A writer whose clock is `now`; `runsTimer` false leaves ``tick()`` to the caller, so a test decides exactly when a held-back change or a heartbeat falls due.
    init(directory: URL, now: @escaping @Sendable () -> Date, runsTimer: Bool) {
        self.directory = directory
        self.now = now
        self.runsTimer = runsTimer
    }

    deinit {
        timer?.cancel()
    }

    /// The current run's file, once ``begin(command:repoRoot:scheme:destination:logPath:tree:runId:pid:)`` has named it.
    public var file: URL? {
        lock.withLock { runFile }
    }

    /// How many snapshots have reached the file.
    var writes: Int {
        lock.withLock { writeCount }
    }

    /// Starts a run: writes its first snapshot, `idle` and uncounted, to a file of its own, prunes the directory, and starts the timer.
    ///
    /// `runId` defaults to one sortable by start (``runId(startingAt:)``); `repoRoot` is recorded with its symlinks resolved.
    public func begin(
        command: String,
        repoRoot: URL,
        scheme: String? = nil,
        destination: String? = nil,
        logPath: String? = nil,
        tree: String? = nil,
        runId: String? = nil,
        pid: Int32 = getpid()
    ) {
        lock.withLock {
            let start = now()
            let runId = runId ?? Self.runId(startingAt: start)
            runFile = RunProgressPaths.file(runId: runId, in: directory)
            snapshot = RunProgressSnapshot(runId: runId, pid: pid, repoRoot: Self.resolved(repoRoot), startedAt: start, command: command, scheme: scheme, destination: destination, logPath: logPath, tree: tree)
            phaseEntered = start
            buildTime = nil
            testTime = nil
            write(at: start)
            Self.prune(in: directory, keeping: Self.keptRuns, now: start)
            startTimer()
        }
    }

    /// A run id that sorts by `start`: UTC to the millisecond, then eight random hex digits against a run started in the same millisecond.
    public static func runId(startingAt start: Date) -> String {
        let stamp = RunProgressSnapshot.stamp(start).filter { $0 != "-" && $0 != ":" && $0 != "." }
        return "\(stamp)-\(String(format: "%08x", UInt32.random(in: 0 ... .max)))"
    }

    /// `url`'s path with every symlink resolved, or its standardised path where the file system cannot resolve it.
    static func resolved(_ url: URL) -> String {
        guard let pointer = realpath(url.path, nil) else { return url.standardizedFileURL.path }
        defer { free(pointer) }
        return String(cString: pointer)
    }

    /// Changes the live snapshot and writes it if the throttle allows; a phase change always writes.
    ///
    /// Only the run's own state is the caller's to change: the run's identity, its start, its outcome and its timings stay the writer's, and a terminal phase set here is ignored, since only ``finish(exitCode:phase:)`` ends a run. Before ``begin(command:repoRoot:scheme:destination:logPath:tree:runId:pid:)`` and after the run has ended this does nothing.
    public func update(_ mutate: (inout RunProgressSnapshot) -> Void) {
        lock.withLock {
            guard let before = snapshot, !before.phase.isTerminal else { return }
            var after = before
            mutate(&after)
            after.schemaVersion = before.schemaVersion
            after.runId = before.runId
            after.pid = before.pid
            after.tree = before.tree
            after.repoRoot = before.repoRoot
            after.startedAt = before.startedAt
            after.phaseStartedAt = before.phaseStartedAt
            after.summary = nil
            after.exitCode = nil
            after.command = RunProgressSnapshot.fitted(after.command)
            if after.phase.isTerminal {
                after.phase = before.phase
            }
            let moment = now()
            if after.phase != before.phase {
                enter(after.phase, at: moment)
                after.phaseStartedAt = moment
            }
            snapshot = after
            if after.phase != before.phase {
                write(at: moment)
            } else if after != before {
                dirty = true
                if let lastWrite, moment.timeIntervalSince(lastWrite) < Self.throttle {
                    return
                }
                write(at: moment)
            }
        }
    }

    /// Ends the run with `exitCode`: `done` for 0 and `failed` otherwise, unless `phase` names a terminal phase itself.
    ///
    /// The first call wins.
    public func finish(exitCode: Int32, phase: RunProgressSnapshot.Phase? = nil) {
        let terminal = phase.flatMap { $0.isTerminal ? $0 : nil } ?? (exitCode == 0 ? .done : .failed)
        lock.withLock {
            end(as: terminal, exitCode: exitCode)
        }
    }

    /// The cleanup that needs no outcome to hand: a run still in flight is written as `failed` with no exit code; an ended run, or none, is left alone.
    public func reset() {
        lock.withLock {
            end(as: .failed, exitCode: nil)
        }
    }

    /// Writes a held-back change once the throttle allows it, or rewrites an unchanged live snapshot once a heartbeat is due.
    ///
    /// The timer calls it; a test with no timer calls it itself.
    func tick() {
        lock.withLock {
            guard let snapshot, !snapshot.phase.isTerminal, let lastWrite else { return }
            let moment = now()
            let since = moment.timeIntervalSince(lastWrite)
            if dirty ? since >= Self.throttle : since >= Self.heartbeat {
                write(at: moment)
            }
        }
    }

    /// Removes the oldest run files in `directory` until `keeping` remain, by name, which sorts by start; a file whose `pid` is alive and whose `updatedAt` is under ``liveWithin`` old is never removed, and nothing but a run file is ever touched.
    ///
    /// Returns the names it removed. A file that cannot be read or decoded is no run's live file, and goes like any other old one.
    @discardableResult
    public static func prune(in directory: URL, keeping: Int, now: Date = Date()) -> [String] {
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? [])
            .filter(RunProgressPaths.isRunFile)
            .sorted(by: >)
        var removed: [String] = []
        for name in names.dropFirst(keeping) {
            let url = directory.appendingPathComponent(name)
            if let data = try? Data(contentsOf: url),
               let snapshot = try? RunProgressSnapshot.decoded(from: data),
               isAlive(snapshot.pid),
               now.timeIntervalSince(snapshot.updatedAt) < liveWithin
            {
                continue
            }
            if (try? FileManager.default.removeItem(at: url)) != nil {
                removed.append(name)
            }
        }
        return removed
    }

    /// Whether a process `pid` exists: one this user may not signal still exists.
    private static func isAlive(_ pid: Int32) -> Bool {
        kill(pid, 0) == 0 || errno == EPERM
    }

    /// Closes the live run as `phase`, timing it, and stops the timer, with the lock held.
    private func end(as phase: RunProgressSnapshot.Phase, exitCode: Int32?) {
        guard var ended = snapshot, !ended.phase.isTerminal else { return }
        let moment = now()
        enter(phase, at: moment)
        ended.phase = phase
        ended.phaseStartedAt = moment
        ended.exitCode = exitCode
        ended.summary = RunProgressSnapshot.Timings(
            buildMs: buildTime.map(Self.milliseconds),
            testMs: testTime.map(Self.milliseconds),
            totalMs: Self.milliseconds(moment.timeIntervalSince(ended.startedAt))
        )
        snapshot = ended
        write(at: moment)
        timer?.cancel()
        timer = nil
    }

    /// Adds the time spent in the phase being left to its total, with the lock held and before `snapshot` takes the new phase.
    private func enter(_ next: RunProgressSnapshot.Phase, at moment: Date) {
        if let phaseEntered, let leaving = snapshot?.phase {
            let spent = moment.timeIntervalSince(phaseEntered)
            switch leaving {
            case .building: buildTime = (buildTime ?? 0) + spent
            case .testing: testTime = (testTime ?? 0) + spent
            case .idle, .done, .failed: break
            }
        }
        phaseEntered = next.isTerminal ? nil : moment
    }

    /// Writes the snapshot stamped `moment`, whole: a temporary beside the file renamed over it, with the lock held.
    private func write(at moment: Date) {
        guard var stamped = snapshot else { return }
        stamped.updatedAt = moment
        snapshot = stamped
        guard let data = try? stamped.encoded(),
              let runFile,
              (try? DurableFile.replace(runFile, with: data, fsync: false, createDirectory: true)) != nil
        else { return }
        lastWrite = moment
        dirty = false
        writeCount += 1
    }

    /// Starts the timer behind ``tick()``, unless this writer leaves ticking to its caller or one is already running, with the lock held.
    ///
    /// The timer runs on a queue of its own: a global queue is given no thread while the process's cores are busy at a higher priority, and the heartbeat is owed then too.
    private func startTimer() {
        guard runsTimer, timer == nil else { return }
        let source = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "sift.run.progress.heartbeat", qos: .utility))
        source.schedule(deadline: .now() + Self.tickInterval, repeating: Self.tickInterval)
        source.setEventHandler { [weak self] in
            self?.tick()
        }
        source.resume()
        timer = source
    }

    private static func milliseconds(_ interval: TimeInterval) -> Int {
        Int((interval * 1000).rounded())
    }
}
