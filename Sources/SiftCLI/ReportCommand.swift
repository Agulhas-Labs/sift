//
// Copyright © Agulhas Labs
//

import ArgumentParser
import Foundation
import SiftCore
import SiftMCP

/// `sift report` — one glanceable page over what already accumulates, written to disk and opened.
///
/// A hosted tool would serve this; this one has no network, no daemon and no account, so the page is a file. Everything on it comes from the usage log, this machine's transcripts, and a read-only probe of the registered indexes — nothing is collected for it.
struct ReportCommand: ParsableCommand {
    static var configuration: CommandConfiguration {
        CommandConfiguration(
            commandName: "report",
            abstract: "Write a self-contained HTML page of conditions, index share, estimated savings and failures, and open it.",
            discussion: """
            Defaults to the last 7 days, matching `audit`: a trend and a repeated-target list need more than one day. \
            Calls come from the per-user log and the index share from this machine's transcripts, so both cover every \
            repository unless you narrow them with --root, which scopes a transcript by the directory it was recorded \
            in. The share is a floor, not a total. The saving is priced against the whole file as its baseline (a \
            located range counts against the file it was cut from), so it leans high. \(TokenEstimate.notMeasured)
            """
        )
    }

    @Option(name: .customLong("since"), help: "Window: today, yesterday, <N>d, or YYYY-MM-DD. Defaults to 7d.")
    var since: String = "7d"

    @Option(name: .customLong("root"), help: "Only calls against this directory and the repositories beneath it, and only transcripts recorded there — an absolute path, or a unique trailing part of one such as Orchard or Orchard/app.")
    var root: String?

    @Option(name: .customLong("out"), help: "Where to write the page (defaults to ~/.sift/report.html, overwritten each run).")
    var out: String?

    @Option(name: .customLong("file"), help: "Usage log to read (defaults to ~/.sift/usage.jsonl, or the file SIFT_USAGE_LOG names).")
    var file: String?

    @Option(name: .customLong("run-file"), help: "Wrapped-run log to read (defaults to ~/.sift/run.jsonl).")
    var runFile: String?

    @Option(name: .customLong("projects"), help: "Transcript directory to scan (defaults to ~/.claude/projects).")
    var projects: String?

    /// Hidden, unlike its two siblings.
    ///
    /// The log and the transcript directory are places a person might genuinely keep elsewhere, where the roots registry is one canonical file the tool maintains itself. This exists so a test can assemble the page without reading — and probing — this machine's real roots.
    @Option(name: .customLong("roots"), help: .hidden)
    var roots: String?

    @Flag(name: .customLong("include-scratch"), help: "Count calls against scratch roots too: temporary directories, ~/Library/Caches and any .build directory (and sessions recorded there). Left out by default, with one line saying how many calls.")
    var includeScratch = false

    @Flag(name: .customLong("no-open"), help: "Write the page without opening it.")
    var noOpen = false

    @Flag(name: .customLong("progress"), help: "Print each stage and the transcript sweep's advance on stderr even when it is not a terminal.")
    var progress = false

    /// Hidden, like `--roots`: where each transcript's counts are kept between runs, so a measurement or a probe can leave the real one alone.
    @Option(name: .customLong("tally-cache"), help: .hidden)
    var tallyCache: String?

    func run() throws {
        let home = SiftPaths.userHome()
        // Validated here so a mistyped window is refused before any transcript is read, and in the same
        // words `usage` and `audit` refuse it — one vocabulary, stated once (UsageWindow).
        guard UsageWindow.firstDay(from: since, now: Date()) != nil else {
            throw ValidationError("--since \(since) is not a window: use today, yesterday, <N>d, or YYYY-MM-DD.")
        }

        let logURL = file.map { URL(fileURLWithPath: $0) }
            ?? UsageLog.standardFileURL()
        let projectsURL = projects.map { URL(fileURLWithPath: $0) }
            ?? home.appendingPathComponent(".claude", isDirectory: true).appendingPathComponent("projects", isDirectory: true)
        let outURL = out.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
            ?? SiftPaths.home.appendingPathComponent("report.html")

        let data = ReportData.assemble(
            logURL: logURL,
            runLogURL: runFile.map { URL(fileURLWithPath: $0) } ?? RunUsageLog.standardFileURL,
            suppressionLogURL: SuppressionLog.standardFileURL,
            projectsDirectory: projectsURL,
            roots: (roots.map { RootsRegistry(fileURL: URL(fileURLWithPath: $0)) } ?? .standard()).currentRoots(),
            since: since,
            root: root,
            includeScratch: includeScratch,
            now: Date(),
            tallyCache: TranscriptTallyCache(fileURL: tallyCache.map { URL(fileURLWithPath: $0) } ?? TranscriptTallyCache.standardFileURL),
            progress: Self.tellsProgress(asked: progress, stderrIsTerminal: isatty(FileHandle.standardError.fileDescriptor) != 0)
                ? { StandardStreams.emitError("report: \($0)") } : { _ in }
        )

        try FileManager.default.createDirectory(at: outURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try ReportPage.render(data).write(to: outURL, atomically: true, encoding: .utf8)
        StandardStreams.emit(outURL.path)

        guard !noOpen else { return }
        let open = Process()
        open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        open.arguments = [outURL.path]
        // A page that could not be opened is still a page that was written, and its path is already on
        // stdout — failing the command here would report a success as a failure.
        try? open.run()
    }

    /// Whether the stages and the sweep's advance go to stderr: on a terminal, where a person is waiting, or when asked — never into a script's or an agent's captured `2>&1` uninvited.
    static func tellsProgress(asked: Bool, stderrIsTerminal: Bool) -> Bool {
        asked || stderrIsTerminal
    }
}
