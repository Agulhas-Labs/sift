//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// Covers the live runner every restore spawns through: what it brings back, and — the property this exists for — that it always comes back.
///
/// These are the only cases in the suite that spawn a real child, because the claim is about processes and pipes and nothing short of a real one can carry it. Nothing here spawns `simctl` or touches a device: `/bin/sh` and `/bin/sleep` stand in for it, which is enough, since what is bounded is the spawn and not the tool inside it. Every child is ended before the case returns and asserted gone, so the suite leaves nothing running behind it.
@Suite(.temporaryDirectories)
struct SimulatorSpawnTests {
    /// What a child said on both streams, and whether it succeeded, comes back as it was.
    ///
    /// The standard error is the half the state machine reads to tell a domain nobody has written from a device nobody can reach, so a runner that dropped it — as this one did, into `nullDevice` — makes those two unanswerable.
    @Test
    func aChildsOutputAndItsStandardErrorBothComeBack() throws {
        let said = try SimulatorAccessibility.spawn("/bin/sh", ["-c", "echo one; echo two >&2"])

        #expect(said.succeeded)
        #expect(said.standardOutput == "one\n")
        #expect(said.standardError == "two\n")

        let failed = try SimulatorAccessibility.spawn("/bin/sh", ["-c", "echo Invalid device: 1 >&2; exit 148"])

        #expect(!failed.succeeded)
        #expect(failed.standardError == "Invalid device: 1\n")
    }

    /// A child that will not end is ended, and the call that gave up on it returns inside its own deadline plus the grace an ended child gets.
    ///
    /// **`sift run` has already printed nothing and is holding the caller's exit code when this runs.** A wedged simulator or a hung `CoreSimulator` service is exactly the case where the wrapped command has finished and the wrapper has not, which is the one failure of this feature nobody can work around — so the bound is the property, and the reason in the answer is how the state machine hears about it.
    @Test
    func aChildThatOutlivesItsDeadlineIsEndedAndSaysSo() throws {
        let file = try TemporaryDirectory.make("spawn-deadline").appendingPathComponent("pid")

        let started = Date()
        let said = try SimulatorAccessibility.spawn("/bin/sh", ["-c", "echo $$ > \(file.path); exec sleep 30"], deadline: 0.5)
        let elapsed = Date().timeIntervalSince(started)

        #expect(elapsed < 1.5)
        #expect(!said.succeeded)
        #expect(said.standardError.contains("timed out"))
        #expect(said.standardError.contains("did not finish within 0.5s"))
        #expect(try Self.isGone(recordedIn: file))
    }

    /// A child that ignores `SIGTERM` is killed rather than waited on, and is gone by the time the call returns.
    ///
    /// `trap '' TERM` before an `exec` is the one-process way to write this: an *ignored* disposition survives an exec where a handler would be reset, so what the deadline meets is a single `sleep` that will not take the polite signal — and no grandchild for the suite to leave behind.
    @Test
    func aChildThatIgnoresThePoliteSignalIsKilled() throws {
        let file = try TemporaryDirectory.make("spawn-kill").appendingPathComponent("pid")

        let started = Date()
        let said = try SimulatorAccessibility.spawn("/bin/sh", ["-c", "echo $$ > \(file.path); trap '' TERM; exec sleep 30"], deadline: 0.5)
        let elapsed = Date().timeIntervalSince(started)

        #expect(elapsed < 1.5)
        #expect(!said.succeeded)
        #expect(try Self.isGone(recordedIn: file))
    }

    /// A grandchild holding the pipe open does not extend the wait: the child's own exit ends it, and what has arrived is what comes back.
    ///
    /// This is why the pipes are drained as they fill rather than read to end of file. `readDataToEndOfFile` waits for the *write end* to close, and a backgrounded grandchild inherited it — so a runner built on it would sit here for thirty seconds over a child that exited in five milliseconds, with its deadline already spent. What this one pays instead is the rest of its own deadline, which is the bound it promised.
    @Test
    func aGrandchildHoldingThePipeDoesNotExtendTheWait() throws {
        let file = try TemporaryDirectory.make("spawn-grandchild").appendingPathComponent("pid")

        let started = Date()
        let said = try SimulatorAccessibility.spawn("/bin/sh", ["-c", "sleep 30 & echo $! > \(file.path); echo done"], deadline: 0.5)
        let elapsed = Date().timeIntervalSince(started)

        #expect(elapsed < 1.5)
        #expect(said.succeeded)
        #expect(said.standardOutput == "done\n")

        // The suite started it, so the suite ends it: a thirty-second sleep is not something to leave behind.
        try Self.end(recordedIn: file)
    }
}

private extension SimulatorSpawnTests {
    /// The pid a child wrote into `file` as it started.
    static func pid(recordedIn file: URL, sourceLocation: SourceLocation = #_sourceLocation) throws -> pid_t {
        let text = try String(contentsOf: file, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        return try #require(pid_t(text), sourceLocation: sourceLocation)
    }

    /// Whether the process that wrote its pid into `file` is gone — signal 0 asks exactly that and sends nothing.
    static func isGone(recordedIn file: URL, sourceLocation: SourceLocation = #_sourceLocation) throws -> Bool {
        try kill(pid(recordedIn: file, sourceLocation: sourceLocation), 0) != 0
    }

    /// Ends a process this test's own child left behind, so the suite leaves nothing running.
    static func end(recordedIn file: URL, sourceLocation: SourceLocation = #_sourceLocation) throws {
        try kill(pid(recordedIn: file, sourceLocation: sourceLocation), SIGKILL)
    }
}
