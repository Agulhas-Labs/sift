//
// Copyright © Agulhas Labs
//

import ArgumentParser
import Foundation
@testable import SiftCLI
import SiftCore
import Testing

/// Covers what `sift run` prints when there is no honest filtered answer to serve: the raw log, the line introducing it, and the device notes after it.
@Suite(.temporaryDirectories)
struct RunFallbackTests {
    /// A selected build failure with no error line at all serves the raw log, and the line introducing it names the build failure rather than claiming the filter found nothing.
    ///
    /// Driven through `run()` rather than ``RunOutcome/didNotBuildFallbackHeadline(selector:)``, because what is pinned is that the fallback asks: a fallback printing its generic line unconditionally would contradict the exit code 5 the same run ends with.
    @Test
    func aSelectedBuildFailureWithNoErrorLineNamesItselfOverTheRawLog() throws {
        let directory = try TemporaryDirectory.make("run-command-fallback-did-not-build")
        defer { try? FileManager.default.removeItem(at: directory) }
        let swift = try Self.fakeTool(
            named: "swift",
            in: directory,
            printing: """
            Testing cancelled because the build failed.

            Testing failed:
            \tThe following build commands failed:

            ** TEST FAILED **

            """,
            exiting: 65
        )
        let recorded = RecordedOutput()
        var command = try RunCommand.parse(["--", swift.path, "test", "--filter", "WidgetTests"])
        command.log = RunUsageLog(fileURL: directory.appendingPathComponent("run.jsonl"))
        command.writesUnder = directory
        command.output = recorded.output

        #expect(throws: ExitCode(RunTestSelector.didNotBuildExitCode)) {
            try command.run()
        }
        #expect(recorded.errors == ["✘ swift test — did not build — no test ran (the command exited 65; sift run exits 5)"])
        #expect(recorded.printed.contains("Testing cancelled because the build failed."))
    }

    /// The raw-log fallback still prints the device's note, after the log, and counts it in the lines it reports as shown.
    ///
    /// An unreached device is the state whose note prints whatever the failures read, so the note owed here does not depend on the empty-tree detector.
    @Test
    func theRawLogFallbackEndsWithTheDeviceNoteAndCountsIt() throws {
        let directory = try TemporaryDirectory.make("run-command-fallback-note")
        defer { try? FileManager.default.removeItem(at: directory) }
        let xcodebuild = try Self.fakeTool(
            named: "xcodebuild",
            in: directory,
            printing: """
            Testing started
            Testing failed:
            \tTest runner exited before starting test execution.
            ** TEST FAILED **

            """,
            exiting: 65
        )
        let outcome = try RunLauncher(workingDirectory: directory, repositoryRoot: nil, runLogDirectory: directory).run([xcodebuild.path, "test"])
        let report = try #require(outcome.report)
        let device = SimulatorAccessibility.Restoration(udid: "00000000-0000-0000-0000-000000000000", state: .unreached(reason: "no simulator was booted"))
        let note = try #require(device.note(failuresReadEmptyTrees: false))
        let recorded = RecordedOutput()
        var command = try RunCommand.parse(["--", xcodebuild.path, "test"])
        command.output = recorded.output

        let shown = command.report(outcome, workingDirectory: directory, accessibility: [device], bundles: .undetermined, selector: nil)

        #expect(recorded.errors == ["sift run: the filter found nothing that explains the failure — raw output follows."])
        #expect(recorded.printed.hasPrefix("Testing started\n"))
        #expect(recorded.printed.hasSuffix("** TEST FAILED **\n\(note)\n"))
        #expect(shown == report.totalLines + 1)
    }

    /// A stand-in for a real toolchain that prints a fixed transcript and exits with a chosen code, named the way `RunCommandKind` recognises it — by its last path component.
    private static func fakeTool(named name: String, in directory: URL, printing output: String, exiting code: Int32) throws -> URL {
        let payload = directory.appendingPathComponent("transcript.txt")
        try output.write(to: payload, atomically: true, encoding: .utf8)
        let script = directory.appendingPathComponent(name)
        try "#!/bin/sh\ncat '\(payload.path)'\nexit \(code)\n".write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        return script
    }
}
