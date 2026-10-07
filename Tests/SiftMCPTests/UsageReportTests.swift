//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftMCP
import Testing

/// Covers the usage summariser: aggregation, ordering, latency percentiles, and tolerance of a damaged log.
@Suite(.temporaryDirectories)
struct UsageReportTests {
    private static func writeLog(_ lines: [String]) throws -> URL {
        let file = try TemporaryDirectory.make("usage")
            .appendingPathComponent("usage.jsonl")
        try (lines.joined(separator: "\n") + "\n").write(to: file, atomically: true, encoding: .utf8)
        return file
    }

    private static func entry(tool: String, target: String? = nil, root: String = "/repo/a", ms: Int = 10, succeeded: Bool = true, error: String? = nil, timestamp: String = "2026-07-30T10:00:00Z", bytes: (out: Int, source: Int)? = nil, served: Int? = nil, agent: String? = nil, via: String? = nil) -> String {
        var object: [String: Any] = ["tool": tool, "root": root, "ms": ms, "ok": succeeded, "ts": timestamp]
        object["via"] = via
        if let target {
            object["target"] = target
        }
        if let agent {
            object["agent"] = agent
        }
        if let error {
            object["err"] = error
        }
        if let bytes {
            object["outBytes"] = bytes.out
            object["srcBytes"] = bytes.source
        }
        // The half a line carries when the answer had no denominator to weigh itself against — every tool
        // records this, and it is the only byte field a `where` or `search` line has ever held.
        if let served {
            object["outBytes"] = served
        }
        let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return String(data: data ?? Data(), encoding: .utf8) ?? ""
    }

    /// The attributed row of `by caller:` on its own, so an assertion about that row is about that row and not about every line in the report.
    private static func callerRow(of report: String) -> String? {
        report.split(separator: "\n").map(String.init).first { $0.contains("calls by") }
    }

    @Test
    func aggregatesByToolRootDayAndTarget() throws {
        let file = try Self.writeLog([
            Self.entry(tool: "digest", target: "Widget", ms: 20, timestamp: "2026-07-28T09:00:00Z"),
            Self.entry(tool: "digest", target: "Widget", ms: 40, timestamp: "2026-07-29T09:00:00Z"),
            Self.entry(tool: "digest", target: "Engine", root: "/repo/b", ms: 60, timestamp: "2026-07-29T10:00:00Z"),
            Self.entry(tool: "where", target: "Widget", ms: 1000, succeeded: false, timestamp: "2026-07-30T11:00:00Z"),
        ])

        let report = UsageReport.render(fileURL: file)

        #expect(report.contains("usage — 1 failure, 4 calls, 2026-07-28 → 2026-07-30"))
        #expect(report.contains("digest"))
        #expect(report.contains("p50 40ms"))
        #expect(report.contains("1 failed"))
        #expect(report.contains("   3  /repo/a"))
        #expect(report.contains("2026-07-29  2"))
        #expect(report.contains("   2  digest Widget"))
        #expect(report.contains("   1  where Widget"))
    }

    /// The criterion the tool is judged on is whether it works for subagents, and without callers recorded it cannot evidence one call of it.
    @Test
    func theSummaryNamesTheWorkASubagentDid() throws {
        let file = try Self.writeLog([
            Self.entry(tool: "digest", target: "Widget", bytes: (out: 400, source: 4000), agent: "adae5f77"),
            Self.entry(tool: "digest", target: "Engine", bytes: (out: 200, source: 2000), agent: "bb19c2d0"),
            Self.entry(tool: "digest", target: "Rail", bytes: (out: 100, source: 1000)),
        ])

        let report = UsageReport.render(fileURL: file)

        #expect(report.contains("by caller:"))
        #expect(Self.callerRow(of: report) == "     2  calls by 2 subagents")
        #expect(report.contains("   1  not attributed to a subagent"))
        // A share of the figure above it, stated as a floor and saying what it is a floor of.
        #expect(report.contains("is work 2 subagents did — a floor"))
    }

    /// One subagent is a subagent, on this row as on the HTML page and in the note under the savings — and the number in front of it is calls, which the row has to say rather than leave to the noun beside it.
    ///
    /// Both halves are one defect: `12  subagent (1 distinct)` pluralises correctly and still reads as twelve subagents, because nothing in the row names what the twelve counts.
    @Test
    func oneSubagentIsNamedInTheSingularAndTheCountInFrontOfItIsCalls() throws {
        let file = try Self.writeLog([
            Self.entry(tool: "digest", target: "Widget", bytes: (out: 400, source: 4000), agent: "adae5f77"),
            Self.entry(tool: "digest", target: "Engine", bytes: (out: 200, source: 2000), agent: "adae5f77"),
            Self.entry(tool: "digest", target: "Rail", bytes: (out: 100, source: 1000)),
        ])

        let report = UsageReport.render(fileURL: file)

        // Asserted as the whole row rather than as a negative over the whole report: `!report.contains("subagents (")`
        // held for the right reason here and would have failed for a wrong one the moment any other row was
        // legitimately plural.
        #expect(Self.callerRow(of: report) == "     2  calls by 1 subagent")
        // The note under the savings reads this way too, so the row and the note agree.
        #expect(report.contains("is work 1 subagent did — a floor"))
    }

    /// A machine with no `PreToolUse` hook attributes nothing, and must be shown nothing rather than a standing zero that reads as a finding about it.
    @Test
    func aLogThatNamesNoCallerCarriesNoCallerSection() throws {
        let file = try Self.writeLog([
            Self.entry(tool: "digest", target: "Widget", bytes: (out: 400, source: 4000)),
        ])

        let report = UsageReport.render(fileURL: file)

        #expect(!report.contains("by caller:"))
        #expect(!report.contains("subagent"))
    }

    /// Failures group by their recorded reason, so a week's worth reads as causes rather than a count to go re-run.
    @Test
    func failuresAreGroupedByRecordedReason() throws {
        let file = try Self.writeLog([
            Self.entry(tool: "digest", target: "Widget"),
            Self.entry(tool: "search", target: "worktree", succeeded: false, error: "\"worktree\" is not field:value"),
            Self.entry(tool: "search", target: "statusline", succeeded: false, error: "\"worktree\" is not field:value"),
            Self.entry(tool: "where", target: "Ghost", succeeded: false),
        ])

        let report = UsageReport.render(fileURL: file)

        #expect(report.contains("failures:"))
        #expect(report.contains("   2  \"worktree\" is not field:value"))
        #expect(report.contains("   1  (no reason recorded — entry predates the err field)"))
    }

    /// No failures, no section — the report only grows where there is something to say.
    @Test
    func anAllGreenLogHasNoFailuresSection() throws {
        let file = try Self.writeLog([Self.entry(tool: "digest", target: "Widget")])

        #expect(!UsageReport.render(fileURL: file).contains("failures:"))
    }

    @Test
    func malformedLinesAreCountedNotFatal() throws {
        let file = try Self.writeLog([
            Self.entry(tool: "digest", target: "Widget"),
            "{ half a line",
            "not json",
        ])

        let report = UsageReport.render(fileURL: file)

        #expect(report.contains("usage — 0 failures, 1 call"))
        #expect(report.contains("(2 malformed lines skipped)"))
    }

    @Test
    func missingLogGetsAnHonestEmptyState() {
        let report = UsageReport.render(fileURL: URL(fileURLWithPath: "/nonexistent/usage.jsonl"))

        #expect(report.contains("no usage recorded yet"))
    }

    private static func mixedLog() throws -> URL {
        try writeLog([
            entry(tool: "digest", target: "Old", root: "/repo/a", timestamp: "2026-07-28T09:00:00Z"),
            entry(tool: "digest", target: "Recent", root: "/repo/a", timestamp: "2026-07-30T09:00:00Z"),
            entry(tool: "where", target: "Recent", root: "/work/Orchard/app", timestamp: "2026-07-30T10:00:00Z"),
        ])
    }

    @Test
    func sinceKeepsOnlyDaysOnOrAfterIt() throws {
        let report = try UsageReport.render(fileURL: Self.mixedLog(), since: "2026-07-30")

        #expect(report.contains("usage — 0 failures, 2 calls (since 2026-07-30)"))
        #expect(!report.contains("digest Old"))
        #expect(report.contains("digest Recent"))
    }

    @Test
    func rootNarrowsToOneRepository() throws {
        let report = try UsageReport.render(fileURL: Self.mixedLog(), root: "/repo/a")

        #expect(report.contains("usage — 0 failures, 2 calls (in /repo/a)"))
        #expect(!report.contains("/work/Orchard/app"))
    }

    @Test
    func aTrailingPathFragmentResolvesToTheFullRoot() throws {
        // The point of the shorthand: answering "what happened in Orchard" without typing the whole path.
        let report = try UsageReport.render(fileURL: Self.mixedLog(), root: "Orchard/app")

        #expect(report.contains("in /work/Orchard/app"))
        #expect(report.contains("usage — 0 failures, 1 call"))
    }

    @Test
    func anAmbiguousFragmentAsksRatherThanPickingARepository() throws {
        let file = try Self.writeLog([
            Self.entry(tool: "digest", root: "/one/app"),
            Self.entry(tool: "digest", root: "/two/app"),
        ])

        let report = UsageReport.render(fileURL: file, root: "app")

        #expect(report.contains("matches 2 paths"))
        #expect(report.contains("/one/app"))
        #expect(report.contains("/two/app"))
    }

    @Test
    func aParentDirectoryReportsTheReposBeneathIt() throws {
        // The everyday shorthand: calls are logged against the app checkout, but the product is what gets
        // typed. Refusing this reads as "nothing has used the tool here", which is a wrong answer, not a
        // narrow one.
        let file = try Self.writeLog([
            Self.entry(tool: "digest", root: "/work/Depot/app"),
            Self.entry(tool: "where", root: "/work/Depot/app"),
        ])

        let report = UsageReport.render(fileURL: file, root: "Depot")

        #expect(report.contains("usage — 0 failures, 2 calls (under /work/Depot)"))
    }

    @Test
    func aRootAlsoCountsTheCallsLoggedBeneathIt() throws {
        // A stray call filed against the product folder itself must not shadow the checkout below it: an
        // exact-path match would skip the subtree and report 2 real calls as none.
        let file = try Self.writeLog([
            Self.entry(tool: "digest", root: "/work/Depot"),
            Self.entry(tool: "digest", root: "/work/Depot/app"),
            Self.entry(tool: "where", root: "/work/Depot/app"),
        ])

        let report = UsageReport.render(fileURL: file, root: "Depot")

        #expect(report.contains("usage — 0 failures, 3 calls (under /work/Depot)"))
    }

    @Test
    func aSiblingSharingANamePrefixIsNotSweptIn() throws {
        // Containment is by path component, not by string prefix.
        let file = try Self.writeLog([
            Self.entry(tool: "digest", root: "/work/Depot/app"),
            Self.entry(tool: "digest", root: "/work/DepotOld"),
        ])

        let report = UsageReport.render(fileURL: file, root: "/work/Depot")

        #expect(report.contains("usage — 0 failures, 1 call (under /work/Depot)"))
        #expect(!report.contains("DepotOld"))
    }

    @Test
    func anUnknownRootSaysSoAndListsTheRealOnes() throws {
        // A typo and genuine silence render identically otherwise, and one of those is a wrong answer to
        // "is anything using this".
        let report = try UsageReport.render(fileURL: Self.mixedLog(), root: "/repo/typo")

        // "the logs", plural: one argument is resolved against the calls and the runs together, so the
        // candidates listed are drawn from both and neither section renders beneath the refusal.
        #expect(report.contains("nothing recorded for a root matching /repo/typo. Roots in the logs:"))
        #expect(report.contains("/repo/a"))
    }

    @Test
    func anEmptyWindowSaysHowManyItFilteredOut() throws {
        let report = try UsageReport.render(fileURL: Self.mixedLog(), since: "2026-08-05")

        #expect(report.contains("no calls recorded (since 2026-08-05)"))
        #expect(report.contains("3 in the log overall"))
    }

    @Test
    func bothFiltersComposeAndBothAreStated() throws {
        let report = try UsageReport.render(fileURL: Self.mixedLog(), since: "2026-07-30", root: "/repo/a")

        #expect(report.contains("usage — 0 failures, 1 call (since 2026-07-30, in /repo/a)"))
    }

    /// Savings are summed on both sides, and said to be measured over the calls that measured anything.
    ///
    /// A mean of per-call ratios would read 30% here, letting the tiny answer — the shape a digest compresses worst — outweigh the large one the tool exists for. And a report that stated 11% without naming the two calls it came from would be read as a claim about all three.
    @Test
    func savingsSumBothSidesAndStateHowManyCallsTheyWereMeasuredOver() throws {
        let file = try Self.writeLog([
            Self.entry(tool: "digest", target: "Small", bytes: (out: 10, source: 20)),
            Self.entry(tool: "digest", target: "Big", bytes: (out: 100, source: 1000)),
            Self.entry(tool: "where", target: "Big"),
        ])

        let report = UsageReport.render(fileURL: file)

        #expect(report.contains("digest served 11% of the source it replaced (measured over 2 of 3 calls)"))
    }

    /// A saving too large to round to anything is still not free, and printing 0% claims it was.
    ///
    /// The strongest number the tool can produce is the one most likely to be disbelieved, and "served 0% of the source it replaced" is a claim no measurement supports — the answer cost bytes, and `<1%` says both that it was small and that it was not nothing.
    @Test
    func aSavingTooLargeToRoundIsPrintedAsUnderOnePercentNotAsFree() throws {
        let file = try Self.writeLog([Self.entry(tool: "digest", target: "Enormous", bytes: (out: 200, source: 90000))])

        let scan = try #require(try? UsageScan.load(fileURL: file).get())
        let savings = try #require(scan.savings)

        #expect(savings.percent == 0)
        #expect(savings.percentText == "<1%")
        #expect(UsageReport.render(fileURL: file).contains("digest served <1% of the source it replaced"))
    }

    /// A denominator that is mostly log age says so, rather than leaving it to read as sampling.
    ///
    /// "Measured over 1 of 3 calls" invites the reading that most answers declined to weigh themselves; what happened is that the fields were added on a day inside the window and everything before it is older than the measurement.
    @Test
    func aWindowReachingBackPastTheFieldsNamesTheDayTheyStarted() throws {
        let file = try Self.writeLog([
            Self.entry(tool: "digest", target: "Old", timestamp: "2026-08-10T09:00:00Z"),
            Self.entry(tool: "digest", target: "Older", timestamp: "2026-08-11T09:00:00Z"),
            Self.entry(tool: "digest", target: "Now", timestamp: "2026-08-18T09:00:00Z", bytes: (out: 100, source: 1000)),
        ])

        let report = UsageReport.render(fileURL: file)

        #expect(report.contains("(measured over 1 of 3 calls — fields recorded since 2026-08-18)"))
    }

    /// A tool that never measures is not evidence the log predates the fields, and must not date them.
    ///
    /// `where` and `search` stand in for a grep rather than a run of source, so they carry no bytes by design. Explaining the denominator with an onset day on their account would attribute it to something that is not its cause.
    @Test
    func anUnmeasuredCallFromANonMeasuringToolDoesNotDateTheFields() throws {
        let file = try Self.writeLog([
            // Deliberately on a day *before* the first measured call: on the same day the day filter alone
            // withholds the note, and the test would pass without the tool ever being consulted.
            Self.entry(tool: "where", target: "Widget", timestamp: "2026-08-17T08:00:00Z"),
            Self.entry(tool: "digest", target: "Now", timestamp: "2026-08-18T09:00:00Z", bytes: (out: 100, source: 1000)),
        ])

        let report = UsageReport.render(fileURL: file)

        #expect(report.contains("(measured over 1 of 2 calls)"))
        #expect(!report.contains("fields recorded since"))
    }

    /// A call that failed measured nothing because it answered nothing, and is no evidence the log predates the fields.
    ///
    /// The same wrong-cause error as the test above, arriving down the one path `tool` cannot filter: a refusal replaces no source, so a failed `digest` records no bytes under whatever version wrote it. Dating the onset on it explains the denominator with a day that proves only that something went wrong.
    @Test
    func aFailedCallBeforeTheFirstMeasuredOneDoesNotDateTheFields() throws {
        let file = try Self.writeLog([
            Self.entry(
                tool: "digest",
                target: "Missing",
                succeeded: false,
                error: "no type named Missing",
                timestamp: "2026-08-17T08:00:00Z"
            ),
            Self.entry(tool: "digest", target: "Now", timestamp: "2026-08-18T09:00:00Z", bytes: (out: 100, source: 1000)),
        ])

        let report = UsageReport.render(fileURL: file)

        #expect(report.contains("(measured over 1 of 2 calls)"))
        #expect(!report.contains("fields recorded since"))
    }

    /// Lines written before the fields existed read as unmeasured calls, not as savings of nothing.
    @Test
    func aLogWithNothingMeasuredCarriesNoSavingsLine() throws {
        let file = try Self.writeLog([
            Self.entry(tool: "digest", target: "Widget"),
            Self.entry(tool: "where", target: "Widget"),
        ])

        #expect(!UsageReport.render(fileURL: file).contains("of the source it replaced"))
    }

    /// Three generations of log line coexist, and each reads as what it is.
    ///
    /// The byte fields arrived in two rounds — the pair for `digest` first, the served size for every tool later — so a log spanning both holds lines carrying neither, lines carrying both, and lines carrying only the numerator. A reader that took the served size as evidence of a measurement would fold a `where` call into the compression ratio with no denominator at all.
    @Test
    func aServedSizeWithoutASourceIsNotAMeasurement() throws {
        let file = try Self.writeLog([
            Self.entry(tool: "digest", target: "Ancient", timestamp: "2026-08-01T09:00:00Z"),
            Self.entry(tool: "digest", target: "Measured", timestamp: "2026-08-18T09:00:00Z", bytes: (out: 100, source: 1000)),
            Self.entry(tool: "where", target: "Looked up", timestamp: "2026-08-27T09:00:00Z", served: 4000),
        ])

        let scan = try #require(try? UsageScan.load(fileURL: file).get())
        let savings = try #require(scan.savings)

        #expect(scan.entries.count == 3)
        #expect(scan.entries.map { $0.answer?.served } == [nil, 100, 4000])
        #expect(scan.entries.compactMap(\.measured).count == 1)
        // The 4,000 bytes the lookup served are on the record and out of the ratio, which is the whole point
        // of recording them without inventing a source to divide them by.
        #expect(savings.total.calls == 1)
        #expect(savings.total.served == 100)
        #expect(savings.unpriced?.served == 4000)
    }

    /// The served size reached the lookup tools on its own day, and the line says so rather than reading as "they served almost nothing".
    ///
    /// The same age argument the measured onset makes, against a later start date. A window spanning both days holds `where` calls that recorded nothing because they predate the field, and "1 of 2 recorded what they served" invites the reading that the other one served nothing at all.
    @Test
    func theUnpricedCallsNameTheDayTheyBeganRecordingWhatTheyServed() throws {
        let file = try Self.writeLog([
            Self.entry(tool: "digest", target: "Measured", timestamp: "2026-08-18T09:00:00Z", bytes: (out: 100, source: 1000)),
            Self.entry(tool: "where", target: "Before", timestamp: "2026-08-20T09:00:00Z"),
            Self.entry(tool: "where", target: "After", timestamp: "2026-08-27T09:00:00Z", served: 4000),
        ])

        let savings = try #require(try UsageScan.load(fileURL: file).get().savings)
        let unpriced = try #require(savings.unpriced)

        #expect(unpriced.calls == 2)
        #expect(unpriced.recorded == 1)
        #expect(unpriced.recordedSince == "2026-08-27")
        // `4.0`, not `4`: below ten kilobytes the figure carries a decimal, because truncating there would
        // print 1,999 B as `1 kB`.
        #expect(unpriced.note.hasSuffix("1 of them served 4.0 kB, recorded since 2026-08-27"))
    }

    /// A window in which every measured call is on one side prints that side once, not twice under two labels.
    ///
    /// Two rows reading identically is not corroboration; it is one number said again, and the split is only worth printing where it separates something.
    @Test
    func aWindowWithNoPassthroughsPrintsOneRowRatherThanTheSameRowTwice() throws {
        let file = try Self.writeLog([
            Self.entry(tool: "digest", target: "Big", bytes: (out: 100, source: 1000)),
            Self.entry(tool: "digest", target: "Bigger", bytes: (out: 200, source: 4000)),
        ])

        let report = UsageReport.render(fileURL: file)
        let savings = try #require(try UsageScan.load(fileURL: file).get().savings)

        #expect(savings.split.isEmpty)
        #expect(!report.contains("compressed"))
        #expect(!report.contains("served source"))
        #expect(report.contains("     2  measured"))
    }

    /// With nothing in scope left unmeasured, the total is a total and says nothing about floors.
    @Test
    func aWindowWhereEveryCallWasWeighedDoesNotCallItsTotalAFloor() throws {
        let file = try Self.writeLog([Self.entry(tool: "digest", target: "Only", bytes: (out: 100, source: 1000))])

        let savings = try #require(try UsageScan.load(fileURL: file).get().savings)

        #expect(savings.unrecorded == nil)
        #expect(savings.unpriced == nil)
        #expect(savings.floorNote == nil)
        #expect(!UsageReport.render(fileURL: file).contains("leaves out what was not weighed"))
    }

    /// The savings line is scoped by the same filters as the counts above it.
    @Test
    func savingsRespectTheSinceAndRootFilters() throws {
        let file = try Self.writeLog([
            Self.entry(tool: "digest", target: "Old", timestamp: "2026-07-28T09:00:00Z", bytes: (out: 900, source: 1000)),
            Self.entry(tool: "digest", target: "Recent", timestamp: "2026-07-30T09:00:00Z", bytes: (out: 100, source: 1000)),
            Self.entry(tool: "digest", target: "Elsewhere", root: "/repo/b", timestamp: "2026-07-30T09:00:00Z", bytes: (out: 900, source: 1000)),
        ])

        let report = UsageReport.render(fileURL: file, since: "2026-07-30", root: "/repo/a")

        #expect(report.contains("digest served 10% of the source it replaced (measured over 1 of 1 call)"))
    }

    /// Seven roots, each with a distinct call count so `most-used first` orders them without ties: `/repo/r0` (7 calls) down to `/repo/r6` (1 call).
    private static func sevenRootsLog() throws -> URL {
        var lines: [String] = []
        for index in 0 ..< 7 {
            let calls = 7 - index
            for _ in 0 ..< calls {
                lines.append(Self.entry(tool: "digest", root: "/repo/r\(index)"))
            }
        }
        return try Self.writeLog(lines)
    }

    /// A machine used against many repositories buried the section in one pseudonymised line per root, none of them the ones that mattered — `by root:` shows the top 5 and folds the rest into one line.
    @Test
    func byRootShowsTheTopFiveAndFoldsTheRestIntoOneLine() throws {
        let report = try UsageReport.render(fileURL: Self.sevenRootsLog())

        for index in 0 ..< 5 {
            #expect(report.contains("/repo/r\(index)"))
        }

        #expect(!report.contains("/repo/r5"))
        #expect(!report.contains("/repo/r6"))
        #expect(report.contains("… and 2 more roots (3 calls)"))
    }

    @Test
    func allRootsPrintsEveryRoot() throws {
        let report = try UsageReport.render(fileURL: Self.sevenRootsLog(), allRoots: true)

        for index in 0 ..< 7 {
            #expect(report.contains("/repo/r\(index)"))
        }

        #expect(!report.contains("more root"))
    }

    @Test
    func exactlyFiveRootsPrintsNoTailLine() throws {
        var lines: [String] = []
        for index in 0 ..< 5 {
            let calls = 5 - index
            for _ in 0 ..< calls {
                lines.append(Self.entry(tool: "digest", root: "/repo/r\(index)"))
            }
        }
        let report = try UsageReport.render(fileURL: Self.writeLog(lines))

        for index in 0 ..< 5 {
            #expect(report.contains("/repo/r\(index)"))
        }

        #expect(!report.contains("more root"))
    }

    /// The floor note says a face's lookups may be missing from the log only where the window reaches back past the CLI's first logged lookup — dated over the whole log, not the window, since it is a fact about the machine.
    @Test
    func theFloorNoteBlamesAnUnloggedFaceOnlyWhereTheWindowReachesPastIt() throws {
        let file = try Self.writeLog([
            Self.entry(tool: "digest", target: "Widget", timestamp: "2026-07-28T09:00:00Z", bytes: (out: 400, source: 4000)),
            Self.entry(tool: "where", target: "Widget", timestamp: "2026-07-28T10:00:00Z", served: 90, via: "cli"),
            Self.entry(tool: "digest", target: "Engine", timestamp: "2026-07-29T08:00:00Z", bytes: (out: 200, source: 2000)),
            Self.entry(tool: "where", target: "Engine", timestamp: "2026-07-29T10:00:00Z", served: 90, via: "cli"),
        ])
        let clause = "and a lookup served before its face began logging is not in the log to weigh at all."

        #expect(UsageReport.render(fileURL: file).contains(clause))
        let afterward = UsageReport.render(fileURL: file, since: "2026-07-29")
        #expect(afterward.contains("leaves out what was not weighed: only the 1 call above were weighed.\n"))
        #expect(!afterward.contains(clause))
    }

    /// A log with no CLI line at all cannot tell a machine that never used the CLI from one older than its logging, so the floor keeps the clause.
    @Test
    func theFloorNoteKeepsTheUnloggedFaceWhereTheLogHoldsNoCLILine() throws {
        let file = try Self.writeLog([
            Self.entry(tool: "digest", target: "Widget", bytes: (out: 400, source: 4000)),
            Self.entry(tool: "where", target: "Widget", served: 90),
        ])

        #expect(UsageReport.render(fileURL: file).contains("is not in the log to weigh at all."))
    }

    /// The clause is decided on the window's own start against the onset's day, not on which entries happen to fall in scope — a `--since` before the CLI's first logged lookup keeps the clause even where the log holds no entry earlier than that lookup to prove the gap.
    @Test
    func theFloorNoteKeepsTheClauseWhenTheWindowStartsBeforeCLILoggingWithNoEntriesBetween() throws {
        let file = try Self.writeLog([
            Self.entry(tool: "where", target: "Widget", timestamp: "2026-07-29T09:00:00Z", served: 90, via: "cli"),
            Self.entry(tool: "digest", target: "Engine", timestamp: "2026-07-29T10:00:00Z", bytes: (out: 200, source: 2000)),
        ])

        let report = UsageReport.render(fileURL: file, since: "2026-07-01")

        #expect(report.contains("and a lookup served before its face began logging is not in the log to weigh at all."))
    }
}
