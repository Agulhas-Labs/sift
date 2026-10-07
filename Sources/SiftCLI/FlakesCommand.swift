//
// Copyright © Agulhas Labs
//

import ArgumentParser
import Foundation
import SiftCore
import SiftMCP

/// `sift flakes` — how often each test has been recorded failing, across every run this machine has wrapped.
///
/// **Its own command rather than a section of `usage`.** `usage` is an adoption review: its headline is a count of index calls, its sections are per tool, per root, per day, and the wrapped runs already sit at the bottom behind a heading whose whole job is to stop a run being read as a lookup. A per-test failure history is a third meaning under that headline and an unbounded listing under a report meant to be read whole — and, more decisively, it is asked at a different moment. `usage` is a review somebody runs to see how the tool is doing; this is asked mid-debug, of one failure, right now: *has this failed before?* A question with that cadence gets a command.
///
/// **Named for the question, not for the answer** — the same split ``RunFailureShape`` makes between what a thing is called and what it is allowed to claim. "Flakes" is the word somebody reaches for when they have this problem, so it is what the command has to be called to be found at all; what it prints is counts, the population they are over, and a line saying they are not a diagnosis. The command name is the question. The output never answers more of it than the log can.
struct FlakesCommand: ParsableCommand {
    static var configuration: CommandConfiguration {
        CommandConfiguration(
            commandName: "flakes",
            abstract: "Count how often each test has been recorded failing across wrapped runs.",
            discussion: """
            Reads the wrapped-run log and reports, for every test that has both failed and passed, how \
            many of the recorded runs named it and when one last did. Only runs that recorded which \
            tests failed are counted; runs written before the log kept them, passed through unfiltered, \
            or failed for a reason the filter could not explain are reported as unknown rather than as \
            runs where nothing failed. Tests that failed and passed on the same tree content under the same command line come first; \
            tests that failed only on trees they never passed on, as a deliberate red does, come second; \
            runs recorded without a tree are listed apart, as unknown. The counts say which tests have \
            failed inconsistently — never why.
            """
        )
    }

    @Option(name: .customLong("file"), help: "Wrapped-run log to read (defaults to ~/.sift/run.jsonl).")
    var file: String?

    @Option(name: .customLong("since"), help: "Only runs on or after this day: today, yesterday, <N>d, or YYYY-MM-DD (UTC, as the log files them).")
    var since: String?

    @Option(name: .customLong("root"), help: "Only runs in this directory and the repositories beneath it, and in every worktree of those repositories wherever it was cut — an absolute path, or a unique trailing part of one such as Orchard or Orchard/app.")
    var root: String?

    @Flag(name: .customLong("unredact"), help: "Print the real test and root names. The report is pseudonymised by default, so sharing one is safe unless you say otherwise.")
    var unredact = false

    func run() throws {
        var firstDay: String?
        if let since {
            guard let resolved = UsageWindow.firstDay(from: since, now: Date()) else {
                throw ValidationError("--since \(since) is not a window: use today, yesterday, <N>d, or YYYY-MM-DD.")
            }
            firstDay = resolved
        }
        StandardStreams.emit(RunFailureHistoryReport.render(
            fileURL: file.map { URL(fileURLWithPath: $0) } ?? RunUsageLog.standardFileURL,
            since: firstDay,
            root: root,
            redactor: unredact ? nil : .standard()
        ))
    }
}
