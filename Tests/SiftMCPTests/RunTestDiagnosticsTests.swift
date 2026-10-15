//
// Copyright © Agulhas Labs
//

import ArgumentParser
import Foundation
@testable import SiftCLI
@testable import SiftCore
import Testing

/// `sift run` turns off the simulator diagnostics `xcodebuild` collects after a failing test, which it otherwise waits up to ten minutes on before it exits, and says so on a failed run.
@Suite(.temporaryDirectories)
struct RunTestDiagnosticsTests {
    /// Only a test action that does not choose for itself gets the option.
    @Test
    func onlyATestActionThatDoesNotChooseGetsTheOption() {
        let added = ["-collect-test-diagnostics", "never"]
        let test = ["xcodebuild", "test", "-scheme", "Gizmo"]
        let rerun = ["xcodebuild", "test-without-building", "-scheme", "Gizmo"]

        #expect(XcodebuildTestDiagnostics.skipping(test) == test + added)
        #expect(XcodebuildTestDiagnostics.skipping(rerun) == rerun + added)
        for unchanged in [
            ["xcodebuild", "build", "-scheme", "Gizmo"],
            ["xcodebuild", "-scheme", "Gizmo"],
            ["xcodebuild", "test", "-collect-test-diagnostics", "on-failure"],
            ["xcodebuild", "test", "-collect-test-diagnostics=on-failure"],
            ["swift", "test"],
        ] {
            #expect(XcodebuildTestDiagnostics.skipping(unchanged) == unchanged)
        }
    }

    /// A stand-in `xcodebuild` that records the arguments it was started with, prints `output` and exits `code`.
    private static func xcodebuild(in directory: URL, printing output: String, exiting code: Int32) throws -> (script: URL, argv: URL) {
        let payload = directory.appendingPathComponent("transcript.txt")
        let argv = directory.appendingPathComponent("argv.txt")
        try output.write(to: payload, atomically: true, encoding: .utf8)
        let script = directory.appendingPathComponent("xcodebuild")
        try "#!/bin/sh\necho \"$@\" > '\(argv.path)'\ncat '\(payload.path)'\nexit \(code)\n".write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        return (script, argv)
    }

    /// A run of `xcodebuild` from `directory`, what it printed, and what the stand-in was started with.
    private static func run(printing output: String, exiting code: Int32, named: String) throws -> (printed: String, argv: String) {
        let directory = try TemporaryDirectory.make(named)
        defer { try? FileManager.default.removeItem(at: directory) }
        let stand = try xcodebuild(in: directory, printing: output, exiting: code)
        let recorded = RecordedOutput()
        var command = try RunCommand.parse(["--", stand.script.path, "test", "-scheme", "Demo"])
        command.log = RunUsageLog(fileURL: directory.appendingPathComponent("run.jsonl"))
        command.writesUnder = directory
        command.output = recorded.output
        do {
            try command.run()
        } catch is ExitCode {}
        return try (recorded.printed, String(contentsOf: stand.argv, encoding: .utf8))
    }

    /// A failed run is started with collection off and closes on the line saying so.
    @Test
    func aFailedRunIsStartedWithCollectionOffAndSaysSo() throws {
        let result = try Self.run(printing: """
        Test Case '-[WidgetTests.WidgetTests testOne]' started.
        /tmp/WidgetTests.swift:4: error: -[WidgetTests.WidgetTests testOne] : XCTAssertEqual failed: ("2") is not equal to ("3")
        Test Case '-[WidgetTests.WidgetTests testOne]' failed (0.1 seconds).
        ** TEST FAILED **
        """, exiting: 65, named: "run-diagnostics-failed")

        #expect(result.argv == "test -scheme Demo -collect-test-diagnostics never\n")
        #expect(result.printed.contains(XcodebuildTestDiagnostics.note), "\(result.printed)")
    }

    /// A passing run collects nothing either way, so it is started with collection off and says nothing about it.
    @Test
    func aPassingRunSaysNothingAboutCollection() throws {
        let result = try Self.run(printing: """
        Test Case '-[WidgetTests.WidgetTests testOne]' started.
        Test Case '-[WidgetTests.WidgetTests testOne]' passed (0.1 seconds).
        ** TEST SUCCEEDED **
        """, exiting: 0, named: "run-diagnostics-passed")

        #expect(result.argv == "test -scheme Demo -collect-test-diagnostics never\n")
        #expect(!result.printed.contains("collect-test-diagnostics"), "\(result.printed)")
    }
}
