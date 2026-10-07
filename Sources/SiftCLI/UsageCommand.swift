//
// Copyright © Agulhas Labs
//

import ArgumentParser
import Foundation
import SiftCore
import SiftMCP

/// `sift usage` — the adoption review over `~/.sift/usage.jsonl`, one command instead of a jq session.
struct UsageCommand: ParsableCommand {
    static var configuration: CommandConfiguration {
        CommandConfiguration(
            commandName: "usage",
            abstract: "Summarise the index usage log: calls by tool, root, and day, latency, top targets.",
            discussion: """
            The log is per-user, not per-repo, so this reports every repository unless you narrow it. \
            The call count is index lookups, whichever face served them: the MCP tools, digest/where/search/strings \
            run from a shell, and the answers the PreToolUse hook gives in place. Commands wrapped in `sift run` \
            keep their own log and are reported in a section of their own — a wrapped build is not a lookup.
            """
        )
    }

    @Option(name: .customLong("file"), help: "Log file to read (defaults to ~/.sift/usage.jsonl, or the file SIFT_USAGE_LOG names).")
    var file: String?

    @Option(name: .customLong("run-file"), help: "Wrapped-run log to read (defaults to ~/.sift/run.jsonl).")
    var runFile: String?

    @Option(name: .customLong("since"), help: "Only calls on or after this day: today, yesterday, <N>d, or YYYY-MM-DD (UTC, as the log files them).")
    var since: String?

    @Option(name: .customLong("root"), help: "Only calls against this directory and the repositories beneath it — an absolute path, or a unique trailing part of one such as Orchard or Orchard/app.")
    var root: String?

    @Flag(name: .customLong("unredact"), help: "Print the real target, root and failure-reason names. The report is pseudonymised by default, so sharing one is safe unless you say otherwise.")
    var unredact = false

    @Flag(name: .customLong("all-roots"), help: "Print every root in the \"by root\" section, not just the top 5.")
    var allRoots = false

    @Flag(name: .customLong("include-scratch"), help: "Count calls against scratch roots too: temporary directories, ~/Library/Caches and any .build directory. Left out by default, with one line saying how many.")
    var includeScratch = false

    func run() throws {
        let fileURL = file.map { URL(fileURLWithPath: $0) }
            ?? UsageLog.standardFileURL()

        var firstDay: String?
        if let since {
            guard let resolved = UsageWindow.firstDay(from: since, now: Date()) else {
                throw ValidationError("--since \(since) is not a window: use today, yesterday, <N>d, or YYYY-MM-DD.")
            }
            firstDay = resolved
        }
        StandardStreams.emit(UsageReport.render(
            fileURL: fileURL,
            runFileURL: runFile.map { URL(fileURLWithPath: $0) } ?? RunUsageLog.standardFileURL,
            since: firstDay,
            root: root,
            redactor: unredact ? nil : .standard(),
            allRoots: allRoots,
            includeScratch: includeScratch
        ))
    }
}
