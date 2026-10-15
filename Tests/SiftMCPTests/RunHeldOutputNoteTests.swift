//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCLI
@testable import SiftCore
import Testing

/// Covers where `sift run` prints the line saying it stopped waiting on output its command left held open: every way an answer goes out carries it, so an agent reading only the filtered answer still sees it.
@Suite(.temporaryDirectories)
struct RunHeldOutputNoteTests {
    private static let held = RunHeldOutput(holders: [RunHeldOutput.Holder(pid: 4242, name: "simctl")])

    /// The filtered answer carries the line under its totals, and counts it.
    @Test
    func theFilteredAnswerCarriesTheNote() throws {
        let directory = try TemporaryDirectory.make("run-held-note-filtered")
        defer { try? FileManager.default.removeItem(at: directory) }
        let swift = try Self.fakeTool(named: "swift", in: directory, printing: "Build complete! (1.00s)\n", exiting: 0)
        let outcome = try Self.holding(RunLauncher(workingDirectory: directory, repositoryRoot: nil, runLogDirectory: directory).run([swift.path, "build"]))
        let recorded = RecordedOutput()
        var command = try RunCommand.parse(["--", swift.path, "build"])
        command.output = recorded.output

        let shown = command.report(outcome, workingDirectory: directory, accessibility: [], bundles: .undetermined, selector: nil)

        #expect(recorded.printed.contains(Self.held.note + "\n"))
        #expect(shown == recorded.printed.split(separator: "\n", omittingEmptySubsequences: false).count - 1)
    }

    /// A command with no filter has its line printed beside the passthrough note.
    @Test
    func thePassthroughNoteIsFollowedByTheHeldNote() throws {
        let directory = try TemporaryDirectory.make("run-held-note-passthrough")
        defer { try? FileManager.default.removeItem(at: directory) }
        let outcome = try Self.holding(RunLauncher(workingDirectory: directory, repositoryRoot: nil, runLogDirectory: directory).run(["sh", "-c", "echo x"]))
        let recorded = RecordedOutput()
        var command = try RunCommand.parse(["--", "sh", "-c", "echo x"])
        command.output = recorded.output

        _ = command.report(outcome, workingDirectory: directory, accessibility: [], bundles: .undetermined, selector: nil)

        #expect(recorded.errors == ["sift run: no filter for this command — output passed through unchanged.", Self.held.note])
    }

    /// The raw-log fallback ends with the line, and counts it among what it showed.
    @Test
    func theRawLogFallbackEndsWithTheNote() throws {
        let directory = try TemporaryDirectory.make("run-held-note-fallback")
        defer { try? FileManager.default.removeItem(at: directory) }
        let xcodebuild = try Self.fakeTool(
            named: "xcodebuild",
            in: directory,
            printing: "Testing started\nTesting failed:\n\tTest runner exited before starting test execution.\n** TEST FAILED **\n",
            exiting: 65
        )
        let outcome = try Self.holding(RunLauncher(workingDirectory: directory, repositoryRoot: nil, runLogDirectory: directory).run([xcodebuild.path, "test"]))
        let report = try #require(outcome.report)
        let recorded = RecordedOutput()
        var command = try RunCommand.parse(["--", xcodebuild.path, "test"])
        command.output = recorded.output

        let shown = command.report(outcome, workingDirectory: directory, accessibility: [], bundles: .undetermined, selector: nil)

        #expect(recorded.printed.hasSuffix("** TEST FAILED **\n\(Self.held.note)\n\(XcodebuildTestDiagnostics.note)\n"))
        #expect(shown == report.totalLines + 2)
    }

    /// `outcome` as a run that stopped waiting on its output would have returned it.
    private static func holding(_ outcome: RunOutcome) -> RunOutcome {
        RunOutcome(
            kind: outcome.kind,
            logKey: outcome.logKey,
            exitCode: outcome.exitCode,
            report: outcome.report,
            log: outcome.log,
            repositoryRoot: outcome.repositoryRoot,
            heldOutput: held
        )
    }

    /// A stand-in for a real toolchain that prints a fixed transcript and exits with a chosen code, named the way `RunCommandKind` recognises it.
    private static func fakeTool(named name: String, in directory: URL, printing output: String, exiting code: Int32) throws -> URL {
        let payload = directory.appendingPathComponent("transcript.txt")
        try output.write(to: payload, atomically: true, encoding: .utf8)
        let script = directory.appendingPathComponent(name)
        try "#!/bin/sh\ncat '\(payload.path)'\nexit \(code)\n".write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        return script
    }
}
