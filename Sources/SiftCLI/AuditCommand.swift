//
// Copyright © Agulhas Labs
//

import ArgumentParser
import Foundation
import SiftCore
import SiftMCP

/// `sift audit` — the adoption review the usage log cannot give you, taken from the transcripts.
struct AuditCommand: ParsableCommand {
    static var configuration: CommandConfiguration {
        CommandConfiguration(
            commandName: "audit",
            abstract: "Audit Claude Code transcripts for Swift lookups the index could have served but didn't.",
            discussion: """
            The usage log records the calls the index served and is blind to the reads that happened \
            instead, so it can say how often the tool was used but never how often it should have been. \
            This reads the transcripts, which hold both sides, and names the misses: first touches of a \
            Swift file with no index call locating it first. Reads that a digest sent you to are reported \
            separately and not counted against the index. Subagent transcripts are included — they are \
            where the heaviest whole-file reading happens. The saving lines are estimates, stated gross: see \
            `sift report --help` for what they are measured against. \(TokenEstimate.notMeasured)
            """
        )
    }

    @Option(name: .customLong("since"), help: "Only lookups made on or after this day, in local time: today, yesterday, <N>d, or YYYY-MM-DD. Defaults to 7d. Ignored with --transcript.")
    var since: String?

    @Option(name: .customLong("until"), help: "Only lookups made before this day (exclusive), same grammar as --since: today, yesterday, <N>d, or YYYY-MM-DD. With --all, an upper bound on its own. Ignored with --transcript.")
    var until: String?

    @Flag(name: .customLong("all"), help: "Audit every transcript regardless of age, overriding --since.")
    var all = false

    @Option(name: .customLong("transcript"), help: "Audit one transcript and its subagents, instead of every session.")
    var transcript: String?

    @Option(name: .customLong("projects"), help: "Transcript directory to scan (defaults to ~/.claude/projects).")
    var projects: String?

    @Option(name: .customLong("root"), help: "Only transcripts and calls whose recorded cwd is this directory or lies beneath it — an absolute path already seen in the logs, or a unique trailing part of one such as Orchard or Orchard/app. With --scan-diff, both scans read only those transcripts. Not yet honoured by --replay or --shapes, which stay unscoped: give one or the other.")
    var root: String?

    @Flag(name: .customLong("unredact"), help: "Print the real file, project, symbol and root names, and with --replay the real calls behind each still-cold shape. The report is pseudonymised by default, so sharing one is safe unless you say otherwise.")
    var unredact = false

    @Flag(name: .customLong("replay"), help: "Also put every call in a sample of the window's sessions (see --sample) to the advice hook as it stands now, and report what share the index would reach: the cold lookups it would answer in place, those it would still let through, and those whose directory is gone.")
    var replay = false

    @Option(name: .customLong("shapes"), help: "With --replay, write every shape of every still-cold rule with its count, and every structure its calls fall in, nothing summed, to this file — with the real calls behind each shape under --unredact. The report itself keeps the ten commonest shapes.")
    var shapes: String?

    @Option(name: .customLong("against"), help: "With --scan-diff, compare this build's scan with this other sift binary's (see --scan-diff). With --replay, put every call to this other sift binary's hook too, in the same replay, and list only the calls the two judge differently — grouped as its rule → this one's, redacted as --shapes redacts them — and the replayed share's denominator where the two differ, in place of the replay section; for this the binary needs the replay-hook entry point, as --scan-diff needs scan-dump.")
    var against: String?

    @Flag(name: .customLong("scan-diff"), help: "With --against, run this build's scan and the other binary's over one snapshot of the transcripts, in place of the audit, over every transcript in the window or, with --root, those the audit would keep, and list each window the two class differently — up to 100 a group, all with --all-windows — grouped as its class → this one's, with each window's file, session, call and the call that located its file under each — and how many of all the windows differ, with both scans' guided and cold totals. The two scans run at once; where they differ, both run again, and a window a build classed differently between its own two runs is listed apart as unstable (live index state) and left out of the count. The binary needs the scan-dump entry point.")
    var scanDiff = false

    @Flag(name: .customLong("all-windows"), help: "With --scan-diff, list every window that moved class, in place of the first 100 of each group.")
    var allWindows = false

    @Flag(name: .customLong("summary"), help: "Print only the summary — the share, the not-worth rows and the refusal accounting — and drop the worst-cold-transcripts list, what the searches were reaching for, the files opened cold in more than one context, and the footnotes. With --replay, the replay section is cut to its own share line and, without --against, its per-day rows; with --against, to the differ count, one line per rule → rule transition (rows that only carry a different (logged) rule fold into one), the denominator line, and the replayed share — every per-transition shape list and structure block is dropped either way. With --against, the audit's own body is left out too: the output is the window, the comparison, a share: unchanged or share: moved +x.y line to gate on, and the command that prints the audit body.")
    var summary = false

    @Flag(name: .customLong("share"), help: "Print only two lines: the headline share (served by sift) and the voluntary share (the indexed lookups the advice hook did not answer, out of the indexed and the cold), each with its fraction, for comparing --root and --since windows in a script. Drops every other row, list and footnote, and --summary's; refuses --replay.")
    var share = false

    @Option(name: .customLong("sample"), help: "With --replay, replay sessions, each with all its subagents, until this many contexts (a session or a subagent each) are replayed, the session that reaches it kept whole; sessions are taken in the order of a digest of each one's file name, so two runs over one window replay the same ones, and the report says how many it left out. Defaults to \(Self.defaultSample), a few minutes' replay even with --against. 0 replays every session: about 10 minutes over a week of sessions, nearly 4 times that with --against.")
    var sample: Int?

    @Flag(name: .customLong("progress"), help: "Print the transcript scan's advance (a count every 50 sessions) and, with --replay, each session replayed and the time taken so far, on stderr as on a terminal, even when stderr is not one.")
    var progress = false

    var output: CommandOutput = .standard

    func validate() throws {
        if sample != nil, !replay {
            throw ValidationError("--sample bounds the contexts --replay replays: add --replay.")
        }
        if let sample, sample < 0 {
            throw ValidationError("--sample \(sample) is not a number of contexts: give 0 for every session, or how many contexts to replay.")
        }
        if shapes != nil, !replay {
            throw ValidationError("--shapes lists the replay's still-cold shapes: add --replay.")
        }
        if share, replay {
            throw ValidationError("--share prints the audit's two share lines and has no replay form: drop --replay.")
        }
        if scanDiff, against == nil {
            throw ValidationError("--scan-diff compares this build's scan with another binary's: name it with --against.")
        }
        if scanDiff, replay {
            throw ValidationError("--scan-diff compares the two scans in place of the audit, and has no replay form: drop --replay.")
        }
        if allWindows, !scanDiff {
            throw ValidationError("--all-windows lifts --scan-diff's cap on the windows it lists: add --scan-diff.")
        }
        if against != nil, !replay, !scanDiff {
            throw ValidationError("--against compares the replay's verdicts with another binary's: add --replay.")
        }
        if root != nil, replay || shapes != nil {
            throw ValidationError("--root doesn't reach --replay yet, which puts every call in the window to the hook regardless of root: drop --replay (and --shapes, which depends on it) or --root.")
        }
        if let shapes {
            let directory = URL(fileURLWithPath: shapes).deletingLastPathComponent()
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory), isDirectory.boolValue,
                  FileManager.default.isWritableFile(atPath: directory.path)
            else {
                throw ValidationError("--shapes \(shapes) needs a writable directory: \(directory.path) doesn't exist or isn't writable.")
            }
        }
    }

    func run() throws {
        let started = Date()
        let directory = projects.map { URL(fileURLWithPath: $0) }
            ?? SiftPaths.userHome()
            .appendingPathComponent(".claude", isDirectory: true)
            .appendingPathComponent("projects", isDirectory: true)

        if transcript != nil {
            let ignored = [since != nil ? "--since" : nil, until != nil ? "--until" : nil].compactMap(\.self)
            if !ignored.isEmpty {
                output.emitError("audit: \(ignored.joined(separator: " and ")) ignored with --transcript, which audits that one transcript regardless of age.")
            }
        }

        let sinceValue = since ?? "7d"
        var start: Date?
        if !all, transcript == nil {
            guard let resolved = UsageWindow.start(from: sinceValue, now: Date()) else {
                throw ValidationError("--since \(sinceValue) is not a window: use today, yesterday, <N>d, or YYYY-MM-DD.")
            }
            start = resolved
        }

        var end: Date?
        if transcript == nil, let until {
            guard let resolved = UsageWindow.start(from: until, now: Date()) else {
                throw ValidationError("--until \(until) is not a window: use today, yesterday, <N>d, or YYYY-MM-DD.")
            }
            end = resolved
        }
        if let start, let end, end <= start {
            throw ValidationError("--until \(until ?? "") is not after --since \(sinceValue): the window would be empty.")
        }

        let interruptions = ReplayInterruptions()
        if replay || scanDiff {
            interruptions.arm()
        }
        if scanDiff, let against {
            let scopedRoot = try Self.scopedRoot(root, knownRoots: RootsRegistry.standard().knownRoots(), unredact: unredact)
            try scanDiff(against: against, projectsDirectory: directory, since: start, until: end, root: scopedRoot, interruptions: interruptions)
            return
        }
        var againstBinary: URL?
        if let against {
            let binary = URL(fileURLWithPath: against)
            guard FileManager.default.isExecutableFile(atPath: binary.path) else {
                throw ValidationError("--against \(against) is not an executable file: name a sift binary.")
            }
            guard ExternalReplayHook.isSupported(by: binary, interruptions: interruptions) else {
                throw ValidationError("--against \(against) has no replay-hook entry point, which it judges each call through: build it from a revision that has one.")
            }
            // Both binaries answer from the same per-repository stores, and each drops and rebuilds a store at another
            // schema version, or another resolution fingerprint, on open, so two versions would rebuild every live
            // store the window touches, in turn.
            let own = ReadOnlyIndex.schemaVersion
            let stamps: ExternalReplayHook.IndexStamps
            switch ExternalReplayHook.schemaVersion(of: binary, interruptions: interruptions) {
            case let .stamps(found):
                stamps = found
            case .wroteNoIndex:
                throw ValidationError("--against \(against) did not show which index schema it keeps: it wrote no index for an empty repository. A binary at another schema than this build's (\(own)) would rebuild every live index the replay touches, and this build would rebuild each one back, so nothing is replayed: name a sift binary that can index.")
            case let .setupFailed(reason):
                throw ValidationError("--against \(against) could not be probed for its index schema: \(reason). Name a sift binary this build can probe.")
            }
            guard stamps.schema == own else {
                throw ValidationError("--against \(against) keeps its index at schema \(stamps.schema), this build at \(own): the two would rebuild every live index the replay touches, each at its own version, on every call, so nothing is replayed. Compare two builds at one schema: build the other on top of the schema change, or this one from before it.")
            }
            guard stamps.fingerprint == stamps.ownFingerprint else {
                throw ValidationError("--against \(against) keeps its index at resolution fingerprint \(stamps.fingerprint ?? "none"), this build at \(stamps.ownFingerprint): the two would rebuild every live index the replay touches, each attributing files its own way, on every call, so nothing is replayed. Compare two builds whose resolution logic agrees.")
            }
            againstBinary = binary
        }
        let knownRoots = RootsRegistry.standard().knownRoots()
        let scopedRoot = try Self.scopedRoot(root, knownRoots: knownRoots, unredact: unredact)
        // One snapshot for both passes: the replay runs minutes after the audit, over transcripts live sessions are still
        // writing, and read afresh it would count lookups the audit never saw.
        let snapshot = TranscriptSnapshot.take(projectsDirectory: directory, since: start, transcript: transcript)
        defer { snapshot.indexes.close() }
        let bounds = Self.replayBounds(
            sample: sample,
            progressAsked: progress,
            stderrIsTerminal: isatty(FileHandle.standardError.fileDescriptor) != 0,
            output: output
        )
        let (report, shapesText) = Self.report(
            snapshot: snapshot,
            projectsDirectory: directory,
            since: start,
            until: end,
            transcript: transcript,
            roots: scopedRoot.map { [$0] } ?? knownRoots,
            root: scopedRoot,
            unredacted: unredact,
            replay: replay,
            against: againstBinary,
            suppressionLog: SuppressionLog.standardFileURL,
            interruptions: interruptions,
            summary: summary,
            window: Self.windowArguments(sinceValue: sinceValue, until: until, all: all, transcript: transcript),
            shareOnly: share,
            usageLog: UsageLog.standardFileURL(),
            sample: bounds.sample,
            progress: bounds.progress
        )
        StandardStreams.emit(replay && summary ? report + "\n" + Self.elapsedLine(Date().timeIntervalSince(started)) : report)
        if let shapes, let shapesText {
            try Data(shapesText.utf8).write(to: URL(fileURLWithPath: shapes))
        }
    }

    /// The audit over `snapshot`, with the replay section after it where `replay`, and the replay's full shape list — both passes read that one snapshot, and the replay prints the audit's own counts as the audit's.
    ///
    /// `sample` bounds the sessions replayed, and `progress` is told the transcript scan's advance and each session replayed, for printing on stderr; neither changes the report.
    ///
    /// The snapshot is taken once, before either pass, because the replay runs minutes after the audit over transcripts live sessions are still writing: read afresh, it would count lookups the audit never saw. Every other argument is `render`'s or `replaySection`'s, read as they read it.
    static func report(
        snapshot: TranscriptSnapshot,
        projectsDirectory: URL,
        since: Date?,
        until: Date? = nil,
        transcript: String? = nil,
        roots: [String] = [],
        root: String? = nil,
        unredacted: Bool = false,
        replay: Bool = false,
        against: URL? = nil,
        suppressionLog: URL? = nil,
        interruptions: ReplayInterruptions? = nil,
        scratch: URL? = nil,
        timeBudget: TimeInterval = HookReplay.timeBudget,
        summary: Bool = false,
        window: String = "--since 7d",
        shareOnly: Bool = false,
        usageLog: URL? = nil,
        sample: ReplaySample = .everySession,
        progress: @escaping (String) -> Void = { _ in }
    ) -> (report: String, shapes: String?) {
        guard replay else {
            let text = TranscriptAudit.render(
                projectsDirectory: projectsDirectory,
                since: since,
                until: until,
                transcript: transcript,
                roots: roots,
                redactor: unredacted ? nil : .standard(),
                root: root,
                suppressionLog: suppressionLog,
                snapshot: snapshot,
                summary: summary,
                shareOnly: shareOnly,
                usageLog: usageLog,
                progress: progress
            )
            return (text, nil)
        }
        let audit = TranscriptAudit.renderWithTallies(
            projectsDirectory: projectsDirectory,
            snapshot: snapshot,
            since: since,
            until: until,
            roots: roots,
            redactor: unredacted ? nil : .standard(),
            root: root,
            suppressionLog: suppressionLog,
            summary: summary,
            usageLog: usageLog,
            transcript: transcript,
            progress: progress
        )
        let sections = replaySections(
            projectsDirectory: projectsDirectory,
            since: since,
            until: until,
            transcript: transcript,
            unredacted: unredacted,
            against: against,
            scratch: scratch,
            timeBudget: timeBudget,
            suppressionLog: suppressionLog,
            interruptions: interruptions,
            snapshot: snapshot,
            audited: audit.tallies,
            summary: summary,
            sample: sample,
            progress: progress
        )
        let shapes = sections.shapes.joined(separator: "\n") + "\n"
        guard summary, against != nil else {
            return (audit.text + "\n" + sections.report.joined(separator: "\n"), shapes)
        }
        return (againstSummary(sections.report, window: window), shapes)
    }

    /// The window as the command line gave it, for a line that names the command to run for the rest.
    static func windowArguments(sinceValue: String, until: String?, all: Bool, transcript: String?) -> String {
        if let transcript {
            return "--transcript \(transcript)"
        }
        return (all ? "--all" : "--since \(sinceValue)") + (until.map { " --until \($0)" } ?? "")
    }

    /// The `--against --summary` report: the window, the comparison, and the command that prints the audit body the comparison leaves out.
    static func againstSummary(_ comparison: [String], window: String) -> String {
        let lines = ["audit --replay against another binary, window \(window)"] + comparison
            + ["  the audit body: sift audit --replay \(window) --summary"]
        return lines.joined(separator: "\n")
    }

    /// The one directory `--root` resolves to against `knownRoots`, or `nil` where none was given — refusing an unmatched or ambiguous argument with the registered roots spelled as `--unredact` allows.
    static func scopedRoot(_ argument: String?, knownRoots: [String], unredact: Bool) throws -> String? {
        guard let argument else { return nil }
        switch LogScope.resolve(argument, among: Set(knownRoots)) {
        case let .success(scope):
            return scope.path
        case let .failure(.rootUnmatched(argument, roots)):
            throw ValidationError("--root \(argument) matches no registered root. Registered roots:\n"
                + LogScope.spellings(of: roots, redacted: !unredact).map { "  \($0)" }.joined(separator: "\n"))
        case let .failure(.rootAmbiguous(argument, matches)):
            throw ValidationError("--root \(argument) matches \(matches.count) registered roots — name one:\n"
                + LogScope.spellings(of: matches, redacted: !unredact).map { "  \($0)" }.joined(separator: "\n"))
        case .failure(.missingOrEmpty), .failure(.unreadable):
            return nil
        }
    }

    /// The replay section, run against a hook whose state lives in a scratch directory of this run's own, removed when it is done, with the real calls behind each still-cold shape where `unredacted`, and every shape of every still-cold rule written to `shapesFile` where one is named, against `snapshot` where one is handed and one taken here otherwise.
    static func replaySection(
        projectsDirectory: URL,
        since: Date?,
        until: Date? = nil,
        transcript: String?,
        unredacted: Bool = false,
        shapesFile: URL? = nil,
        scratch: URL? = nil,
        timeBudget: TimeInterval = HookReplay.timeBudget,
        roots: RootDiscovery = RootDiscovery(),
        against: URL? = nil,
        againstEnvironment: [String: String]? = nil,
        suppressionLog: URL? = nil,
        snapshot: TranscriptSnapshot? = nil
    ) throws -> [String] {
        let sections = Self.replaySections(
            projectsDirectory: projectsDirectory,
            since: since,
            until: until,
            transcript: transcript,
            unredacted: unredacted,
            against: against,
            againstEnvironment: againstEnvironment,
            scratch: scratch,
            timeBudget: timeBudget,
            roots: roots,
            suppressionLog: suppressionLog,
            snapshot: snapshot
        )
        if let shapesFile {
            try Data((sections.shapes.joined(separator: "\n") + "\n").utf8).write(to: shapesFile)
        }
        return sections.report
    }

    /// The replay's report and full shape list, run against a hook whose state lives in a scratch directory of this run's own, removed when it is done — writing what `--shapes` names is left to the caller, so a report already built survives a write that fails.
    ///
    /// `snapshot` is the one the audit beside it was rendered from, so both count the same bytes of the same transcripts, and `audited` is that audit's own counts, printed as its share beside the replayed one.
    ///
    /// Where `against` names another binary, every call is put to its hook too, with state of its own in the same scratch directory, and the report is the comparison of the two. `suppressionLog` is the log the audit beside it read, so the two score a call the hook let run as `notSmaller`, `linesNotShown` or `otherStatementsRun` alike. The scratch directory, and each child the other binary is run as, are recorded in `interruptions` while they last, so a signal that ends the run removes and stops them.
    private static func replaySections(
        projectsDirectory: URL,
        since: Date?,
        until: Date? = nil,
        transcript: String?,
        unredacted: Bool = false,
        against: URL? = nil,
        againstEnvironment: [String: String]? = nil,
        scratch: URL? = nil,
        timeBudget: TimeInterval = HookReplay.timeBudget,
        roots: RootDiscovery = RootDiscovery(),
        suppressionLog: URL? = nil,
        interruptions: ReplayInterruptions? = nil,
        snapshot: TranscriptSnapshot? = nil,
        audited: AuditTallies? = nil,
        summary: Bool = false,
        sample: ReplaySample = .everySession,
        progress: @escaping (String) -> Void = { _ in }
    ) -> (report: [String], shapes: [String]) {
        let directory = scratch ?? AdviceLedger.standardDirectory()
            .deletingLastPathComponent()
            .appendingPathComponent("replay", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        interruptions?.track(directory)
        defer {
            try? FileManager.default.removeItem(at: directory)
            interruptions?.forget(directory)
        }
        let other = against.map {
            ExternalReplayHook(binary: $0, directory: directory.appendingPathComponent("against", isDirectory: true), timeBudget: timeBudget, interruptions: interruptions, environment: againstEnvironment)
        }
        // Every call made one unit of work, so a signal's cleanup removes the scratch only after the call in flight has written its last.
        // The run's one snapshot, taken here where the caller handed none, so the hook's name gate reads the indexes the replay's scan reads.
        let snapshot = snapshot ?? TranscriptSnapshot.take(projectsDirectory: projectsDirectory, since: since, transcript: transcript)
        // Put beside another binary, whose `replay-hook` child judges every name afresh, the hook judges them afresh too:
        // judged against the snapshot, a name a store dropped since the run first read it would move every call naming it.
        let couldAnswer = other == nil ? AdvisableName.memoised(in: snapshot.indexes) : HookReplay.judgesAfresh
        let own = HookReplay(directory: directory, timeBudget: timeBudget, roots: roots, couldAnswer: couldAnswer)
        let hook: any ReplayHook = interruptions.map { InterruptibleReplayHook(hook: own, interruptions: $0) } ?? own
        let otherHook: (any ReplayHook)? = other.map { other -> any ReplayHook in
            interruptions.map { InterruptibleReplayHook(hook: other, interruptions: $0) } ?? other
        }
        var sections = TranscriptReplay.sections(
            projectsDirectory: projectsDirectory,
            since: since,
            until: until,
            transcript: transcript,
            unredacted: unredacted,
            hook: hook,
            against: otherHook,
            suppressionLog: suppressionLog,
            snapshot: snapshot,
            audited: audited,
            summary: summary,
            sample: sample,
            progress: progress
        )
        if let other, other.failures > 0 {
            sections.report.append("  the other binary failed \(other.failures) of its \(other.requests) requests — each verdict it failed is listed under \(ExternalReplayHook.failedRule)")
        }
        return sections
    }
}

extension AuditCommand {
    /// The line a replay's summary ends on: how long the whole command took, to the second.
    ///
    /// A replay beside the suite has to finish before the suite's proof expires, so the time it took is printed where the share is read rather than left to be measured by hand.
    static func elapsedLine(_ elapsed: TimeInterval) -> String {
        ReplayProgress.elapsed(elapsed)
    }

    /// How many contexts `audit --replay` replays when `--sample` is not given: a context replayed in about half a second, and about two with `--against`, so the paired replay of a hundred takes a few minutes.
    static let defaultSample = 100

    /// The sample `--sample` bounds the replay to, and where the scan's and the replay's progress goes: stderr, prefixed `audit: `, when ``ReportCommand/tellsProgress(asked:stderrIsTerminal:)`` says so, nowhere otherwise.
    static func replayBounds(
        sample: Int?,
        progressAsked: Bool,
        stderrIsTerminal: Bool,
        output: CommandOutput
    ) -> (sample: ReplaySample, progress: @Sendable (String) -> Void) {
        let sample = ReplaySample(limit: Self.limit(sample))
        guard ReportCommand.tellsProgress(asked: progressAsked, stderrIsTerminal: stderrIsTerminal) else { return (sample, { _ in }) }
        return (sample, { output.emitError("audit: \($0)") })
    }

    /// The bound `--sample` sets: `defaultSample` where it is not given, none where it is 0.
    static func limit(_ sample: Int?) -> Int? {
        let limit = sample ?? defaultSample
        return limit == 0 ? nil : limit
    }
}

extension AuditCommand {
    /// Only the flags and options come off the command line.
    ///
    /// Spelled out for the reason ``BuildCommand``'s keys are: an output is not something a decoder can produce.
    enum CodingKeys: String, CodingKey {
        case since
        case until
        case all
        case transcript
        case projects
        case root
        case unredact
        case replay
        case shapes
        case against
        case scanDiff
        case allWindows
        case summary
        case share
        case sample
        case progress
    }

    /// Prints how `against`'s scan and this build's class the windows of one snapshot differently, refusing in one line, with nothing else printed, a binary without the scan-dump entry point or whose dump fails.
    ///
    /// The snapshot is taken once, here, narrowed to `root` where one is given as the audit narrows its sweep, and handed to the other binary whole — its transcripts, their sizes and the window's instants — so a transcript written while either scan runs, or a midnight passed, cannot make the two read different bytes. The two scans run at once, so both read the live indexes in the same window of time, and where they differ both run a second time, so a window a build classed differently between its own two runs is listed apart as unstable.
    func scanDiff(against: String, projectsDirectory: URL, since: Date?, until: Date?, root: String?, interruptions: ReplayInterruptions) throws {
        let binary = URL(fileURLWithPath: against)
        guard FileManager.default.isExecutableFile(atPath: binary.path) else {
            output.emitError("audit: --against \(against) is not an executable file: name a sift binary.")
            throw ExitCode.failure
        }
        guard ScanDumpCommand.isSupported(by: binary, interruptions: interruptions) else {
            output.emitError("audit: --against \(against) predates --scan-diff: it has no scan-dump entry point to score its windows with, so build it from a revision that has one.")
            throw ExitCode.failure
        }
        let taken = TranscriptSnapshot.take(projectsDirectory: projectsDirectory, since: since, transcript: transcript)
        defer { taken.indexes.close() }
        let redactor: Redactor? = unredact ? nil : .standard()
        let plan = ScanDiffPlan(taken: taken, root: root, allWindows: allWindows, since: since, until: until, projectsDirectory: projectsDirectory, redactor: redactor)
        if let refusal = plan.refusal {
            output.emitError(refusal)
            throw ExitCode.failure
        }
        let snapshot = plan.snapshot
        let request = ScanDumpRequest(snapshot: snapshot, since: since, until: until, suppressionLog: SuppressionLog.standardFileURL)
        let failure = "audit: --against \(against) failed to dump its scan: it could not be run, exited non-zero, wrote a line that is not a window, or ran past \(Int(ScanDumpCommand.dumpLimit)) seconds."
        let first = ScanDumpCommand.windowsAtOnce(of: binary, request: request, interruptions: interruptions)
        guard let unattributed = first.theirs else {
            output.emitError(failure)
            throw ExitCode.failure
        }
        let theirs = snapshot.attributing(unattributed)
        let ours = first.ours
        var again: (theirs: [ScoredWindow], ours: [ScoredWindow])?
        if ScanDiff.differs(theirs: theirs, ours: ours) {
            let second = ScanDumpCommand.windowsAtOnce(of: binary, request: request, interruptions: interruptions)
            guard let theirsAgain = second.theirs else {
                output.emitError(failure)
                throw ExitCode.failure
            }
            again = (theirs: snapshot.attributing(theirsAgain), ours: second.ours)
        }
        output.emit(ScanDiff.lines(theirs: theirs, ours: ours, again: again, listsAll: plan.listsAll, redactor: redactor).joined(separator: "\n"))
    }
}
