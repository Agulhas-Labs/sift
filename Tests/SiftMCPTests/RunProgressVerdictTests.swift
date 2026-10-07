//
// Copyright © Agulhas Labs
//

import ArgumentParser
import Foundation
@testable import SiftCLI
import SiftCore
import Testing

/// Covers how a run's progress file ends: on sift's own verdict and exit code, naming the log the answer names, where sift's verdict is not the wrapped command's.
@Suite(.temporaryDirectories)
struct RunProgressVerdictTests {
    /// A selected run that did not build exits 5 and moves its log into the did-not-build pool; the file ends `failed` with 5 and names the log where it now is.
    @Test
    func aRunThatDidNotBuildEndsOnSiftsCodeAndNamesTheKeptLog() throws {
        let directory = try TemporaryDirectory.make("progress-verdict-unbuilt")
        let swift = try Self.fakeSwift(in: directory, printing: "Tests/WidgetTests/WidgetTests.swift:3:5: error: cannot find 'Gadget' in scope", exiting: 1)
        let (printed, thrown) = try Self.run([swift.path, "test", "--filter", "WidgetTests"], in: directory)

        #expect(thrown == ExitCode(RunTestSelector.didNotBuildExitCode))
        let ended = try #require(Self.snapshots(in: directory).first)
        #expect(ended.phase == .failed)
        #expect(ended.exitCode == RunTestSelector.didNotBuildExitCode)
        let logPath = try #require(ended.logPath)
        #expect(FileManager.default.fileExists(atPath: logPath), "\(logPath)")
        let raw = try #require(printed.split(separator: "\n").first { $0.hasPrefix("raw: ") })
        let named = try #require(raw.dropFirst("raw: ".count).split(separator: " ").first?.split(separator: "/").last)
        #expect(URL(fileURLWithPath: logPath).lastPathComponent == String(named), "\(raw)")
    }

    /// A selected run that matched no test exits 0 under the command and 4 under sift; the file ends `failed` with 4, not `done` with 0.
    @Test
    func aRunThatMatchedNoTestEndsFailedWithSiftsCode() throws {
        let directory = try TemporaryDirectory.make("progress-verdict-no-match")
        let zero = """
        Test Suite 'Selected tests' started at 2026-10-02 06:49:41.667.
        Test Suite 'Selected tests' passed at 2026-10-02 06:49:41.668.
        \t Executed 0 tests, with 0 failures (0 unexpected) in 0.000 (0.001) seconds
        """
        let swift = try Self.fakeSwift(in: directory, printing: zero, exiting: 0)
        let (_, thrown) = try Self.run([swift.path, "test", "--filter", "GadgetTests"], in: directory)

        #expect(thrown == ExitCode(RunTestSelector.exitCode))
        let ended = try #require(Self.snapshots(in: directory).first)
        #expect(ended.phase == .failed)
        #expect(ended.exitCode == RunTestSelector.exitCode)
        #expect(ended.logPath.map { FileManager.default.fileExists(atPath: $0) } == true)
    }
}

private extension RunProgressVerdictTests {
    /// Runs `sift run -- <command>` in this process with its writes scoped under `directory`, returning what it printed and the exit it threw.
    static func run(_ command: [String], in directory: URL) throws -> (String, ExitCode?) {
        let recorded = RecordedOutput()
        var run = try RunCommand.parse(["--"] + command)
        run.log = RunUsageLog(fileURL: directory.appendingPathComponent("run.jsonl"))
        run.writesUnder = directory
        run.output = recorded.output
        run.environment[RunProgress.switchName] = nil
        do {
            try run.run()
            return (recorded.printed, nil)
        } catch let exit as ExitCode {
            return (recorded.printed, exit)
        }
    }

    /// A `swift` that prints `output` and exits `code`.
    static func fakeSwift(in directory: URL, printing output: String, exiting code: Int32) throws -> URL {
        let payload = directory.appendingPathComponent("transcript.txt")
        try (output + "\n").write(to: payload, atomically: true, encoding: .utf8)
        let script = directory.appendingPathComponent("swift")
        try "#!/bin/sh\ncat '\(payload.path)'\nexit \(code)\n".write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        return script
    }

    /// Every run file the scoped run wrote, newest first.
    static func snapshots(in directory: URL) throws -> [RunProgressSnapshot] {
        let progress = RunProgressPaths.directory(in: directory, writesUnder: directory)
        let names = try FileManager.default.contentsOfDirectory(atPath: progress.path).filter(RunProgressPaths.isRunFile).sorted(by: >)
        return try names.map { try RunProgressSnapshot.decoded(from: Data(contentsOf: progress.appendingPathComponent($0))) }
    }
}
