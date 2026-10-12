//
// Copyright © Agulhas Labs
//

import Foundation
import SiftCore

/// Renders `usage.jsonl` as the adoption review it exists to feed (Docs/Design.md §4): calls by tool, root, and day, latency percentiles, and the top targets — what the codebase is repeatedly asked about.
///
/// Reading, scoping and aggregating the log belong to ``UsageScan``; this is the text face over it. `report` is the other, and neither counts anything for itself.
public struct UsageReport {
    /// The rendered report for the log at `fileURL`, or an honest empty-state line.
    ///
    /// `since` (an inclusive `YYYY-MM-DD`) and `root` narrow it. Both are stated in the header when set, because a filtered count read as a global one is the same misreading the log already invites — 17 calls is a very different claim scoped to a day than to five days.
    ///
    /// `runFileURL` adds the wrapped-run section when there is one to add. Optional rather than defaulted to the standard path so a test asking about a log it wrote cannot pick up whatever this machine happens to have run.
    ///
    /// `allRoots` prints every root `by root:` groups, not just the top 5 — a machine used against many repositories otherwise buries the section in one pseudonymised line per root, none of them the ones that mattered.
    public static func render(
        fileURL: URL,
        runFileURL: URL? = nil,
        since: String? = nil,
        root: String? = nil,
        redactor: Redactor? = nil,
        allRoots: Bool = false,
        includeScratch: Bool = false
    ) -> String {
        let logPath = redactor == nil ? fileURL.path : Redactor.tilded(fileURL.path)
        // One argument, one directory: resolved against both logs' roots together, before either is
        // scanned. A refusal ends the report here rather than falling through to the run section, because a
        // run count printed beneath "name one of these" is the tool guessing precisely where it has just
        // said it will not.
        let rootScope: LogScope?
        switch LogScope.resolve(root, inLogsAt: [fileURL] + [runFileURL].compactMap(\.self)) {
        case let .success(resolved):
            rootScope = resolved
        case let .failure(problem):
            return message(for: problem, logPath: logPath, redactor: redactor)
        }
        // Assembled up front so it survives the two early exits below. A machine that wraps its builds but
        // has not queried the index would otherwise be told there is no usage to report while its own runs
        // sat unmentioned in a file this command is the reader for.
        let runs = runSection(runFileURL, since: since, scope: rootScope, redactor: redactor)
        let scan: UsageScan
        switch UsageScan.load(fileURL: fileURL, since: since, scope: rootScope, includeScratch: includeScratch) {
        case let .success(loaded):
            scan = loaded
        case let .failure(problem):
            return ([message(for: problem, logPath: logPath, redactor: redactor)] + runs).joined(separator: "\n")
        }

        var scope: [String] = []
        if let since {
            scope.append("since \(since)")
        }
        if let resolvedRoot = scan.resolvedRoot {
            // "under" whenever anything below it contributed, so a subtree total is never read as one repo's.
            scope.append("\(scan.sweptSubtree ? "under" : "in") \(redactor?.root(resolvedRoot) ?? resolvedRoot)")
        }
        let scopeSuffix = scope.isEmpty ? "" : " (\(scope.joined(separator: ", ")))"

        let entries = scan.entries
        guard !entries.isEmpty else {
            return (["no calls recorded\(scopeSuffix) — \(scan.logged) in the log overall", "log: \(logPath)"] + [scan.scratchNote].compactMap(\.self) + runs)
                .joined(separator: "\n")
        }

        let failures = entries.filter { !$0.succeeded }.count
        let days = entries.map(\.day).sorted()
        // Failures ahead of calls (Docs/AnswerContract.md §2): the call count only ever rises, and leading with it
        // reads as adoption whatever the failure count beside it says.
        var lines = [
            "usage — \(failures) failure\(failures == 1 ? "" : "s"), \(entries.count) call\(entries.count == 1 ? "" : "s")\(scopeSuffix), "
                + "\(days.first ?? "?") → \(days.last ?? "?")\(sessionClause(entries))",
            "log: \(logPath)",
            // What a call is, against what `audit` counts, so the two numbers are not read as one count that disagrees.
            "counted: one call per answer sift logged, failures and Markdown outlines included; "
                + "sift audit counts the transcripts' Swift lookups by any route instead, the ones sift served among them",
        ]
        if scan.malformed > 0 {
            lines.append("(\(scan.malformed) malformed line\(scan.malformed == 1 ? "" : "s") skipped)")
        }
        if let note = scan.scratchNote {
            lines.append(note)
        }
        lines.append(contentsOf: savingsSection(scan.savings))
        if let savings = scan.savings, let gross = grossNote(savings: savings) {
            lines.append(gross)
        }
        // Last of the saving block, under the subagent line (a share of the total) so that line never reads as a
        // share of this one; and printed whether or not any code call measured, so a window of only Markdown
        // outlines does not look as though nothing was measured. The note carries its own count.
        if let markdown = scan.markdown {
            lines.append(contentsOf: scan.savings == nil ? [""] : [])
            lines.append("        \(markdown.note)")
        }

        lines.append("")
        lines.append("by tool:")
        // Latency is the server's alone. A lookup another face served — the advice hook answering in place, or a
        // query subcommand run from a shell — is timed from a fresh process, the engine opened and the index
        // checked inside it, so its milliseconds measure something else, and folded in they would move the
        // server's percentiles without the server having changed. Counted in the tally beside them all the same:
        // the count is lookups, and every face's lookup is one.
        for (tool, group) in scan.grouped(by: \.tool) {
            let sorted = group.filter { $0.via == nil }.map(\.milliseconds).sorted()
            let failed = group.filter { !$0.succeeded }.count
            let latency = sorted.isEmpty ? "p50 —     p90 —" : "p50 \(UsageScan.percentile(sorted, 50))ms   p90 \(UsageScan.percentile(sorted, 90))ms"
            var line = "  \(tool.padding(toLength: 9, withPad: " ", startingAt: 0)) \(String(group.count).leftPadded(4))   \(latency)"
            if failed > 0 {
                line += "   \(failed) failed"
            }
            lines.append(line)
        }
        // Named face by face rather than as one "not the server" total: they are answered in different places for
        // different reasons, and a reader checking whether the CLI is used at all has no other line to read it off.
        let elsewhere = [
            (calls: entries.count { $0.via == "hook" }, where: "in place by the advice hook"),
            (calls: entries.count { $0.via == "cli" }, where: "on the CLI"),
        ].filter { $0.calls > 0 }
        if !elsewhere.isEmpty {
            lines.append("  answered elsewhere: \(elsewhere.map { "\($0.calls) \($0.where)" }.joined(separator: ", ")) "
                + "— counted above, left out of p50/p90, since their time includes opening the index")
        }

        lines.append(contentsOf: callerSection(scan))

        let failureGroups = scan.failureGroups
        if !failureGroups.isEmpty {
            lines.append("")
            lines.append("failures:")
            // Reasons are near-unique (most name the symbol asked about), so the cap keeps a bad week from
            // swamping the report — the log line itself still holds every one.
            for group in failureGroups.prefix(10) {
                // The placeholder for a reasonless entry carries no name and stays readable either way.
                let displayed = group.isRecorded ? (redactor?.reason(group.reason) ?? group.reason) : group.reason
                lines.append("  \(String(group.count).leftPadded(4))  \(displayed)")
            }
            if failureGroups.count > 10 {
                lines.append("  … and \(failureGroups.count - 10) more distinct reasons")
            }
        }

        lines.append("")
        lines.append("by root:")
        let rootGroups = scan.grouped(by: \.root)
        let shownRootGroups = allRoots ? rootGroups : Array(rootGroups.prefix(5))
        for (root, group) in shownRootGroups {
            lines.append("  \(String(group.count).leftPadded(4))  \(redactor?.root(root) ?? root)")
        }
        let hiddenRootGroups = rootGroups.dropFirst(shownRootGroups.count)
        if !hiddenRootGroups.isEmpty {
            let hiddenCalls = hiddenRootGroups.reduce(0) { $0 + $1.1.count }
            lines.append("  … and \(hiddenRootGroups.count) more root\(hiddenRootGroups.count == 1 ? "" : "s") (\(hiddenCalls) call\(hiddenCalls == 1 ? "" : "s"))")
        }

        lines.append("")
        lines.append("by day:")
        for (day, group) in scan.grouped(by: \.day).sorted(by: { $0.0 < $1.0 }) {
            lines.append("  \(day)  \(group.count)")
        }

        lines.append("")
        lines.append("top targets:")
        for target in scan.topTargets(naming: { redactor?.target($0) ?? $0 }).prefix(10) {
            lines.append("  \(String(target.count).leftPadded(4))  \(target.label)")
        }

        lines.append(contentsOf: runs)
        return lines.joined(separator: "\n")
    }

    /// What the measured calls are estimated to have saved, and everything that keeps that figure from being read as a total.
    ///
    /// A block rather than a single sentence, because one ratio over one population leaves three facts unsaid: the absolute — the question anyone actually asks of a savings figure is *how much*, and a percentage cannot answer it; the calls the tool deliberately declined to compress, which sit inside the same ratio dragging it down; and the calls that measure nothing at all, whose silence makes the figure a floor without ever saying so.
    ///
    /// The two-row split appears only when both sides have calls in them. One side alone would print the total twice under different labels, which reads as corroboration and is in fact one number said again.
    private static func savingsSection(_ savings: UsageScan.Savings?) -> [String] {
        guard let savings else { return [] }
        var lines = ["", "estimated savings — \(savings.headline)"]
        for row in savings.split + [savings.total] {
            lines.append(
                "  \(String(row.calls).leftPadded(4))  \(row.label.padding(toLength: 14, withPad: " ", startingAt: 0))"
                    + "\(ByteSize.short(row.source).leftPadded(8)) → \(ByteSize.short(row.served).leftPadded(8))   \(row.outcome)"
            )
        }
        if let unpriced = savings.unpriced {
            lines.append("  \(String(unpriced.calls).leftPadded(4))  \(unpriced.note)")
        }
        // Under the rows rather than among them: it is a share of the total above, not a population beside it,
        // and a row would invite it to be added to them.
        if let subagents = savings.subagents {
            lines.append("  \(String(subagents.row.calls).leftPadded(4))  \(subagents.note)")
        }
        return lines
    }

    /// Why the saving above is gross, or `nil` where nothing was saved.
    ///
    /// The log records what each answer served and what the read it stood in for asked for, and what the context did next only where the hook let a re-run or a whole read of the file through (a `readAnyway` line, which takes that answer back). A read the hook never judged is in the transcripts alone, so this line says the figure is gross and points at `sift audit`, which counts those reads beside the same figure (Docs/Design.md).
    private static func grossNote(savings: UsageScan.Savings) -> String? {
        guard savings.savedText != nil else { return nil }
        return "        the figure above is gross: an answer whose file was then read whole anyway is taken back only by a re-run or whole read "
            + "the hook let through; sift audit counts those reads"
    }

    /// The sessions the calls in scope came from, in `audit`'s words — `, from 1 session (+2 subagents)` — with the calls that named no session counted beside them, or nothing where no call named one.
    ///
    /// A subagent's call carries its parent's session, so the sessions are the parents and the subagents are the distinct callers a hook named, a floor for the reason ``callerSection(_:)`` gives.
    private static func sessionClause(_ entries: [UsageScan.Entry]) -> String {
        let named = entries.filter { $0.session != nil }
        guard !named.isEmpty else { return "" }
        let count = SessionCount(sessions: Set(named.compactMap(\.session)).count, subagents: Set(named.compactMap(\.agent)).count)
        let unnamed = entries.count - named.count
        return ", from \(count.spelled)" + (unnamed == 0 ? "" : " and \(unnamed) call\(unnamed == 1 ? "" : "s") naming no session")
    }

    /// Who made the calls in scope, or nothing at all where nothing names a caller.
    ///
    /// Rendered only when something is attributed, like the run section and for the same reason: a machine with no `PreToolUse` hook would otherwise be shown a standing "0 subagents" that says nothing about it. **Two rows and not a split**, because the second is not a population — `nil` covers a session's own call, a machine with no hook, a slip that could not be claimed, and every line older than its face's naming of callers, and naming that is the difference between a floor and a false partition.
    ///
    /// **The leading number is calls and the row says so**, matching `UsageScan.Savings.Attributed` and the HTML page. Pluralising on the count of agents is only half of it: `12  subagent (1 distinct)` still reads as twelve subagents at a glance, because the only noun beside the number is the one naming who made the calls rather than the calls themselves. Naming the unit is what settles it — `12  calls by 1 subagent` carries both counts, each against the word it belongs to.
    private static func callerSection(_ scan: UsageScan) -> [String] {
        let attributed = scan.entries.filter { $0.agent != nil }
        guard !attributed.isEmpty else { return [] }
        let agents = Set(attributed.compactMap(\.agent)).count
        let rest = scan.entries.count - attributed.count
        return [
            "",
            "by caller:",
            "  \(String(attributed.count).leftPadded(4))  calls by \(agents) subagent\(agents == 1 ? "" : "s")",
            "  \(String(rest).leftPadded(4))  not attributed to a subagent — this session's own calls, and any "
                + "call no hook was present for, including every call recorded before its face named callers",
        ]
    }

    /// The wrapped-run section, or nothing at all when the window holds no runs.
    ///
    /// **Last, and under its own heading with its own log path**, because the headline above says "N calls" and that number means index lookups, whichever face served them. A run is not a lookup — that is the whole reason it keeps a separate file — so anything that could let the two be added together, or let one be read as a share of the other, is a wrong answer in the same shape as folding the logs would have been.
    ///
    /// Rendered only when there is something to render, rather than as a standing zero: a machine that has never wrapped a build should see no section, not a section reporting nothing.
    private static func runSection(_ fileURL: URL?, since: String?, scope: LogScope?, redactor: Redactor?) -> [String] {
        guard let fileURL,
              let summary = RunScan.load(fileURL: fileURL, since: since, scope: scope).summary
        else {
            return []
        }
        var lines = [
            "",
            "runs (sift run — wrapped commands, not index calls):",
            "  \(summary.runs) run\(summary.runs == 1 ? "" : "s"), \(summary.days.first ?? "?") → \(summary.days.last ?? "?"), \(summary.nonzeroExits) nonzero exit\(summary.nonzeroExits == 1 ? "" : "s")",
        ]
        for kind in summary.kinds {
            lines.append("  \(String(kind.count).leftPadded(4))  \(kind.kind)")
        }
        if let sentence = summary.sentence {
            lines.append("  \(sentence)")
        }
        lines.append("  log: \(redactor == nil ? fileURL.path : Redactor.tilded(fileURL.path))")
        return lines
    }

    /// The line a log that cannot be read gets, in the wording the summary has always used.
    ///
    /// The two root refusals say "logs", plural: the argument is resolved against the calls and the runs together, so the candidates listed are drawn from both and neither section is rendered beneath the refusal.
    ///
    /// Their candidates are spelled as the rest of the report spells a root — pseudonymised unless the reader asked otherwise. Printed as absolute paths, this refusal would be the one part of a report advertised as safe to share that publishes, on a mistyped `--root`, every repository on the machine, the username above them, and on a machine holding more than one person's checkouts, another person's repository names.
    private static func message(for problem: UsageScan.Problem, logPath: String, redactor: Redactor?) -> String {
        switch problem {
        case .missingOrEmpty:
            "no usage recorded yet — \(logPath) is missing or empty"
        case let .unreadable(malformed):
            "no readable entries in \(logPath) (\(malformed) malformed line\(malformed == 1 ? "" : "s"))"
        case let .rootUnmatched(argument, roots):
            "nothing recorded for a root matching \(argument). Roots in the logs:\n"
                + listed(roots, redactor: redactor)
        case let .rootAmbiguous(argument, matches):
            "\(argument) matches \(matches.count) paths in the logs — name one:\n"
                + listed(matches, redactor: redactor)
        }
    }

    /// One candidate directory per line, spelled as this reader is allowed to see it.
    private static func listed(_ paths: [String], redactor: Redactor?) -> String {
        LogScope.spellings(of: paths, redacted: redactor != nil)
            .map { "  \($0)" }
            .joined(separator: "\n")
    }
}
