//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCLI
import Testing

/// Covers the `report` subcommand's contract: where it writes, what it refuses, and that it can be told not to open anything.
@Suite(.temporaryDirectories)
struct ReportCommandTests {
    /// `--no-open` writes the page and stops there, which is the only way this command can be run without a browser appearing — including from a test.
    @Test
    func noOpenWritesThePageAndOpensNothing() throws {
        let directory = try TemporaryDirectory.make("report-cmd")
        let log = directory.appendingPathComponent("usage.jsonl")
        try #"{"tool":"digest","target":"Widget","root":"/repo/a","ms":9,"ok":true,"ts":"2026-08-14T10:00:00Z"}"#
            .write(to: log, atomically: true, encoding: .utf8)
        let out = directory.appendingPathComponent("nested").appendingPathComponent("report.html")

        // Every input is pointed at this directory, the roots registry included: left on the standard one
        // the page would be assembled from — and its repositories probed against — whatever this machine
        // happens to have indexed, which is neither repeatable nor the test's business. `--run-file` is
        // here for the same reason: left off, the run section is assembled from the real
        // `~/.sift/run.jsonl` of whichever machine runs the suite.
        let command = try ReportCommand.parse([
            "--no-open",
            "--file", log.path,
            "--run-file", directory.appendingPathComponent("no-runs.jsonl").path,
            "--projects", directory.appendingPathComponent("no-transcripts").path,
            "--roots", directory.appendingPathComponent("no-roots.json").path,
            "--out", out.path,
        ])
        #expect(command.noOpen)
        try command.run()

        let page = try String(contentsOf: out, encoding: .utf8)
        #expect(page.hasPrefix("<!doctype html>"))
        #expect(page.hasSuffix("</html>"))
    }

    /// The window defaults to a week, matching `audit`: a trend and a repeated-target list need more than one day.
    @Test
    func theWindowDefaultsToAWeek() throws {
        let command = try ReportCommand.parse([])

        #expect(command.since == "7d")
        #expect(!command.noOpen)
    }

    /// A window this vocabulary does not know is refused before any transcript is read, in the same words `usage` and `audit` refuse it.
    @Test
    func anUnknownWindowIsRefused() throws {
        let command = try ReportCommand.parse(["--since", "last tuesday", "--no-open"])

        #expect(throws: (any Error).self) {
            try command.run()
        }
    }

    /// The sweep's advance goes to a terminal, or wherever `--progress` asks, and never uninvited into a captured stderr.
    @Test
    func progressIsToldOnATerminalOrWhenAsked() throws {
        #expect(ReportCommand.tellsProgress(asked: false, stderrIsTerminal: true))
        #expect(ReportCommand.tellsProgress(asked: true, stderrIsTerminal: false))
        #expect(!ReportCommand.tellsProgress(asked: false, stderrIsTerminal: false))
        #expect(try ReportCommand.parse(["--progress"]).progress)
    }
}
