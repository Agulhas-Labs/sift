//
// Copyright © Agulhas Labs
//

import Foundation
import SiftCore
import Testing

/// A `sift run --without` run that did not build keeps the raw log its receipt names past the runs that follow, as a plain run that did not build does.
@Suite(.temporaryDirectories)
struct RunWithoutDidNotBuildKeptLogTests {
    typealias Fixture = RunWithoutCommandTests.Fixture

    /// The run without the change failing to compile its tests is the common shape of a proof whose test names what the fix declares.
    @Test
    func theRawLogOfARunThatDidNotBuildWithoutTheChangeOutlivesTheNextRuns() throws {
        let fixture = try Fixture()
        try standIn(buildingOnlyWithTheFix: true, in: fixture)

        let result = try fixture.sift(Fixture.proof)
        let logs = named(in: result.stdout)
        let without = try #require(logs["without Sources/"], "\(result.stdout)")
        prune(fixture)
        let names = try kept(fixture)

        #expect(names.contains(without), "\(without) is gone from \(names); \(result.stdout)")
    }

    /// The run with the change back is the caller's own tree, and a log of it that did not build is the same only record.
    @Test
    func theRawLogOfARunThatDidNotBuildWithTheChangeOutlivesTheNextRuns() throws {
        let fixture = try Fixture()
        try standIn(buildingOnlyWithTheFix: false, in: fixture)

        let result = try fixture.sift(Fixture.proof)
        let logs = named(in: result.stdout)
        let with = try #require(logs.first { $0.key.hasPrefix("with ") }?.value, "\(result.stdout)")
        prune(fixture)
        let names = try kept(fixture)

        #expect(names.contains(with), "\(with) is gone from \(names); \(result.stdout)")
    }

    /// Replaces the fixture's `swift` with one whose tests do not compile — without the fix only, or in both passes.
    private func standIn(buildingOnlyWithTheFix: Bool, in fixture: Fixture) throws {
        let passes = buildingOnlyWithTheFix
            ? """
            if grep -q fixed Sources/feature.txt; then
                printf 'Test shoutingWorks() passed after 0.001 seconds.\\n'
                printf 'Test run with 1 test in 1 suite passed after 0.001 seconds.\\n'
                exit 0
            fi

            """
            : ""
        let script = """
        #!/bin/sh
        \(passes)echo "Tests/WidgetTests/WidgetTests.swift:3:5: error: cannot find 'Gadget' in scope"
        exit 1

        """
        try script.write(to: fixture.bin.appendingPathComponent("swift"), atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fixture.bin.appendingPathComponent("swift").path)
    }

    /// Each raw log the receipt names, by the file name it stands under, keyed by the run it is named for.
    private func named(in stdout: String) -> [String: String] {
        var logs: [String: String] = [:]
        for match in stdout.matches(of: #/(\S+\.log) \((with(?:out)? [^)]*)\)/#) {
            logs[String(match.output.2)] = match.output.1.split(separator: "/").last.map(String.init)
        }
        return logs
    }

    /// Opens and closes one more plain run than the count that prunes keeps.
    private func prune(_ fixture: Fixture) {
        for _ in 0 ... RunLog.keptLogs {
            RunLog.open(inDirectory: fixture.root)?.close()
        }
    }

    private func kept(_ fixture: Fixture) throws -> [String] {
        let runs = SiftPaths.cache(in: fixture.root).appendingPathComponent(RunLog.runsDirectoryName, isDirectory: true)
        return try FileManager.default.contentsOfDirectory(atPath: runs.path)
    }
}
