//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftMCP
import Testing

/// Covers the half of the orphaned-server problem that a server can decide for itself: it ends when the process that spawned it does.
///
/// **Why the first of these is a subprocess test.** The property is about what happens to a *process* when another process dies, and no in-process assertion can see it — the same reason ``ServerExitTests`` is shaped this way. The arrangement it builds is an orphan's: a client end still open, nothing being said on it, and a parent that can be killed on its own. Only the last of those three differs from an ordinary idle session, and it is the whole of what this mechanism acts on.
///
/// The rest are in-process, and they cover the two edges the subprocess test cannot reach on demand: a parent that is already gone at the instant the watch is armed, and a watch that must fire exactly once however many paths reach it.
@Suite(.serialized, .temporaryDirectories)
struct ServerParentExitTests {
    /// A server whose parent is killed exits, and the log says that is why.
    ///
    /// The client end is held open across every assertion, so `input-closed` is not available as an explanation: what is pinned is that the server acted on the parent's death and on nothing else.
    @Test
    func theServerExitsWhenTheProcessThatSpawnedItDoes() throws {
        let binary = try #require(BuiltExecutable.sift, "no `sift` built beside the test bundle, at \(BuiltExecutable.expected.path)")
        let directory = try TemporaryDirectory.make("parent")
        let log = directory.appendingPathComponent("server.jsonl")

        // A shell that stays alive as the server's parent rather than exec'ing into it: `& wait` is what
        // keeps the two pids apart, and `<&0` is what keeps the server's input on the test's pipe — a
        // backgrounded command with no explicit redirection is given /dev/null instead.
        let wrapper = Process()
        wrapper.executableURL = URL(fileURLWithPath: "/bin/sh")
        wrapper.arguments = ["-c", "'\(binary.path)' mcp <&0 & wait"]
        var environment = ProcessInfo.processInfo.environment
        environment["SIFT_SERVER_LOG"] = log.path
        environment["SIFT_USAGE_LOG"] = directory.appendingPathComponent("usage.jsonl").path
        environment["SIFT_ADVICE_DIR"] = directory.appendingPathComponent("advice").path
        wrapper.environment = environment
        let toServer = Pipe()
        wrapper.standardInput = toServer
        wrapper.standardOutput = Pipe()
        wrapper.standardError = Pipe()
        try wrapper.run()

        let start = try #require(Self.wait(forEventIn: log, event: "start"), "the server never recorded a start")
        // A failing run of this test is a run that has just produced the very orphan it is about, and an
        // orphan is a subprocess test's mess to clear whichever way the assertions go.
        defer {
            if ServerLifecycleReport.isStillRunning(start) {
                kill(start.pid, SIGKILL)
            }
        }
        // The start line is the only sign the server is up, so the parent it will watch has to be settled by the
        // time the line exists: a kill from here on must land on a pid the server already knows. Read after the
        // line, a parent killed in between reads as launchd and nothing is watched at all. What this can see is
        // the pid the line records; that the same pid is the one watched is held by `ServerParentWatch.arm`
        // taking its parent with no default, so the watch cannot quietly read its own later.
        #expect(start.parent == wrapper.processIdentifier, "the start line does not name the process that spawned the server as its parent")
        // Killed outright, so nothing it might have done on the way out — closing the pipe, passing the
        // signal on — can stand in for the fact under test.
        kill(wrapper.processIdentifier, SIGKILL)
        let stop = try #require(Self.wait(forEventIn: log, event: "stop"), "the server outlived the process that spawned it")

        #expect(stop.reason == "parent-exited")
        #expect(stop.detail == "parent pid \(wrapper.processIdentifier)")
        #expect(stop.pid == start.pid)
        // And it is really gone, rather than having merely written a line. The line is written before the
        // exit, so the exit is waited for on the kernel's notice rather than assumed to have happened by the
        // time the line is read; once it has, nothing running holds this pid.
        #expect(Self.waitForExit(of: start), "the server recorded its stop and went on running")
        #expect(!ServerLifecycleReport.isStillRunning(start))
        // The client end was open for every one of those assertions. Held explicitly, because a handle
        // released early would close the pipe and hand the exit a second explanation.
        withExtendedLifetime(toServer) {}
        try? FileManager.default.removeItem(at: directory)
    }

    /// A parent that dies in the window before the source is live is still noticed.
    ///
    /// The race is a real one and cannot be produced on demand — it is a handful of instructions wide — so the second reading of the parent is what is exercised here, standing for the instant it covers. Firing once is asserted in the same test rather than in one of its own: the two paths only conflict when both are reachable, which is exactly this arrangement.
    ///
    /// Whether the source's own firing came and went is read off the queue it runs on, never off a clock: a probe watching the same process on the same serial queue proves the exit has reached that queue, and a barrier behind it drains what the watch's source was handed with it.
    @Test
    func aParentAlreadyGoneWhenTheWatchIsArmedIsNoticedAnyway() throws {
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/bin/sleep")
        child.arguments = ["30"]
        try child.run()
        let tally = Tally()
        let queue = DispatchQueue(label: "parent-watch")
        let probe = Tally()
        let probeSource = DispatchSource.makeProcessSource(identifier: child.processIdentifier, eventMask: .exit, queue: queue)
        probeSource.setEventHandler { probe.record() }
        probeSource.resume()

        let source = ServerParentWatch.arm(
            parent: child.processIdentifier,
            queue: queue,
            parentIsUnchanged: { _ in false },
            handle: { _ in tally.record() }
        )

        #expect(tally.recorded == 1, "a parent already gone when the watch was armed was never noticed")
        // Now let the source itself fire. It must find the claim already taken: a server that recorded one
        // stop and exited must not record a second on its way out.
        kill(child.processIdentifier, SIGKILL)
        child.waitUntilExit()
        #expect(probe.wait(seconds: 30), "the exit never reached the watch's queue")
        queue.sync {}
        #expect(tally.recorded == 1, "the watch fired twice for one parent")
        withExtendedLifetime((source, probeSource)) {}
    }

    /// The kernel's own notice arrives — this is the mechanism, exercised without a server around it.
    @Test
    func theWatchFiresWhenTheWatchedProcessExits() throws {
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/bin/sleep")
        child.arguments = ["30"]
        try child.run()
        let tally = Tally()
        let source = ServerParentWatch.arm(
            parent: child.processIdentifier,
            parentIsUnchanged: { _ in true },
            handle: { _ in tally.record() }
        )

        kill(child.processIdentifier, SIGKILL)
        child.waitUntilExit()

        #expect(tally.wait(seconds: 10), "no exit notice arrived for a process that exited")
        withExtendedLifetime(source) {}
    }

    /// Nothing is armed where there is no parent worth watching, and nothing is reported either.
    ///
    /// A process already re-parented to the system before it started has no fact available to it: the pid it would watch belongs to the machine, and waiting for that to exit is not a thing this process lives to see. Reporting it as a dead parent would end every such server the moment it began.
    @Test
    func aProcessWithNoParentToWatchArmsNothing() {
        let tally = Tally()

        for pid in [pid_t(0), pid_t(1)] {
            let source = ServerParentWatch.arm(parent: pid, parentIsUnchanged: { _ in false }, handle: { _ in tally.record() })
            #expect(source == nil)
        }

        #expect(tally.recorded == 0)
    }

    /// Whether the process `entry` records exits, on the kernel's own notice of it rather than after an interval.
    ///
    /// The watch is live before the process is looked at, so an exit at any instant is seen by one or the other; `seconds` bounds a process that never exits and is not how long anything is expected to take.
    private static func waitForExit(of entry: ServerLifecycleEntry, seconds: Int = 30) -> Bool {
        let exited = Tally()
        let source = DispatchSource.makeProcessSource(identifier: entry.pid, eventMask: .exit, queue: .global())
        source.setEventHandler { exited.record() }
        source.resume()
        defer { source.cancel() }
        guard ServerLifecycleReport.isStillRunning(entry) else { return true }

        return exited.wait(seconds: seconds)
    }

    /// The first entry of `event` the log at `fileURL` records, or `nil` if none arrives in time.
    private static func wait(forEventIn fileURL: URL, event: String, seconds: Int = 30) -> ServerLifecycleEntry? {
        let deadline = Date() + Double(seconds)
        while Date() < deadline {
            if let found = ServerLifecycleReport.entries(in: fileURL).last(where: { $0.event == event }) {
                return found
            }
            usleep(20000)
        }

        return nil
    }
}

extension ServerParentExitTests {
    /// Counts calls from the watch's queue, and lets a test wait for the first without polling a variable across threads.
    final class Tally: @unchecked Sendable {
        private let mutex = NSLock()
        private let arrived = DispatchSemaphore(value: 0)
        private var calls = 0

        var recorded: Int {
            mutex.lock()
            defer { mutex.unlock() }
            return calls
        }

        func record() {
            mutex.lock()
            calls += 1
            mutex.unlock()
            arrived.signal()
        }

        func wait(seconds: Int) -> Bool {
            arrived.wait(timeout: .now() + Double(seconds)) == .success
        }
    }
}
