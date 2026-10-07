//
// Copyright © Agulhas Labs
//

import ArgumentParser
import Foundation
@testable import SiftCLI
import SiftCore
@testable import SiftMCP
import Testing

/// Covers what `sift servers` will and will not do when asked, which is the part of server cleanup a person drives.
///
/// The guards themselves are pinned in ``ServerRosterTests``. What is pinned here is the command around them: that a stop has to name what it means, that it changes nothing until it is told to, and that a caller who asked for something that did not happen learns so from the exit code rather than by reading prose.
@Suite(.temporaryDirectories)
struct ServersCommandTests {
    /// A stop with nothing named refuses, and refuses at the parse, before a single log is opened.
    ///
    /// **This is the design, not an argument-parsing detail.** A form of this command that reaped whatever it found would be an idle timeout with a person's name on it — the same failure as a server exiting because it was quiet, and the reason the design is not simply "kill the idle ones".
    @Test
    func aStopMustNameWhatItMeans() {
        #expect(Self.refusal(["--stop"])?.contains("needs at least one --pid or a --root") == true)
    }

    /// A root that names the machine is refused too, and that is the same rule rather than a second one.
    ///
    /// `--root /` is a prefix of every absolute path, so one token would have selected every server on the machine. In a cron there is no session id and no shared ancestry, so neither of the other guards would have stood in its way — what remained would have been the bare idle timeout this whole design refuses to build.
    @Test
    func aRootThatNamesTheMachineIsRefused() {
        let home = SiftPaths.userHome().path

        #expect(Self.refusal(["--stop", "--root", "/", "--yes"])?.contains("names this machine") == true)
        #expect(Self.refusal(["--stop", "--root", home, "--yes"])?.contains("names this machine") == true)
        // A directory somebody chose inside their own is a scope, and still parses.
        #expect(Self.refusal(["--stop", "--root", home + "/some-repo", "--yes"]) == nil)
    }

    /// A root that matched nothing exits nonzero, exactly as a pid that matched nothing does.
    @Test
    func aRootThatMatchedNothingExitsNonzero() async throws {
        let log = try Self.log(startedSecondsAgo: 90000, pid: 4646)
        defer { try? FileManager.default.removeItem(at: log.deletingLastPathComponent()) }
        var command = try ServersCommand.parse(["--stop", "--yes", "--root", "/repo/typo", "--file", log.path, "--usage-file", "/dev/null"])
        let signalled = Signalled()
        command.send = { pid in
            signalled.record(pid)
            return nil
        }
        command.isRunning = { _ in true }

        await #expect(throws: ExitCode(1)) {
            try await command.run()
        }

        #expect(signalled.pids.isEmpty)
    }

    /// A stop without `--yes` sends nothing, however eligible the server it names.
    @Test
    func aStopWithoutConsentSendsNothing() async throws {
        let log = try Self.log(startedSecondsAgo: 90000, pid: 4242)
        defer { try? FileManager.default.removeItem(at: log.deletingLastPathComponent()) }
        var command = try ServersCommand.parse(["--stop", "--pid", "4242", "--file", log.path, "--usage-file", "/dev/null"])
        let signalled = Signalled()
        command.send = { pid in
            signalled.record(pid)
            return nil
        }
        command.isRunning = { _ in true }

        try await command.run()

        #expect(signalled.pids.isEmpty)
    }

    /// A stop with `--yes` sends to exactly the server it named.
    @Test
    func aStopWithConsentSendsToTheServerItNamed() async throws {
        let log = try Self.log(startedSecondsAgo: 90000, pid: 4343)
        defer { try? FileManager.default.removeItem(at: log.deletingLastPathComponent()) }
        var command = try ServersCommand.parse(["--stop", "--yes", "--pid", "4343", "--file", log.path, "--usage-file", "/dev/null"])
        let signalled = Signalled()
        command.send = { pid in
            signalled.record(pid)
            return nil
        }
        command.isRunning = { _ in true }

        try await command.run()

        #expect(signalled.pids == [4343])
    }

    /// A pid that was not there is a nonzero exit, because a script reaping by name has to be able to tell.
    @Test
    func askingToStopSomethingThatIsNotThereExitsNonzero() async throws {
        let log = try Self.log(startedSecondsAgo: 90000, pid: 4444)
        defer { try? FileManager.default.removeItem(at: log.deletingLastPathComponent()) }
        var command = try ServersCommand.parse(["--stop", "--yes", "--pid", "5555", "--file", log.path, "--usage-file", "/dev/null"])
        command.send = { _ in nil }
        command.isRunning = { _ in true }

        await #expect(throws: ExitCode(1)) {
            try await command.run()
        }
    }

    /// What parsing these arguments refuses with, or `nil` where it accepts them.
    ///
    /// The refusal is read as the sentence a person sees rather than as a type: a parse wraps a validation failure in ArgumentParser's own error, and what is worth pinning is that the command says why it will not do this — not which envelope the wording arrived in.
    private static func refusal(_ arguments: [String]) -> String? {
        do {
            _ = try ServersCommand.parse(arguments)
            return nil
        } catch {
            return ServersCommand.message(for: error)
        }
    }

    /// A lifecycle log holding one unclosed start, written as the real one writes it.
    private static func log(startedSecondsAgo seconds: TimeInterval, pid: Int32) throws -> URL {
        let directory = try TemporaryDirectory.make("servers")
        let file = directory.appendingPathComponent("server.jsonl")
        ServerLifecycleLog(fileURL: file).recordStart(
            pid: pid,
            session: "another-session",
            root: "/repo",
            now: Date().addingTimeInterval(-seconds)
        )

        return file
    }
}

extension ServersCommandTests {
    /// Records the pids a stop actually reached.
    final class Signalled: @unchecked Sendable {
        private let mutex = NSLock()
        private var seen: [Int32] = []

        var pids: [Int32] {
            mutex.lock()
            defer { mutex.unlock() }
            return seen
        }

        func record(_ pid: Int32) {
            mutex.lock()
            defer { mutex.unlock() }
            seen.append(pid)
        }
    }
}
