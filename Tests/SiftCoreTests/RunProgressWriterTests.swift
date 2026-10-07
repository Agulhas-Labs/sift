//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// Covers the writer behind `.sift/progress.json`: whole writes under a concurrent reader, the throttle, the heartbeat, and how a run ends.
@Suite(.temporaryDirectories)
struct RunProgressWriterTests {
    private static var runId: String {
        "20260921T141320000Z-0000abcd"
    }

    private static let root = URL(fileURLWithPath: "/")

    /// A writer with no timer on `clock`, and the file its run (begun with ``runId``) writes.
    private func writer(_ clock: HandClock) throws -> (RunProgressWriter, URL) {
        let directory = try TemporaryDirectory.make("run-progress")
        return (RunProgressWriter(directory: directory, now: { clock.now }, runsTimer: false), RunProgressPaths.file(runId: Self.runId, in: directory))
    }

    private func read(_ file: URL) throws -> RunProgressSnapshot {
        try RunProgressSnapshot.decoded(from: Data(contentsOf: file))
    }

    /// A reader polling the file while two hundred snapshots land on it never sees a partial, empty or missing one: each write is a temporary renamed into place.
    @Test
    func aConcurrentReaderOnlyEverSeesWholeSnapshots() async throws {
        let clock = HandClock()
        let (writer, file) = try writer(clock)
        writer.begin(command: "swift test", repoRoot: Self.root, runId: Self.runId)
        let tally = ReaderTally()
        let reader = Task.detached {
            while !tally.isStopped {
                tally.record(readable: (try? RunProgressSnapshot.decoded(from: Data(contentsOf: file))) != nil)
            }
        }
        while tally.reads == 0 {
            try await Task.sleep(for: .milliseconds(1))
        }
        let bulk = String(repeating: "x", count: 64 * 1024)
        for index in 0 ..< 200 {
            clock.advance(RunProgressWriter.throttle)
            writer.update {
                $0.tests.passed = index
                $0.current = "\(index)\(bulk)"
            }
        }
        tally.stop()
        await reader.value

        #expect(writer.writes == 201)
        #expect(tally.reads > 1)
        #expect(tally.unreadable == 0)
        #expect(try read(file).tests.passed == 199)
    }

    /// Ten changes inside a hundred milliseconds reach the file once; a phase change and the finish each write at once whatever the throttle says.
    @Test
    func theThrottleHoldsBackCountsButNeverAPhaseChangeOrTheFinish() throws {
        let clock = HandClock()
        let (writer, file) = try writer(clock)
        writer.begin(command: "swift test", repoRoot: Self.root, runId: Self.runId)
        clock.advance(1)
        let before = writer.writes

        for index in 1 ... 10 {
            writer.update { $0.tests.passed = index }
            clock.advance(0.01)
        }

        #expect(writer.writes == before + 1)
        #expect(try read(file).tests.passed == 1)

        writer.update { $0.phase = .testing }

        #expect(writer.writes == before + 2)
        #expect(try read(file).phase == .testing)

        writer.finish(exitCode: 0)

        #expect(writer.writes == before + 3)
        #expect(try read(file).phase == .done)
        #expect(try read(file).tests.passed == 10)
    }

    /// A change the throttle held back reaches the file on the first tick after the window, so the last counts are never lost to it.
    @Test
    func aHeldBackChangeIsFlushedOnceTheWindowPasses() throws {
        let clock = HandClock()
        let (writer, file) = try writer(clock)
        writer.begin(command: "swift build", repoRoot: Self.root, runId: Self.runId)
        writer.update { $0.errors = 3 }
        writer.tick()

        #expect(try read(file).errors == 0)

        clock.advance(RunProgressWriter.throttle)
        writer.tick()

        #expect(try read(file).errors == 3)
    }

    /// With nothing changing, a live run still rewrites the file every heartbeat, so a silent step never looks like a dead run.
    @Test
    func anUnchangedLiveRunIsRewrittenEachHeartbeat() throws {
        let clock = HandClock()
        let (writer, file) = try writer(clock)
        writer.begin(command: "swift build", repoRoot: Self.root, runId: Self.runId)
        let started = try read(file).updatedAt

        clock.advance(RunProgressWriter.heartbeat - 0.25)
        writer.tick()

        #expect(try read(file).updatedAt == started)

        clock.advance(0.25)
        writer.tick()

        #expect(try read(file).updatedAt == clock.now)
        #expect(clock.now.timeIntervalSince(started) < RunProgressWriter.staleAfter)
    }

    /// The finish times each phase from the writer's own phase changes and records the outcome; a second finish, from whichever path lost the race, changes nothing.
    @Test
    func finishTimesThePhasesAndTheFirstCallWins() throws {
        let clock = HandClock()
        let (writer, file) = try writer(clock)
        writer.begin(command: "xcodebuild test -scheme App", repoRoot: Self.root, scheme: "App", runId: Self.runId)
        clock.advance(1)
        writer.update { $0.phase = .building }
        clock.advance(2)
        writer.update { $0.phase = .testing }

        #expect(try read(file).phaseStartedAt == clock.now)

        clock.advance(3)
        DispatchQueue.global().sync {
            writer.finish(exitCode: 130, phase: .failed)
        }
        let writes = writer.writes

        writer.finish(exitCode: 0)

        let ended = try read(file)

        #expect(writer.writes == writes)
        #expect(ended.phase == .failed)
        #expect(ended.exitCode == 130)
        #expect(ended.summary == RunProgressSnapshot.Timings(buildMs: 2000, testMs: 3000, totalMs: 6000))
        #expect(ended.phaseStartedAt == ended.startedAt + 6)
    }

    /// `reset` closes a run still in flight as failed with no exit code, leaves an ended run's outcome alone, and writes nothing the second time.
    @Test
    func resetEndsALiveRunOnceAndLeavesAnEndedOneAlone() throws {
        let clock = HandClock()
        let (writer, file) = try writer(clock)
        writer.begin(command: "swift test", repoRoot: Self.root, runId: Self.runId)
        writer.update { $0.phase = .building }
        writer.reset()
        let afterFirst = writer.writes
        writer.reset()

        #expect(writer.writes == afterFirst)
        #expect(try read(file).phase == .failed)
        #expect(try read(file).exitCode == nil)

        writer.begin(command: "swift test", repoRoot: Self.root, runId: Self.runId)
        writer.finish(exitCode: 0)
        let finished = try Data(contentsOf: file)
        writer.reset()

        #expect(try Data(contentsOf: file) == finished)
        #expect(try read(file).phase == .done)
        #expect(try read(file).exitCode == 0)
    }

    /// Pruning keeps the newest run files by name, spares an old one whose process is alive and whose file is fresh, and touches nothing that is not a run file.
    @Test
    func pruneKeepsTheNewestAndSparesALiveRun() throws {
        let directory = try TemporaryDirectory.make("run-progress-prune")
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        let ids = (0 ..< 8).map { "20260921T1413\($0)0000Z-0000abcd" }
        for (index, id) in ids.enumerated() {
            var snapshot = RunProgressSnapshot(runId: id, pid: getpid(), repoRoot: "/", startedAt: now - 100, command: "swift test")
            snapshot.updatedAt = index == 0 ? now - 1 : now - 60
            try snapshot.encoded().write(to: RunProgressPaths.file(runId: id, in: directory))
        }
        let bystanders = [".run-\(ids[1]).json.42.tmp", "notes.txt"]
        for name in bystanders {
            try Data("x".utf8).write(to: directory.appendingPathComponent(name))
        }

        let removed = RunProgressWriter.prune(in: directory, keeping: 5, now: now)

        let left = try Set(FileManager.default.contentsOfDirectory(atPath: directory.path))

        #expect(Set(removed) == Set(ids[1 ... 2].map { "run-\($0).json" }))
        #expect(left == Set(([ids[0]] + ids[3...]).map { "run-\($0).json" } + bystanders))
    }

    /// Two runs writing into one directory at once each keep a file of their own, and neither's begin prunes the other's live file.
    @Test
    func twoWritersInOneDirectoryNeverTouchEachOther() throws {
        let clock = HandClock()
        let directory = try TemporaryDirectory.make("run-progress-pair")
        let first = RunProgressWriter(directory: directory, now: { clock.now }, runsTimer: false)
        let second = RunProgressWriter(directory: directory, now: { clock.now }, runsTimer: false)
        first.begin(command: "swift test", repoRoot: Self.root)
        second.begin(command: "swift build", repoRoot: Self.root)
        for index in 1 ... 20 {
            clock.advance(RunProgressWriter.throttle)
            first.update { $0.tests.passed = index }
            second.update { $0.errors = index * 2 }
        }
        first.finish(exitCode: 0)

        let firstRead = try read(#require(first.file))
        let secondRead = try read(#require(second.file))

        #expect(first.file != second.file)
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).count(where: RunProgressPaths.isRunFile) == 2)
        #expect(firstRead.runId != secondRead.runId)
        #expect(firstRead.phase == .done && firstRead.tests.passed == 20 && firstRead.errors == 0)
        #expect(secondRead.phase == .idle && secondRead.errors == 40 && secondRead.tests.passed == 0)
    }

    /// Run ids sort by start, and the recorded repository root has its symlinks resolved.
    @Test
    func runIdsSortByStartAndTheRootIsResolved() throws {
        let start = Date(timeIntervalSince1970: 1_790_000_000)
        let earlier = RunProgressWriter.runId(startingAt: start)
        let later = RunProgressWriter.runId(startingAt: start + 0.001)
        let base = try TemporaryDirectory.make("run-progress-root")
        let real = base.appendingPathComponent("real", isDirectory: true)
        let link = base.appendingPathComponent("link")
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)

        let resolved = RunProgressWriter.resolved(link)

        #expect(earlier.hasPrefix("20260921T141320000Z-"))
        #expect(earlier < later)
        #expect(resolved.hasSuffix("/real"))
        #expect(resolved == RunProgressWriter.resolved(real))
    }

    /// The command is carried on one line and never past the contract's limit.
    @Test
    func theCommandIsOneLineWithinTheLimit() throws {
        let clock = HandClock()
        let (writer, file) = try writer(clock)
        writer.begin(command: "swift test \\\n  --filter " + String(repeating: "a", count: 300), repoRoot: Self.root, runId: Self.runId)

        let command = try read(file).command

        #expect(command.count == RunProgressSnapshot.commandLimit)
        #expect(!command.contains("\n"))
        #expect(command.hasSuffix("…"))
    }

    /// The writer's own timer still beats while every core of the process is busy at a higher priority, as in a parallel test run: a global queue would get no thread then.
    @Test
    func theTimerBeatsWhileTheProcessIsBusy() throws {
        let clock = HandClock()
        let directory = try TemporaryDirectory.make("run-progress")
        let writer = RunProgressWriter(directory: directory, now: { clock.now }, runsTimer: true)
        writer.begin(command: "swift build", repoRoot: Self.root, runId: Self.runId)
        defer { writer.reset() }
        let cores = ProcessInfo.processInfo.activeProcessorCount
        let spinners = Spinners()
        defer { spinners.stop() }
        spinners.start(cores * 2)
        let busyBy = Date() + 1
        while spinners.running < cores, Date() < busyBy {
            Thread.sleep(forTimeInterval: 0.01)
        }
        let before = writer.writes

        clock.advance(RunProgressWriter.heartbeat)
        let beatBy = Date() + 2
        while writer.writes == before, Date() < beatBy {
            Thread.sleep(forTimeInterval: 0.01)
        }

        #expect(writer.writes > before, "no heartbeat within 2 s while \(spinners.running) of \(cores * 2) spinners held the cores")
    }
}

extension RunProgressWriterTests {
    /// A clock a test moves by hand, so the throttle and the heartbeat fall due exactly when the test says.
    private final class HandClock: @unchecked Sendable {
        private let lock = NSLock()
        private var moment = Date(timeIntervalSince1970: 1_790_000_000)

        var now: Date {
            lock.withLock { moment }
        }

        func advance(_ seconds: TimeInterval) {
            lock.withLock { moment += seconds }
        }
    }

    /// Work that keeps the process's cores busy on the global queue at a higher priority than the writer's timer, until stopped.
    private final class Spinners: @unchecked Sendable {
        private let lock = NSLock()
        private var stopped = false
        private var started = 0

        var running: Int {
            lock.withLock { started }
        }

        /// Starts `count` spinners; each looks at the stop flag only every hundred thousand turns, so the lock never parks it.
        func start(_ count: Int) {
            for _ in 0 ..< count {
                DispatchQueue.global(qos: .userInitiated).async { [self] in
                    lock.withLock { started += 1 }
                    var turns = 0
                    while turns % 100_000 != 0 || !lock.withLock({ stopped }) {
                        turns &+= 1
                    }
                }
            }
        }

        func stop() {
            lock.withLock { stopped = true }
        }
    }

    /// What a reader on another thread saw, and the flag that stops it.
    private final class ReaderTally: @unchecked Sendable {
        private let lock = NSLock()
        private var stopped = false
        private var readCount = 0
        private var unreadableCount = 0

        var reads: Int {
            lock.withLock { readCount }
        }

        var unreadable: Int {
            lock.withLock { unreadableCount }
        }

        var isStopped: Bool {
            lock.withLock { stopped }
        }

        func stop() {
            lock.withLock { stopped = true }
        }

        func record(readable: Bool) {
            lock.withLock {
                readCount += 1
                unreadableCount += readable ? 0 : 1
            }
        }
    }
}
