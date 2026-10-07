//
// Copyright © Agulhas Labs
//

import Foundation
import SiftCore

/// `sift audit` — what the transcripts say about where the index was reached for and where it was not.
///
/// The usage log answers "how often was this called". It cannot answer "how often should it have been", because the reads that happened instead are not in it. The transcripts hold both sides, and they hold them for sessions that have already finished — which is why this is a report over history rather than instrumentation added from now on.
///
/// It exists in preference to asking sessions to explain themselves. A model asked why it did not call a tool produces a plausible narrative, not a cause: there was no deliberation to report, and tuning the tool against that narrative would be tuning it against fiction. What the model *did* is recorded exactly, in order, already.
public struct TranscriptAudit {
    /// The rendered audit over every session transcript under `projectsDirectory`, or one named transcript.
    ///
    /// `since` bounds the *lookups* counted, not the transcripts opened. A session that began yesterday and continued into today contributes only today's half — filtering whole transcripts by modification time instead would report yesterday's misses as today's, which is precisely the misreading this command exists to prevent. Transcripts untouched since the window are still skipped, but only as an optimisation: they can hold nothing inside it.
    ///
    /// `until` is the same window's other edge, exclusive: a lookup timestamped on `until`'s own day falls outside it. There is no analogous transcript-level skip for it — a transcript's modification date only grows, so it proves nothing about whether an early line falls before `until`.
    ///
    /// `roots` is the set of indexed repositories whose module health is reported. It is passed in rather than read here, and defaults to none: reading the registry inside the renderer would make every test of this report depend on whatever the machine running it happens to have indexed.
    ///
    /// `timeZone` is the zone the findings' days resolve in — the caller's, matching how the `--since`/`--until` window resolves. Injectable for the same reason `UsageWindow.start` takes one: a test of "the day is local" must be able to stand on either side of a midnight without waiting for one.
    ///
    /// `suppressionLog` is the hook's own record of what it withheld, read for the calls it let run on worth — `notSmaller` and `linesNotShown` windows and `notWorthTheTurn` whole reads — which are not worth answering rather than misses, and for the `otherStatementsRun` lines it let run whole, which are batched misses. Passed in, and read not at all where it is `nil`, for the reason `roots` is.
    ///
    /// `root` narrows the audit to one repository: a session or subagent transcript counts only where its own recorded `cwd` is that directory or lies beneath it, the same test `usage --root` and `report --root` apply to a logged call's root.
    ///
    /// Share-only rendering prints just the headline share and the voluntary share, two lines, and drops every other row and list.
    ///
    /// `snapshot` is the set of transcripts, and the bytes of each, to read — the one the replay beside it reads, so the two count the same lookups however the live transcripts grow between them. Taken here from `projectsDirectory`, `since` and `transcript` where none is given.
    ///
    /// `progress` is told the sweep's advance as `tallies` tells it, for a caller to print; it never changes the text.
    public static func render(
        projectsDirectory: URL,
        since: Date? = nil,
        until: Date? = nil,
        transcript: String? = nil,
        roots: [String] = [],
        timeZone: TimeZone = .current,
        redactor: Redactor? = nil,
        root: String? = nil,
        suppressionLog: URL? = nil,
        snapshot: TranscriptSnapshot? = nil,
        summary: Bool = false,
        shareOnly: Bool = false,
        usageLog: URL? = nil,
        progress: @escaping (String) -> Void = { _ in }
    ) -> String {
        let sweep = sweep(
            snapshot ?? .take(projectsDirectory: projectsDirectory, since: since, transcript: transcript),
            since: since,
            until: until,
            timeZone: timeZone,
            root: root,
            suppressionLog: suppressionLog,
            progress: progress
        )
        let saving = usageLog.flatMap { AuditLoggedSaving.line($0, since: since, until: until, root: root, transcript: transcript) }
        return rendered(sweep, directory: projectsDirectory, since: since, until: until, timeZone: timeZone, roots: roots, redactor: redactor, root: root, summary: summary, shareOnly: shareOnly, saving: saving)
    }

    /// The audit's text for a sweep already made: what `render` prints, and what `renderWithTallies` prints beside the counts it hands on.
    private static func rendered(
        _ sweep: Sweep,
        directory projectsDirectory: URL,
        since: Date?,
        until: Date?,
        timeZone: TimeZone,
        roots: [String] = [],
        redactor: Redactor? = nil,
        root: String? = nil,
        summary: Bool = false,
        shareOnly: Bool = false,
        saving: String? = nil
    ) -> String {
        guard !sweep.transcripts.isEmpty else {
            let scope = since == nil && until == nil ? "" : " in that window"
            let path = redactor == nil ? projectsDirectory.path : Redactor.tilded(projectsDirectory.path)
            if let root, !sweep.windowed.isEmpty {
                return TranscriptWorkingDirectory.noneIn(root, windowed: sweep.windowed, scope: scope, path: path, redactor: redactor)
            }
            return "no session transcripts found\(scope) under \(path)"
        }

        let active = sweep.active
        guard !active.isEmpty else {
            let scope = since == nil && until == nil ? "" : " in that window"
            let count = sweep.transcripts.count
            return "no Swift lookups\(scope) across \(count) transcript\(count == 1 ? "" : "s") — nothing to audit"
        }

        return render(
            AuditFindings(scans: active),
            window: windowText(since: since, until: until, timeZone: timeZone),
            directory: projectsDirectory,
            roots: roots,
            redactor: redactor,
            summary: summary,
            shareOnly: shareOnly,
            saving: saving
        )
    }

    private static func render(
        _ findings: AuditFindings,
        window: String,
        directory: URL,
        roots: [String],
        redactor: Redactor?,
        summary: Bool = false,
        shareOnly: Bool = false,
        saving: String? = nil
    ) -> String {
        let totals = findings.totals
        let everything = totals.indexed + totals.guided + totals.readWholeAfterDigest
            + totals.revisited + totals.belowFloor + totals.cold + totals.textSearches
            + totals.withheldOnWorth + totals.unreachable
        if shareOnly {
            return shareLines(totals).joined(separator: "\n")
        }
        var lines = [
            "audit — \(findings.sessions) session\(findings.sessions == 1 ? "" : "s")\(window), \(everything) Swift lookup\(everything == 1 ? "" : "s")",
            "scanned: \(redactor == nil ? directory.path : Redactor.tilded(directory.path))",
            "live: name and names judge each name against each index as this run first opened it, held for the run; "
                + "below floor, path and unreplayable read the disk as each is asked, and replayed hook answers read the indexes live — "
                + "all of these, and cold, text search and the share with them, can move between runs",
            "",
        ]

        let tallies = findings.scans.map(\.tally)
        lines.append(indexedLine(totals, tallies: tallies))
        lines.append(voluntaryLine(totals))
        // Inside `indexed`, not beside it: the index served these, through the hook rather than the server.
        if totals.answered > 0 {
            lines.append("    answered  \(pad(totals.answered))  of those, by the advice hook in a refusal's place — its call run and the answer handed over")
        }
        if let partial = partialAnswerLine(totals) {
            lines.append(partial)
        }
        lines.append(contentsOf: AnswerThenRead.auditLines(totals.answerMisses, pad: pad))
        // Inside `indexed` for the same reason, and on a row of its own because the route is the thing a
        // reader cannot otherwise see: a context under an output style that mandates Bash reaches the index
        // almost entirely this way, and before this row the share moved with no visible cause.
        if totals.cliServed > 0 {
            lines.append("    on the CLI\(pad(totals.cliServed))  of those, from a Bash `sift digest`/`where`/`search`/`strings` — the same answers, off the MCP tools")
        }
        lines.append("  cold        \(pad(totals.cold))  went around the index  ← the misses")
        lines.append("    batched   \(pad(totals.batched))  of those, a Swift read on a line the hook let run whole for its other statements — put the sift call on the line instead")
        lines.append("")
        lines.append("  guided      \(pad(totals.guided))  ranged reads an index call had located — the loop working")
        lines.append("  read whole  \(pad(totals.readWholeAfterDigest))  read whole after its digest — the read a digest exists to save, paid anyway")
        // The usage log's saving, gross, then the baseline it is priced against and the whole reads it does
        // not subtract — counted, never priced (`TokenEstimate.readAnyway(_:)`).
        if let saving {
            lines.append(saving)
        }
        lines.append("    baseline  a saving is the source a digest replaced less the bytes it served, at \(TokenEstimate.bytesPerToken) bytes a token, "
            + TokenEstimate.baseline)
        if let readAnyway = TokenEstimate.readAnyway(totals.readWholeAfterDigest) {
            lines.append("    gross     \(readAnyway)")
        }
        lines.append("  below floor \(pad(totals.belowFloor))  files small enough that a digest would have served the source anyway")
        lines.append("  revisited   \(pad(totals.revisited))  re-reads of a file already open in that context")
        lines.append("  text search \(pad(totals.textSearches))  for text the index does not record — a name no index declares, a file no call can name, or a search that names no call at all")
        // Split unconditionally, and under the row rather than beside it: the total says how many lookups
        // were excused and nothing about what would answer them, and the three causes argue for three
        // different things — recording more than declarations, indexing another tree, neither. A reader
        // deciding whether the tool should be reading comment bodies needs the first line on its own, and a
        // reader diffing two audits needs each line missing for a reason rather than because it was zero.
        let causes = totals.textSearchCauses
        lines.append("    pattern   \(pad(causes.patternNamesNothing))  of those, a pattern naming nothing the index records — a count, a literal, a merge's markers, the text of a comment")
        lines.append("    name      \(pad(causes.undeclaredName))  of those, a name no index on this machine declares — `where` would answer \"no symbol named …\"")
        lines.append("    path      \(pad(causes.unnameableFile))  of those, a file no index call can name — build output, a dependency's checkout, a tree no index holds")
        lines.append("    one file  \(pad(causes.patternInOneFile))  of those, a grep of one file for a pattern naming nothing a declaration could be")
        // Beside the row above and never inside it: these are lookups the index could have answered, so
        // the share they are kept out of is stated as the reader would have it without them. A count on
        // its own says how many were excused and nothing about what the excuse was worth. Unconditional
        // like `guided` and `revisited` — a reader diffing two audits needs the line missing for a
        // reason, not missing because it happened to be zero — with the share clause dropped at zero,
        // where it would only restate the headline.
        var notWorth = "  not worth   \(pad(totals.withheldOnWorth))  not worth the round trips it would have cost to answer these — more than the command in one case, no digest shape giving an answer at all in another"
        if totals.withheldOnWorth > 0, let without = TranscriptTally.shareTextCountingWithheldOnWorth(tallies) {
            notWorth += " — counted as misses the share is \(without)"
        }
        lines.append(notWorth)
        lines.append(contentsOf: notWorthRuleLines(totals.withheldOnWorthCauses))
        lines.append("  unreachable \(pad(totals.unreachable))  lookups from contexts holding no sift tools — advice that could not land")
        if totals.failed > 0 {
            lines.append("  failed      \(pad(totals.failed))  index calls that came back an error")
        }
        // Apart from `failed`, because these never reached the index: the harness answered them itself.
        if totals.unavailable > 0 {
            lines.append("  unavailable \(pad(totals.unavailable))  index calls the harness never delivered — the tool was not there in that context")
        }
        // Neither a failure nor a miss: the permission step answered these, not the index.
        if totals.declined > 0 {
            lines.append("  declined    \(pad(totals.declined))  index calls stopped at the permission check — declined, or not ruled on in time; neither a failure nor a miss")
        }
        lines.append(contentsOf: floorProvenance(findings.scans))
        lines.append(contentsOf: unreachableCauses(findings.scans))
        lines.append(contentsOf: RefusalCostReport.section(findings.scans, totals: totals, redactor: redactor))

        if summary {
            return (lines + summaryTrailer()).joined(separator: "\n")
        }

        let misses = findings.reached.filter { $0.tally.cold > 0 }.sorted {
            ($0.tally.cold, $1.label) > ($1.tally.cold, $0.label)
        }
        if !misses.isEmpty {
            lines.append("")
            lines.append("cold lookups, worst first:")
            for scan in misses.prefix(15) {
                let label = redactor.map { redacted(label: scan.label, by: $0) } ?? scan.label
                lines.append("  \(pad(scan.tally.cold))  \(label)\(dates(scan.missDays))")
                if !scan.coldFiles.isEmpty {
                    lines.append("      \(summarise(scan.coldFiles.map(\.path), redactor: redactor))")
                }
                if scan.coldSearches > 0 {
                    lines.append("      + \(scan.coldSearches) Swift-flavoured search\(scan.coldSearches == 1 ? "" : "es")\(missedCallBreakdown(scan))")
                }
            }
            if misses.count > 15 {
                lines.append("  … and \(misses.count - 15) more transcript\(misses.count - 15 == 1 ? "" : "s") with cold lookups")
            }
        }

        lines.append(contentsOf: failureSection(findings.scans, redactor: redactor))

        let calls = missedCalls(in: findings.reached)
        let searches = findings.reached.reduce(0) { $0 + $1.coldSearches }
        if searches > 0 {
            lines.append("")
            lines.append("what the searches were reaching for — the call that would have answered each:")
            for entry in calls {
                lines.append("  \(pad(entry.count))  \(column(entry.call.rawValue, 8))\(entry.call.yields)")
            }
            let unclassified = searches - calls.reduce(0) { $0 + $1.count }
            if unclassified > 0 {
                lines.append("  \(pad(unclassified))  \(column("—", 8))the advisors named no call for these")
            }
            lines.append("  (verbs, not queries — this section reads the same with or without --unredact, which is")
            lines.append("   the point: the half that says what to do is the half that is always safe to share.)")
        }

        let readWhole = countedEntries(findings.scans.flatMap(\.readWholeFiles))
        if !readWhole.isEmpty {
            lines.append("")
            lines.append("read whole after its digest — the files, most first:")
            for entry in readWhole.prefix(10) {
                lines.append("  \(pad(entry.count))  \(redactor?.file(entry.name) ?? entry.name)\(lastSeen(entry))")
            }
            // Worded as what was counted, because the transcript records the read and not the reason for it.
            lines.append("  (what these reads cost, not a verdict on the digest: a file is often read whole for a")
            lines.append("   comment or a string literal, which no digest records — the ranged reads below say more)")
        }

        var followUp = DigestFollowUp()
        for scan in findings.scans {
            followUp += scan.followUp
        }
        if followUp.total > 0 {
            lines.append("")
            lines.append("what the ranged reads went back for — the digest member each one landed on:")
            lines.append("  \(pad(followUp.namedMember))  a member the digest had named and located — the loop working")
            lines.append("  \(pad(followUp.collapsedNested))  a container the digest showed as a count, with no names")
            // Symbol names carry no `/`, so the path-shaped counting displays them unchanged.
            for entry in countedEntries(followUp.collapsed.map { (path: $0.name, day: $0.day) }).prefix(5) {
                lines.append("      \(entry.count)× \(redactor?.symbol(entry.name) ?? entry.name)\(lastSeen(entry))")
            }
            lines.append("  \(pad(followUp.wholeDeclaration))  essentially the whole declaration again")
            lines.append("  \(pad(followUp.unrecordedContent))  content a digest does not record — a preview, file-head prose, another declaration")
            lines.append("  \(pad(followUp.unattributed))  no member the digest listed covers those lines")
            // Named rather than numbered: the collapsed-container examples are interleaved between the rows,
            // so "the second row" counts past something and lands on a line the reader is not looking at.
            lines.append("  (the collapsed-container row is the actionable one: a count standing where the names")
            lines.append("   were the content. Content a digest does not record is not a defect at all — a preview")
            lines.append("   is skipped on purpose and prose is not a declaration.)")
        }

        let repeated = repeatedColdFiles(in: findings.reached)
        if !repeated.isEmpty {
            lines.append("")
            lines.append("opened cold in more than one context — the files worth a digest habit:")
            for entry in repeated.prefix(10) {
                lines.append("  \(pad(entry.count))  \(redactor?.file(entry.name) ?? entry.name)\(lastSeen(entry))")
            }
        }

        lines.append(contentsOf: AuditModuleHealth.indexHealth(roots: roots, redactor: redactor))

        lines.append("")
        lines.append("A cold lookup is a first touch of a Swift file with no index call naming it first, or a")
        lines.append("Grep/Glob mentioning Swift. Reads the index sent you to are counted as guided, not cold.")
        return lines.joined(separator: "\n")
    }

    // MARK: Scanning

    /// Every transcript in scope, scanned once — the one sweep both faces of this data draw on.
    ///
    /// `datesEveryLookup` buckets each lookup under its local day as well as counting it, which the trend on the `report` page needs and the text audit does not. It is opt-in because it costs one extra JSON parse per line carrying an event, and `audit` runs over transcripts that reach 60 MB.
    ///
    /// `suppressionLogSize` reads only that prefix of the log, and `keepsWindows` has every scan keep the windows it scored (`sift scan-dump`).
    static func sweep(
        _ snapshot: TranscriptSnapshot,
        since: Date?,
        until: Date? = nil,
        timeZone: TimeZone,
        datesEveryLookup: Bool = false,
        root: String? = nil,
        excludingScratch: Bool = false,
        suppressionLog: URL? = nil,
        suppressionLogSize: Int? = nil,
        keepsWindows: Bool = false,
        cache: TranscriptTallyCache.Store? = nil,
        progress: @escaping (String) -> Void = { _ in }
    ) -> Sweep {
        let windowed = snapshot.sessions
        guard !windowed.isEmpty else { return Sweep(transcripts: [], scans: []) }
        let advance = SweepProgress(tell: progress)
        advance.began(windowed.count)

        let home = SiftPaths.accountHome.path
        // One memo for the whole run: the same file is first-touched in every transcript that opened it.
        let options = ScanOptions(
            since: since,
            until: until,
            belowFloor: DigestFloor.memoised(),
            couldAnswer: AdvisableName.memoised(in: snapshot.indexes),
            memberExists: AdvisableName.memoisedMember(in: snapshot.indexes),
            timeZone: timeZone,
            datesEveryLookup: datesEveryLookup,
            loggedLetThrough: suppressionLog.map { SuppressionLog.callsLetThrough(in: $0, prefix: suppressionLogSize) } ?? [:],
            answeredCalls: suppressionLog.map { AnsweredLog.calls(in: AnsweredLog.fileURL(besideSuppressionLog: $0)) } ?? [],
            keepsWindows: keepsWindows
        )
        /// A scan the cache holds for this file, window and build stands in for reading it; one read is stored back.
        func recalledOrScanned(_ url: URL, label: String, session: String, isSubagent: Bool) -> Scan {
            let read = { scan(url, label: label, session: session, isSubagent: isSubagent, options: options, snapshot: snapshot) }
            return cache?.recalled(Scan(label: label, session: session, transcript: url.path, isSubagent: isSubagent), in: snapshot, since: since, reading: read) ?? read()
        }
        var scans: [Scan] = []
        var scoped: [URL] = []
        for (index, session) in windowed.enumerated() {
            advance.reached(index, of: windowed.count)
            let key = session.path
            // Each subagent is scoped by its own `cwd`, never by its parent's: a session started outside the root
            // can dispatch an agent into it, and that agent's lookups are that root's as much as any.
            let agents = snapshot.subagents(of: session).filter { inScope($0, root: root, excludingScratch: excludingScratch) }
            // The session's own context answers for its subagents as well as for itself: their MCP tools come from
            // the session's servers, so a session that never held sift's explains why none of its agents did. Read
            // only where it is in scope — which is every session `render` sweeps, the one caller that names causes;
            // outside it, its subagents are explained by their own transcripts alone.
            var own: Scan?
            if inScope(session, root: root, excludingScratch: excludingScratch) {
                let named = SubagentFile.identity(of: session, home: home)
                var scanned = recalledOrScanned(session, label: named?.label ?? label(for: session, home: home), session: named?.session ?? key, isSubagent: named != nil)
                scanned.sessionHeldNoIndexTools = scanned.heldNoIndexTools
                scanned.sessionBinaryMissing = scanned.binaryMissingAtStart
                scans.append(scanned)
                own = scanned
            }
            for agent in agents {
                var agentScan = recalledOrScanned(agent, label: label(for: session, home: home, agent: agent), session: key, isSubagent: true)
                agentScan.sessionHeldNoIndexTools = own?.heldNoIndexTools ?? false
                agentScan.sessionBinaryMissing = own?.binaryMissingAtStart ?? false
                scans.append(agentScan)
            }
            if own != nil || !agents.isEmpty {
                scoped.append(session)
            }
        }
        advance.finished(windowed.count)
        return Sweep(transcripts: scoped, scans: scans, windowed: windowed)
    }
}

extension TranscriptAudit {
    static func scan(_ url: URL, label: String, session: String, isSubagent: Bool, options: ScanOptions, snapshot: TranscriptSnapshot) -> Scan {
        var scan = Scan(label: label, session: session, transcript: url.path, isSubagent: isSubagent)
        guard let data = snapshot.contents(of: url) else { return scan }
        scan.wasRead = true
        let (since, until, timeZone) = (options.since, options.until, options.timeZone)
        var state = TranscriptScanState()
        state.windowLog = options.keepsWindows ? ScanWindowLog() : nil
        var followUp = DigestFollowUpScan(since: since, until: until, day: { day(of: $0, timeZone: timeZone) })
        for line in data.split(separator: 0x0A, omittingEmptySubsequences: true) {
            followUp.consume(line: Data(line))
            let events = TranscriptScan.events(
                line: Data(line),
                state: &state,
                since: since,
                until: until,
                belowFloor: options.belowFloor,
                couldAnswer: options.couldAnswer,
                memberExists: options.memberExists,
                loggedLetThrough: options.loggedLetThrough,
                answeredCalls: options.answeredCalls
            )
            // The day is read only when a finding on this line will carry it — re-parsing every line
            // for its timestamp would double the JSON work over transcripts that reach 60 MB.
            let wantsDay = options.datesEveryLookup ? !events.isEmpty : events.contains(where: isDated)
            let day = wantsDay ? day(ofLine: Data(line), timeZone: timeZone) : nil
            for event in events {
                scan.tally.fold(event)
                if options.datesEveryLookup, let day {
                    scan.byDay[day, default: TranscriptTally()].fold(event)
                }
                apply(event, day: day, to: &scan)
            }
        }
        // Every refusal still waiting for a follow-up has none: the transcript ends on its round trip.
        for pending in state.awaitingFollowUp {
            scan.tally.fold(.refusalFollowUp(.ended, cost: pending.cost))
        }
        scan.followUp = followUp.result
        scan.windows = state.windowLog?.windows ?? []
        scan.floorFromDisk = state.floorFromDisk
        scan.earliestStamp = state.earliestStamp
        scan.serverFailed = state.serverFailed
        scan.heldIndexTools = state.heldIndexTools
        scan.binaryMissingAtStart = state.binaryMissingAtStart
        // The verdict is read off the tally, and this one was folded event by event rather than line by line, so
        // the tool-list evidence is copied across here — from the whole transcript, as the line-by-line fold
        // copies it after every line.
        scan.tally.recordedToolListWithoutIndex = state.recordedToolListWithoutIndex
        scan.tally.recordsWholeToolList = state.recordsWholeToolList
        return scan
    }

    /// Every session transcript under the projects directory: `<projects>/<project>/<session>.jsonl`.
    ///
    /// One level deep on purpose — the second level is the per-session subagent directory, which is collected against its own session rather than as a session of its own.
    ///
    /// Deduped by resolved path: a symlinked project directory is followed rather than skipped, so a symlink beside the real project it points at would otherwise reach the same transcript twice, once under each name. The first name reached, in sorted order, is the one kept — and so the one the label is built from.
    static func sessionTranscripts(under directory: URL) -> [URL] {
        let projects = entries(of: directory, includingPropertiesForKeys: [.isDirectoryKey])
        let sessions = projects.flatMap { project in
            entries(of: project, includingPropertiesForKeys: nil).filter { $0.pathExtension == "jsonl" }
        }.sorted { $0.path < $1.path }
        var seen: Set<String> = []
        return sessions.filter { seen.insert(CanonicalPath.of($0.path)).inserted }
    }

    static func subagentTranscripts(of session: URL) -> [URL] {
        let directory = session.deletingPathExtension().appendingPathComponent("subagents", isDirectory: true)
        return entries(of: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "jsonl" }
            .sorted { $0.path < $1.path }
    }

    /// `directory`'s entries, following it past a symlink when the plain listing comes up empty.
    ///
    /// `contentsOfDirectory` throws for a directory reached through a symlink — a `--projects` argument that is itself a symlink, or one project folder among many that is — and the `try?` that absorbs a missing directory turns that into an empty listing, indistinguishable from a directory that is genuinely empty until the symlink is resolved and listed again. Tried first unresolved so the ordinary, non-symlinked case never pays for a second stat, and resolution goes through the filesystem (`resolvingSymlinksInPath`, `realpath` underneath) rather than a hand-rolled walk, so a symlink cycle is the filesystem's problem to refuse, never this tool's to loop on: a path a cycle cannot resolve comes back unchanged, and the identical, already-tried path contributes nothing more.
    private static func entries(of directory: URL, includingPropertiesForKeys keys: [URLResourceKey]?) -> [URL] {
        let direct = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: keys
        )) ?? []
        guard direct.isEmpty else { return direct }
        let resolved = directory.resolvingSymlinksInPath()
        guard resolved.path != directory.path else { return [] }
        return (try? FileManager.default.contentsOfDirectory(
            at: resolved,
            includingPropertiesForKeys: keys
        )) ?? []
    }

    /// When the transcript at `url` was last written — its target's date when `url` is a symlink, since the link's own date is when the link was made and says nothing about the file being written through it.
    static func modificationDate(of url: URL) -> Date? {
        (try? url.resolvingSymlinksInPath().resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }

    // MARK: Presentation

    /// A readable name for a transcript: the project it belongs to, and which context inside it.
    ///
    /// Claude Code names a project directory after its absolute path with the separators flattened to dashes, so the home prefix is repeated on every line and carries nothing. It is trimmed off; anything that does not start with it is left exactly as found rather than guessed at.
    static func label(for session: URL, home: String, agent: URL? = nil) -> String {
        let project = session.deletingLastPathComponent().lastPathComponent
        let prefix = home.replacingOccurrences(of: "/", with: "-")
        var trimmed = project.hasPrefix(prefix) ? String(project.dropFirst(prefix.count)) : project
        while trimmed.hasPrefix("-") {
            trimmed.removeFirst()
        }
        let name = trimmed.isEmpty ? project : trimmed
        let id = session.deletingPathExtension().lastPathComponent.prefix(8)
        guard let agent else { return "\(name) · \(id)" }
        return "\(name) · \(id) · subagent \(agent.deletingPathExtension().lastPathComponent.prefix(14))"
    }

    /// The first few file names, with the rest counted rather than listed.
    private static func summarise(_ paths: [String], redactor: Redactor?) -> String {
        let distinct = NSOrderedSet(array: paths.map(name)).array as? [String] ?? paths
        let displayed = redactor.map { redactor in distinct.map { redactor.file($0) } } ?? distinct
        let shown = displayed.prefix(4).joined(separator: ", ")
        return displayed.count > 4 ? "\(shown), +\(displayed.count - 4) more" : shown
    }

    /// The label with its project component pseudonymised; the session id and subagent marker are already opaque.
    static func redacted(label: String, by redactor: Redactor) -> String {
        let parts = label.components(separatedBy: " · ")
        guard let project = parts.first else { return label }
        return ([redactor.project(project)] + parts.dropFirst()).joined(separator: " · ")
    }

    /// Files opened cold in more than one context, most-repeated first, each with the last day it happened.
    ///
    /// A file read cold once is ordinary. One read cold in five separate contexts is a type that keeps being rediscovered from source, which is exactly what a digest is for.
    ///
    /// Counted by full path and only then shortened for display. Basenames repeat across repositories — `Package.swift`, `Container.swift`, `Exports.swift` — and counting those together would invent a rediscovery out of two files that merely share a name, in the one list meant to be acted on.
    private static func repeatedColdFiles(in scans: [Scan]) -> [CountedEntry] {
        var counts: [String: (count: Int, last: String?)] = [:]
        for scan in scans {
            var seen: Set<String> = []
            for entry in scan.coldFiles {
                var slot = counts[entry.path] ?? (0, nil)
                if seen.insert(entry.path).inserted {
                    slot.count += 1
                }
                slot.last = latest(slot.last, entry.day)
                counts[entry.path] = slot
            }
        }
        return counts.filter { $0.value.count > 1 }
            .map { CountedEntry(name: name($0.key), count: $0.value.count, last: $0.value.last) }
            .sorted { ($0.count, $1.name) > ($1.count, $0.name) }
    }

    private static func name(_ path: String) -> String {
        URL(fileURLWithPath: path).lastPathComponent
    }

    /// Occurrence counts by path, most first, displayed by name, each with the last day one happened.
    private static func countedEntries(_ entries: [(path: String, day: String?)]) -> [CountedEntry] {
        var counts: [String: (count: Int, last: String?)] = [:]
        for entry in entries {
            var slot = counts[entry.path] ?? (0, nil)
            slot.count += 1
            slot.last = latest(slot.last, entry.day)
            counts[entry.path] = slot
        }
        return counts.map { CountedEntry(name: name($0.key), count: $0.value.count, last: $0.value.last) }
            .sorted { ($0.count, $1.name) > ($1.count, $0.name) }
    }

    /// The later of two days — `yyyy-MM-dd` orders correctly as text — treating unknown as earliest.
    private static func latest(_ lhs: String?, _ rhs: String?) -> String? {
        guard let lhs else { return rhs }
        guard let rhs else { return lhs }
        return max(lhs, rhs)
    }

    /// The day annotation for a counted row: the bare day for a single occurrence, `last` for several.
    private static func lastSeen(_ entry: CountedEntry) -> String {
        guard let last = entry.last else { return "" }
        return entry.count == 1 ? " · \(last)" : " · last \(last)"
    }

    /// The day annotation for a transcript's misses: one day, or the span they fall across.
    private static func dates(_ days: [String]) -> String {
        guard let first = days.first, let last = days.last else { return "" }
        return first == last ? " · \(first)" : " · \(first) – \(last)"
    }

    /// Whether an event is one the report will date — the findings, not the counts.
    private static func isDated(_ event: TranscriptEvent) -> Bool {
        switch event {
        case .lookup(.cold), .lookup(.batched), .lookup(.readWholeAfterDigest), .indexFailure, .refusalRoundTrip, .refusalFollowUp: true
        default: false
        }
    }

    /// The local day of the line's timestamp, matching the local resolution of the window it is read within.
    private static func day(ofLine line: Data, timeZone: TimeZone) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let stamp = object["timestamp"] as? String,
              let instant = TranscriptScan.instant(stamp)
        else {
            return nil
        }
        return day(of: instant, timeZone: timeZone)
    }

    /// `text` padded out to `width`, never cut short of it.
    ///
    /// `String.padding(toLength:)` truncates when the string is already longer, which is the wrong half of the contract for a column whose whole job is to name the tool that failed — and a tool name comes off whatever the transcript carried, not off a closed list.
    static func column(_ text: String, _ width: Int) -> String {
        text.count >= width ? text + " " : text + String(repeating: " ", count: width - text.count)
    }

    static func pad(_ value: Int) -> String {
        String(repeating: " ", count: max(0, 4 - String(value).count)) + String(value)
    }
}

extension TranscriptAudit {
    /// The formatters every audit and replay in the process names days with.
    private static let dayFormatters = DayFormatters()

    static func day(of date: Date, timeZone: TimeZone) -> String {
        dayFormatters.formatter(for: timeZone).string(from: date)
    }
}

/// The report's own sections, kept out of the primary body so it stays inside the length the project holds every type to.
extension TranscriptAudit {
    /// Applies one event to the scan it belongs to — the findings a `Scan` lists rather than merely counts, each keyed to the day the event carried.
    ///
    /// Split out of `scan`'s own loop for the same reason this extension exists at all: a scan that both walked every line and matched every event kept the primary body over the project's length cap.
    private static func apply(_ event: TranscriptEvent, day: String?, to scan: inout Scan) {
        switch event {
        case let .lookup(.cold(file, missed)):
            if let file {
                // The full path is kept and only ever shortened for display: the cross-context
                // tally below counts distinct files, and a repo's `Package.swift` must not merge
                // with another repo's into one row claiming a rediscovery that never happened.
                scan.coldFiles.append((path: file, day: day))
            } else {
                scan.coldSearchEntries.append((day: day, missed: missed))
            }
        case let .lookup(.batched(file, missed)):
            // A miss like any cold one, so the context's list of misses names it beside the rest.
            apply(.lookup(.cold(file: file, missed: missed)), day: day, to: &scan)
        case let .lookupRetracted(.batched(file, missed)):
            apply(.lookupRetracted(.cold(file: file, missed: missed)), day: day, to: &scan)
        case let .lookup(.readWholeAfterDigest(file)):
            scan.readWholeFiles.append((path: file, day: day))
        case let .indexFailure(failure):
            scan.failures.append((failure: failure, day: day))
        case let .refusalRoundTrip(cost):
            scan.roundTrips.append((cost: cost, day: day))
        case let .refusalFollowUp(.reRun(shape, call), _):
            scan.reRunFollowUps.append(ReRunFollowUp(shape: shape, call: call, day: day))
        // The tally is a count and can simply be decremented; these lists name files, so a retracted
        // read has to be struck from the row it was written into — with the day that rode in on it,
        // or a span still names a day whose only miss was taken back. A retracted *search* carries
        // no identity to strike by, so it drops the newest recorded day instead of its own. That is
        // exact in the ordinary transcript, where a result lands beside its call; the days can
        // differ only when parallel searches straddle a midnight, and threading a call id through
        // the event contract to close that is more machinery than one span annotation is worth.
        case let .lookupRetracted(.cold(file, missed)):
            if let file, let index = scan.coldFiles.lastIndex(where: { $0.path == file }) {
                scan.coldFiles.remove(at: index)
            } else if file == nil,
                      let index = scan.coldSearchEntries.lastIndex(where: { $0.missed == missed })
            {
                // Matched on the classification the retraction carries rather than simply dropping the
                // newest entry. Two searches in flight at once are ordinarily classified differently —
                // one `where`, one `search` — and taking back whichever landed last would move a
                // count between verb buckets, which is the one thing the breakdown is read for.
                scan.coldSearchEntries.remove(at: index)
            }
        case let .lookupRetracted(.readWholeAfterDigest(file)):
            if let index = scan.readWholeFiles.lastIndex(where: { $0.path == file }) {
                scan.readWholeFiles.remove(at: index)
            }
        default:
            break
        }
    }

    /// `--summary`'s closing line: how to get the lists it dropped.
    private static func summaryTrailer() -> [String] {
        ["", "lists: sift audit without --summary"]
    }

    /// The failures, grouped by the tool and the kind of failure, worst first.
    ///
    /// The one row of this report that is unambiguously a defect rather than a habit, and so the one that most needs to name something: a bare `failed 10` says a tenth of something went wrong and gives you nowhere to start. The kind is printed in full because it is our own message classified rather than anything of the caller's, so it survives the default redaction that the targets beside it do not.
    private static func failureSection(_ scans: [Scan], redactor: Redactor?) -> [String] {
        let failures = scans.flatMap(\.failures)
        guard !failures.isEmpty else { return [] }

        var groups: [FailureKey: FailureGroup] = [:]
        for entry in failures {
            let key = FailureKey(tool: entry.failure.tool, kind: entry.failure.kind)
            var group = groups[key] ?? FailureGroup()
            group.count += 1
            if let target = entry.failure.target {
                let displayed = redactor?.target(target) ?? target
                if !group.targets.contains(displayed) {
                    group.targets.append(displayed)
                }
            }
            group.last = latest(group.last, entry.day)
            groups[key] = group
        }

        var lines = ["", "index calls that failed — the tool, the kind of failure, and what it was asked:"]
        for (key, group) in groups.sorted(by: { ($0.value.count, $1.key.sortKey) > ($1.value.count, $0.key.sortKey) }) {
            var row = "  \(pad(group.count))  \(column(key.tool, 9))\(key.kind.rawValue)"
            if !group.targets.isEmpty {
                row += " · " + group.targets.prefix(3).joined(separator: ", ")
                if group.targets.count > 3 {
                    row += " +\(group.targets.count - 3) more"
                }
            }
            if let last = group.last {
                row += group.count == 1 ? " · \(last)" : " · last \(last)"
            }
            lines.append(row)
        }
        lines.append("  (the kind is our own message classified, never a name of yours, so it reads the same either way.)")
        return lines
    }

    /// The partial-answer row, printed only where one fired: how many in-place answers left an alternation's branches uncovered, and how many of those the caveat's own identical re-run then swept — `nil` where none fired, so the audit stays silent about a shape that never showed up.
    static func partialAnswerLine(_ totals: TranscriptTally) -> String? {
        guard totals.partialAnswers > 0 else { return nil }
        return "    partial answers  \(pad(totals.partialAnswers))  followed by the sweep re-run  \(pad(totals.partialAnswersSwept))"
    }

    /// The `indexed` row: the share, and the share on the old denominator beside it, which held the one-file text searches as misses, so an accounting change is read off the report and never taken on trust — neither number hides the other.
    private static func indexedLine(_ totals: TranscriptTally, tallies: [TranscriptTally]) -> String {
        let oldShare = TranscriptTally.shareTextCountingOneFileTextSearches(tallies) ?? "n/a"
        let oneFile = TranscriptTally.oneFileTextSearchesOnTheOldDenominator(tallies)
        return "  indexed     \(pad(totals.indexed))  served by sift — \(totals.shareText ?? "n/a") of the lookups that had a choice"
            + " — on the old denominator \(oldShare) (text searches in one file +\(oneFile))"
    }

    /// The `voluntary` row under `indexed`: the lookups the agent chose the index for, the hook's own answers taken out, with the arithmetic behind the percentage.
    static func voluntaryLine(_ totals: TranscriptTally) -> String {
        "  voluntary   \(pad(totals.voluntary))  chosen by the agent, not answered by the hook — \(totals.voluntaryShareText ?? "n/a") of the lookups that had a choice"
    }

    /// The two lines `--share` prints: the headline share and the voluntary share, each with its fraction.
    static func shareLines(_ totals: TranscriptTally) -> [String] {
        let headline = totals.total > 0 ? "\(totals.shareText ?? "n/a") = \(totals.indexed) / \(totals.total)" : "n/a"
        return [
            "served by sift — \(headline) of the lookups that had a choice",
            "voluntary — \(totals.voluntaryShareText ?? "n/a") of the lookups that had a choice",
        ]
    }

    /// The `not worth` row split by rule, mirroring the text-search row's own split: the rules argue for different fixes, and pooling them into the parent count would hide which one applies.
    ///
    /// Printed unconditionally, like the causes above it, so a reader diffing two audits sees each line missing for a reason rather than because it happened to be zero.
    private static func notWorthRuleLines(_ rules: WithholdOnWorthCauses) -> [String] {
        [
            "    context   \(pad(rules.contextLines))  of those, a grep of one file printing context around a match that is not a declaration",
            "    names     \(pad(rules.severalNames))  of those, an alternation confined to the files it names",
            "    filtered  \(pad(rules.filteredOutput))  of those, a read whose output a later stage filters",
            "    retried   \(pad(rules.retryAllowed))  of those, a refusal whose identical re-run the hook then allowed",
            "    larger    \(pad(rules.notSmaller))  of those, a read the hook let run, its answer no smaller than what it prints (the hook's logged verdict)",
            "    unshown   \(pad(rules.linesNotShown))  of those, a window the hook let run, its answer not showing the lines asked for (the hook's logged verdict)",
            "    files     \(pad(rules.filesOnly))  of those, a search printing only the names of the files it matches",
            "    turn      \(pad(rules.notWorthTheTurn))  of those, a whole read of a Swift file the hook let run, its digest sparing less than the turn after it costs (the hook's logged verdict)",
            "    named     \(pad(rules.namedFiles))  of those, a name search of the Swift files it names, which the hook lets run rather than answer with a `where` of the whole tree",
        ]
    }

    /// Why the unreachable lookups could not reach the index, by the cause each context's transcript points to — then the contexts that held no MCP tools but ran the `sift` CLI, so the index was within their reach anyway, which the bucket leaves in the share.
    ///
    /// Spelled out only when there is something to explain, and never as a bare number: the count on its own reads as a fault of the tool, and the fix for it is somewhere sift cannot reach. **Which somewhere depends on the context, and naming the wrong one sends a reader to fix something that is fine.** Where the harness recorded this server as failed in that context, the server is the cause — it never started or its connection dropped — and no agent definition was at fault. Where the session's own context demonstrably never held the tools, the session had no server to give any of its agents, and that is the cause whatever a subagent's own transcript recorded: an agent definition cannot add a tool its session does not have. Only where neither is on record is the tool list the likely gap, and the durable fix the agent definition that spawned the context. And where the session's own transcript records its `SessionStart` hook unable to run the binary at all, that is why its server was missing, and it is said.
    private static func unreachableCauses(_ scans: [Scan]) -> [String] {
        let unreachable = scans.filter(\.tally.couldNotReachTheIndex)
        let lookups = { (group: [Scan]) in group.reduce(0) { $0 + $1.tally.scored.unreachable } }
        let serverDown = unreachable.filter(\.serverFailed)
        let sessionWithout = unreachable.filter { !$0.serverFailed && $0.sessionHeldNoIndexTools }
        let (down, without) = (lookups(serverDown), lookups(sessionWithout))
        let listed = lookups(unreachable.filter { !$0.serverFailed && !$0.sessionHeldNoIndexTools })
        let binaryMissing = lookups((serverDown + sessionWithout).filter(\.sessionBinaryMissing))

        var lines: [String] = []
        if down + without + listed > 0 {
            lines = [
                "  (a context that took \(TranscriptTally.refusalsWithoutAnIndexCall)+ refusals or undelivered calls and never once reached the index could not",
                "   reach it, and nor could one that never reached it whose transcript lists its tools with no sift among",
                "   them; the lookups of both are out of the share above.",
            ]
            if down > 0 {
                lines.append("   \(down) from contexts where the sift server failed to start or connect in that session: its")
                lines.append("   tools were never there to call. `claude mcp list` says whether it is running now, and a new")
                lines.append("   session connects afresh — no agent definition needs changing.")
            }
            if without > 0 {
                lines.append("   \(without) from contexts in a session whose own context never held sift's tools: the session had no")
                lines.append("   sift server to give them, so no agent definition needs changing — `claude mcp list` says whether")
                lines.append("   it is registered and running now, and a new session connects afresh.")
            }
            if binaryMissing > 0 {
                let which = binaryMissing == down + without ? "All \(binaryMissing)" : "\(binaryMissing) of those \(down + without)"
                lines.append("   \(which) were in a session whose SessionStart hook could not run the sift binary (exit 127):")
                lines.append("   it was not on disk when the session started, so its server could not start either —")
                lines.append("   install it, then start a new session.")
            }
            if listed > 0 {
                lines.append("   \(listed) from contexts with no server failure recorded, whose tool list has no sift in it —")
                lines.append("   the durable fix is the agent definition that spawned it, not anything here.")
            }
            lines[lines.count - 1] += ")"
        }
        // Said because the bucket above is the one place a reader looks for toolless contexts, and these are not in it.
        let onTheCLI = scans.count { $0.tally.recordedToolListWithoutIndex && $0.tally.cliCalls > 0 }
        if onTheCLI > 0 {
            let one = onTheCLI == 1
            lines.append("  (\(onTheCLI) context\(one ? "" : "s") held no sift MCP tools but ran the `sift` CLI, so the index was")
            lines.append("   within \(one ? "its" : "their") reach: \(one ? "it is" : "they are") not unreachable, and \(one ? "its" : "their") lookups stay in the share.)")
        }
        return lines
    }

    /// What the below-floor judgement rested on, stated wherever some of it rested on the disk rather than on the transcript.
    ///
    /// The transcript records the floor's decision only for files a whole-file digest answered; every other first touch is judged against the file as it stands now, which is not the file that was read. A file since deleted cannot be read, and is never counted below the floor, so it lands in whichever bucket the read would otherwise take — that is the conservative direction, but it is a guess about a number that is not known, and a reader has to be told how much of the count it touches.
    private static func floorProvenance(_ scans: [Scan]) -> [String] {
        let judged = scans.flatMap(\.floorFromDisk)
        guard !judged.isEmpty else { return [] }
        let gone = judged.count(where: { !FileManager.default.isReadableFile(atPath: $0) })
        let touches = "\(judged.count) first touch\(judged.count == 1 ? "" : "es")"
        let unknown = gone == 0 ? "" : " — \(gone) of those files cannot be read now, so whether they were under it is unknown and they count as over it"
        return [
            "  (below floor is taken from the file's own digest wherever the transcript holds one; \(touches) had",
            "   none, so the file on disk decided\(unknown))",
        ]
    }

    /// Cold searches counted by the call that would have answered them, most first, ties broken by verb so the report is stable across runs.
    ///
    /// Searches the advisors declined to classify are deliberately *not* folded in under a default. "No call could be named" and "the call was `search`" are different findings, and merging them would invent confidence the scan does not have; the report states the unclassified remainder as its own row instead.
    private static func missedCalls(in scans: [Scan]) -> [(call: MissedCall, count: Int)] {
        var counts: [MissedCall: Int] = [:]
        for entry in scans.flatMap(\.coldSearchEntries) {
            guard let missed = entry.missed else { continue }
            counts[missed, default: 0] += 1
        }
        return counts
            .sorted { ($0.value, $1.key.rawValue) > ($1.value, $0.key.rawValue) }
            .map { (call: $0.key, count: $0.value) }
    }

    /// The per-transcript gloss on a row's searches: `44 where, 12 search`, or empty when none was classified.
    private static func missedCallBreakdown(_ scan: Scan) -> String {
        let calls = missedCalls(in: [scan])
        guard !calls.isEmpty else { return "" }
        return " — " + calls.map { "\($0.count) \($0.call.rawValue)" }.joined(separator: ", ")
    }

    /// What failures are grouped by: the same tool failing two different ways is two findings, not one.
    fileprivate struct FailureKey: Hashable {
        let tool: String
        let kind: IndexFailure.Kind

        var sortKey: String {
            "\(tool)/\(kind.rawValue)"
        }
    }

    /// One grouped row as it accumulates: how many, which targets, and the last day one happened.
    fileprivate struct FailureGroup {
        var count = 0
        var targets: [String] = []
        var last: String?
    }
}

public extension TranscriptAudit {
    /// The index's share over the same sweep `render` reports on, as data rather than as a page of text.
    ///
    /// The `report` page needs the share and its trend and nothing else from the audit; giving it its own scanner would make two answers to "what share was this week", which is the divergence one-generator-per-value exists to stop. `render` and this go through the same walk.
    ///
    /// `root` scopes the transcripts exactly as a logged call's `root` field scopes `usage`: a transcript counts only when its recorded `cwd` is `root` itself or a directory beneath it. `nil` counts every transcript, which is what `render`'s callers — `audit` has no root of its own — get by never passing one.
    ///
    /// `suppressionLog` is read as `render` reads it, so the page's share is the audit's.
    ///
    /// `progress` is told what the sweep is doing, in lines a caller can print as they come, so a long scan is distinguishable from a stuck one.
    ///
    /// `tallyCache` holds each transcript's counts from an earlier run, keyed by path, size, modification date, window and build, so an unchanged transcript is not read again; `nil` reads every one. `now` is when the run happened, the date the cache counts its retention back from.
    static func tallies(projectsDirectory: URL, since: Date? = nil, now: Date = Date(), timeZone: TimeZone = .current, root: String? = nil, excludingScratch: Bool = false, suppressionLog: URL? = nil, tallyCache: TranscriptTallyCache? = nil, progress: @escaping (String) -> Void = { _ in }) -> Tallies {
        let snapshot = TranscriptSnapshot.take(projectsDirectory: projectsDirectory, since: since, transcript: nil)
        let store = tallyCache?.open(timeZone: timeZone, now: now)
        defer { store?.save(listing: snapshot, since: since) }
        let sweep = sweep(
            snapshot,
            since: since,
            timeZone: timeZone,
            datesEveryLookup: true,
            root: root,
            excludingScratch: excludingScratch,
            suppressionLog: suppressionLog,
            cache: store,
            progress: progress
        )
        var totals = TranscriptTally()
        var byDay: [String: TranscriptTally] = [:]
        for scan in sweep.active {
            totals += scan.tally.scored
            // Each day's slice is scored on the verdict for the whole context, not on its own counters: a
            // context has the index or it has not, and a day on which it happened to make no call is not a
            // day on which it had none to make.
            for (day, tally) in scan.byDay {
                byDay[day, default: TranscriptTally()] += tally.scored(inContext: scan.tally)
            }
        }
        return Tallies(
            totals: totals,
            sessions: Set(sweep.active.map(\.session)).count,
            transcripts: sweep.transcripts.count,
            byDay: byDay.keys.sorted().map { DayTally(day: $0, tally: byDay[$0] ?? TranscriptTally()) }
        )
    }

    /// The rendered audit over `snapshot`, and each context's counts behind it, dated by day, for the replay beside it to print as the audit's own share.
    ///
    /// Every argument is read as `render` reads it, `progress` included; the counts are those the text was rendered from, so the replay's "audit's own" figures are the audit section's to the lookup rather than a second scan's.
    static func renderWithTallies(
        projectsDirectory: URL,
        snapshot: TranscriptSnapshot,
        since: Date? = nil,
        until: Date? = nil,
        roots: [String] = [],
        timeZone: TimeZone = .current,
        redactor: Redactor? = nil,
        root: String? = nil,
        suppressionLog: URL? = nil,
        summary: Bool = false,
        usageLog: URL? = nil,
        transcript: String? = nil,
        progress: @escaping (String) -> Void = { _ in }
    ) -> (text: String, tallies: AuditTallies) {
        let sweep = sweep(
            snapshot,
            since: since,
            until: until,
            timeZone: timeZone,
            datesEveryLookup: true,
            root: root,
            suppressionLog: suppressionLog,
            progress: progress
        )
        let saving = usageLog.flatMap { AuditLoggedSaving.line($0, since: since, until: until, root: root, transcript: transcript) }
        let text = rendered(sweep, directory: projectsDirectory, since: since, until: until, timeZone: timeZone, roots: roots, redactor: redactor, root: root, summary: summary, saving: saving)
        return (text, AuditTallies(sweep.scans))
    }

    /// What a transcript sweep counted: the window's totals, and the same counts per day.
    struct Tallies: Sendable, Equatable {
        public let totals: TranscriptTally

        /// Sessions that made at least one Swift lookup in the window — a subagent counts under its parent.
        public let sessions: Int

        /// Transcripts in scope, whether or not they contributed — every transcript when there is no root, and only those inside it otherwise.
        public let transcripts: Int

        /// One row per local day a lookup landed on, oldest first.
        public let byDay: [DayTally]
    }

    /// One day's counts.
    struct DayTally: Sendable, Equatable {
        public let day: String
        public let tally: TranscriptTally
    }
}

// MARK: - Root scope

extension TranscriptAudit {
    /// Whether `url`'s recorded working directory places it inside `root` — every transcript when `root` is `nil`, and otherwise only one whose `cwd` is `root` itself or a directory beneath it, canonically compared so a differently-cased or symlinked spelling still matches (the same rule `LogScope` compares a logged call's `root` field by).
    ///
    /// The scratch exclusion additionally drops a transcript whose recorded `cwd` is a scratch root (``ScratchRoot``), so the report's share is real sessions only, as its call counts are; a transcript recording no `cwd` is kept.
    static func inScope(_ url: URL, root: String?, excludingScratch: Bool = false) -> Bool {
        let recordedCwd = (root != nil || excludingScratch) ? TranscriptWorkingDirectory.of(transcriptAt: url) : nil
        if excludingScratch, let recordedCwd, ScratchRoot.contains(recordedCwd) {
            return false
        }
        guard let root else { return true }
        guard let recordedCwd else { return false }
        return CanonicalPath.of(recordedCwd).isWithin(root)
    }
}
