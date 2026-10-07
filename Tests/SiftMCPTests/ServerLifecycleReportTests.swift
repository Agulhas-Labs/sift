//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftMCP
import Testing

/// Covers what `sift status` can say about a server that is not there.
@Suite(.temporaryDirectories)
struct ServerLifecycleReportTests {
    /// A fixed reading time, so what the report says is a property of the entries rather than of the day the suite runs.
    private static var reading: Date {
        Date(timeIntervalSince1970: 1_788_000_000)
    }

    private static func at(_ offset: TimeInterval) -> String {
        ServerLifecycleLog.stamp(Date(timeIntervalSince1970: 1_788_000_000 + offset))
    }

    private static func start(_ pid: Int32, at stamp: String? = nil) -> ServerLifecycleEntry {
        ServerLifecycleEntry(event: "start", pid: pid, stamp: stamp ?? at(-600))
    }

    private static func stop(
        _ pid: Int32,
        reason: String,
        detail: String? = nil,
        seconds: Int? = nil,
        at stamp: String? = nil
    ) -> ServerLifecycleEntry {
        ServerLifecycleEntry(event: "stop", pid: pid, stamp: stamp ?? at(-60), reason: reason, detail: detail, seconds: seconds)
    }

    @Test
    func aStartWithNoStopWhoseProcessIsAliveIsAServerThatIsServing() {
        let text = ServerLifecycleReport.text(entries: [Self.start(101)], bootedAt: Self.reading.addingTimeInterval(-3600), isRunning: { _ in true })

        #expect(text == "mcp servers — 1 running (pid 101)")
    }

    /// The shape only an uncatchable death leaves: it started, it never wrote a stop, and it is not there.
    ///
    /// `SIGKILL` — which is what `pkill -9` sends and what a supervisor reaping a process sends — looks like this and nothing else does.
    @Test
    func aStartWithNoStopWhoseProcessIsGoneIsSaidOutLoud() throws {
        let text = try #require(ServerLifecycleReport.text(
            entries: [Self.start(101)],
            bootedAt: Self.reading.addingTimeInterval(-3600),
            isRunning: { _ in false }
        ))

        #expect(text.contains("none running"))
        #expect(text.contains("never recorded a stop"))
        #expect(text.contains("pid 101"))
        #expect(text.contains("killed outright"))
    }

    /// A start the machine went away underneath is not news; a start something *killed* is, at any age.
    ///
    /// A reboot never lets a server record a stop, so without this every start it interrupted would put a permanent alarm into `sift status`. Boot time answers that exactly. An age window is wrong in the direction that costs — it measures from the *start* stamp, so the long-lived server killed a minute ago, which is precisely the case this branch exists to surface, falls out of the report entirely. The second half of this test is that case, and it is the one that matters.
    @Test
    func aStartFromBeforeThisBootIsNotNewsAndOneAfterItAlwaysIs() throws {
        let booted = Self.reading.addingTimeInterval(-2 * 60 * 60)
        let beforeBoot = Self.start(101, at: Self.at(-3 * 24 * 60 * 60))
        // Ran for thirty hours across the boot line and was killed a minute ago — old, and entirely news.
        let longLived = Self.start(202, at: Self.at(-90 * 60))

        let reboot = try #require(ServerLifecycleReport.text(
            entries: [beforeBoot, Self.stop(303, reason: "input-closed")],
            bootedAt: booted,
            isRunning: { _ in false }
        ))
        let killed = try #require(ServerLifecycleReport.text(
            entries: [longLived],
            bootedAt: booted,
            isRunning: { _ in false }
        ))

        #expect(!reboot.contains("never recorded a stop"))
        #expect(killed.contains("never recorded a stop"))
        #expect(killed.contains("pid 202"))
    }

    /// A zombie is not a running server, and it is the shape a `pkill` leaves behind when the server's parent is too wedged to reap it.
    ///
    /// A process that has exited but has not been reaped keeps a kernel record, its pid, and a perfectly valid start time. The scenario is not hypothetical: a subagent runs `pkill -9 -f "sift mcp"`, the server dies, and the parent never reaps it — because the parent being wedged is *why* somebody reached for `pkill`. Reported as running, that is a corpse the tool vouches for.
    @Test
    func aProcessThatDiedButWasNeverReapedIsNotRunning() {
        var pid: pid_t = 0
        let arguments: [UnsafeMutablePointer<CChar>?] = [strdup("/usr/bin/true"), nil]
        defer { free(arguments[0]) }
        #expect(posix_spawn(&pid, "/usr/bin/true", nil, nil, arguments, environ) == 0)
        defer {
            var status: Int32 = 0
            waitpid(pid, &status, 0)
        }

        // Deliberately not reaped: the child becomes a zombie and stays one until the defer above runs. Its exit is
        // waited on without reaping it, rather than polled for against a clock a loaded machine can outlast.
        var exited = siginfo_t()
        #expect(waitid(P_PID, id_t(pid), &exited, WEXITED | WNOWAIT) == 0)
        let state = ServerLifecycleReport.processState(of: pid)
        let corpse = ServerLifecycleEntry(event: "start", pid: pid, stamp: ServerLifecycleLog.stamp(Date()))

        #expect(state == SZOMB, "the child never became a zombie, so this test proved nothing")
        #expect(!ServerLifecycleReport.isStillRunning(corpse))
    }

    /// The case this exists for, as `sift status` shows it: a live server killed out from under a session by a `pkill` meant for something else.
    @Test
    func aSignalledStopIsReportedWithItsSignal() throws {
        let text = try #require(ServerLifecycleReport.text(
            entries: [Self.start(101), Self.stop(101, reason: "signalled", detail: "SIGTERM", seconds: 7200)],
            bootedAt: Self.reading.addingTimeInterval(-3600),
            isRunning: { _ in false }
        ))

        #expect(text.contains("none running"))
        #expect(text.contains("pid 101 after 2h — signalled (SIGTERM)"))
        // A closed start is closed: it must not also be counted among the ones that vanished.
        #expect(!text.contains("never recorded a stop"))
    }

    @Test
    func aClientHangingUpIsAnOrdinaryEnding() throws {
        let text = try #require(ServerLifecycleReport.text(
            entries: [Self.start(101), Self.stop(101, reason: "input-closed", seconds: 45)],
            bootedAt: Self.reading.addingTimeInterval(-3600),
            isRunning: { _ in false }
        ))

        #expect(text.contains("pid 101 after 45s — input-closed"))
    }

    /// A re-exec neither closes a start nor opens one: the server that replaced its image is still the one running, and its eventual stop closes the start it has always had.
    @Test
    func aReexecLeavesItsServerRunning() throws {
        let reexec = ServerLifecycleEntry(event: "reexec", pid: 101, stamp: Self.at(-300), seconds: 300)
        let running = try #require(ServerLifecycleReport.text(
            entries: [Self.start(101), reexec],
            bootedAt: Self.reading.addingTimeInterval(-3600),
            isRunning: { _ in true }
        ))
        let stopped = ServerLifecycleReport.unclosedStarts(in: [Self.start(101), reexec, Self.stop(101, reason: "input-closed")])

        #expect(running == "mcp servers — 1 running (pid 101)")
        #expect(stopped.isEmpty)
    }

    /// A stop closes the most recent start for *that* pid, so one server ending does not account for another that is still running.
    @Test
    func eachStopClosesOnlyItsOwnServer() throws {
        let text = try #require(ServerLifecycleReport.text(
            entries: [Self.start(101), Self.start(202), Self.stop(101, reason: "input-closed")],
            bootedAt: Self.reading.addingTimeInterval(-3600),
            isRunning: { $0.pid == 202 }
        ))

        #expect(text.contains("1 running (pid 202)"))
        #expect(!text.contains("never recorded a stop"))
    }

    /// A pid is not an identity, and this is the check that says so.
    ///
    /// `kill(pid, 0)` reports only that *something* holds the number. Weeks after a server died, an unrelated process can inherit its pid, and a check on the pid alone would tell an agent whose four tools had just vanished that its server was healthy — the failure the line exists to prevent, carrying the tool's endorsement. Pid 1 has been running since boot, so a start entry claiming it was written moments ago is not describing it.
    @Test
    func aPidHeldBySomethingElseIsNotThisServer() {
        let impostor = ServerLifecycleEntry(event: "start", pid: 1, stamp: ServerLifecycleLog.stamp(Date()))

        #expect(!ServerLifecycleReport.isStillRunning(impostor))
    }

    /// And the other direction, or the check would be useless: this very process, stamped with the start time the kernel reports for it, is recognised as still running.
    @Test
    func aPidWhoseStartTimeAgreesIsThisServer() throws {
        let launched = try #require(ServerLifecycleReport.startTime(of: getpid()))
        let mine = ServerLifecycleEntry(event: "start", pid: getpid(), stamp: ServerLifecycleLog.stamp(launched))

        #expect(ServerLifecycleReport.isStillRunning(mine))
    }

    /// Nothing recorded means nothing to say — `status` does not grow a line that reports an absence of news.
    @Test
    func anEmptyLogSaysNothing() {
        #expect(ServerLifecycleReport.text(entries: [], bootedAt: Self.reading, isRunning: { _ in true }) == nil)
    }

    @Test
    func entriesAreReadBackFromWhatTheLogWrote() throws {
        let directory = try TemporaryDirectory.make("lifecycle-report")
        let fileURL = directory.appendingPathComponent("server.jsonl")
        let log = ServerLifecycleLog(fileURL: fileURL)
        let started = Date(timeIntervalSince1970: 1_000_000)

        log.recordStart(pid: 909, session: nil, root: "/tmp/repo", now: started)
        log.recordStop(pid: 909, reason: .signalled(number: SIGHUP), startedAt: started, now: started.addingTimeInterval(30))
        let read = ServerLifecycleReport.entries(in: fileURL)

        #expect(read.count == 2)
        #expect(read.first?.event == "start")
        #expect(read.last?.reason == "signalled")
        #expect(read.last?.detail == "SIGHUP")
        #expect(read.last?.seconds == 30)
    }

    /// A log that is not there at all is not a failure — it is a machine on which no server has run yet.
    @Test
    func aMissingLogIsNotAFailure() throws {
        let missing = try TemporaryDirectory.make("absent")
            .appendingPathComponent("absent.jsonl")

        #expect(ServerLifecycleReport.entries(in: missing).isEmpty)
        #expect(ServerLifecycleReport.text(fileURL: missing) == nil)
    }
}
