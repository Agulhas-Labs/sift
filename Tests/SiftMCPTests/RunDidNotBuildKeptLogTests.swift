//
// Copyright © Agulhas Labs
//

import ArgumentParser
import Foundation
@testable import SiftCLI
import SiftCore
import Testing

/// A selected run that did not build keeps the raw log its answer names past the runs that follow it, since that log is the only record of what failed beyond the summary.
@Suite(.temporaryDirectories)
struct RunDidNotBuildKeptLogTests {
    /// Driven through `run()`: what is pinned is that the log the `raw:` line names is still there after as many later runs as the count keeps.
    @Test
    func theRawLogADidNotBuildAnswerNamesOutlivesTheNextRuns() throws {
        let directory = try TemporaryDirectory.make("run-did-not-build-kept")
        defer { try? FileManager.default.removeItem(at: directory) }
        let swift = directory.appendingPathComponent("swift")
        try "#!/bin/sh\necho \"Tests/WidgetTests/WidgetTests.swift:3:5: error: cannot find 'Gadget' in scope\"\nexit 1\n"
            .write(to: swift, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: swift.path)
        let recorded = RecordedOutput()
        var command = try RunCommand.parse(["--", swift.path, "test", "--filter", "WidgetTests"])
        command.log = RunUsageLog(fileURL: directory.appendingPathComponent("run.jsonl"))
        command.writesUnder = directory
        command.output = recorded.output

        #expect(throws: ExitCode(RunTestSelector.didNotBuildExitCode)) {
            try command.run()
        }
        let raw = try #require(recorded.printed.split(separator: "\n").first { $0.hasPrefix("raw: ") })
        let named = try #require(raw.dropFirst("raw: ".count).split(separator: " ").first).split(separator: "/").last
        let runs = SiftPaths.cache(in: directory).appendingPathComponent(RunLog.runsDirectoryName, isDirectory: true)
        for _ in 0 ..< RunLog.keptLogs {
            RunLog.open(inDirectory: directory)?.close()
        }

        let names = try FileManager.default.contentsOfDirectory(atPath: runs.path)
        #expect(names.contains(String(named ?? "")), "\(raw) is gone from \(names)")
    }

    /// Transcripts kept because a run did not build are bounded in a pool of their own, so an edit-compile loop never pushes out the one explaining a lost result.
    @Test
    func aRunThatDidNotBuildNeverPushesOutALostResultsLog() throws {
        let directory = try TemporaryDirectory.make("run-did-not-build-pool")
        defer { try? FileManager.default.removeItem(at: directory) }
        let lost = try #require(RunLog.open(inDirectory: directory))
        lost.close()
        let keptLost = try #require(RunLog.keep(lost.url.path))
        for _ in 0 ... RunLog.keptLogs {
            let unbuilt = try #require(RunLog.open(inDirectory: directory))
            unbuilt.close()
            unbuilt.keep(in: .didNotBuild)
        }
        let runs = SiftPaths.cache(in: directory).appendingPathComponent(RunLog.runsDirectoryName, isDirectory: true)
        let names = try FileManager.default.contentsOfDirectory(atPath: runs.path)

        #expect(FileManager.default.fileExists(atPath: keptLost))
        #expect(names.count { $0.hasPrefix(RunLog.KeptPool.didNotBuild.rawValue) } == RunLog.keptLogs)
    }
}
