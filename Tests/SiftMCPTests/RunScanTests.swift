//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftMCP
import Testing

/// Covers the wrapped-run log's scan and the section `usage` renders from it — including the line that must never move: the headline call count means index lookups, and a run is not one.
@Suite(.temporaryDirectories)
struct RunScanTests {
    // MARK: Fixtures

    private static func writeLog(_ lines: [String]) throws -> URL {
        let file = try TemporaryDirectory.make("run-scan")
            .appendingPathComponent("run-scan.jsonl")
        try (lines.joined(separator: "\n") + "\n").write(to: file, atomically: true, encoding: .utf8)
        return file
    }

    private static func run(
        kind: String,
        exit: Int = 0,
        root: String? = "/repo/a",
        shown: Int? = nil,
        total: Int? = nil,
        ms: Int = 100,
        timestamp: String = "2026-08-18T10:00:00Z"
    ) -> String {
        var object: [String: Any] = ["kind": kind, "exit": exit, "ms": ms, "ts": timestamp]
        if let root {
            object["root"] = root
        }
        if let shown, let total {
            object["shown"] = shown
            object["total"] = total
        }
        let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return String(data: data ?? Data(), encoding: .utf8) ?? ""
    }

    private static func usageEntry(timestamp: String = "2026-08-18T10:00:00Z") -> String {
        let object: [String: Any] = ["tool": "digest", "target": "Widget", "root": "/repo/a", "ms": 5, "ok": true, "ts": timestamp]
        let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return String(data: data ?? Data(), encoding: .utf8) ?? ""
    }

    private static func writeUsageLog(_ lines: [String]) throws -> URL {
        let file = try TemporaryDirectory.make("usage-beside-run")
            .appendingPathComponent("usage-beside-run.jsonl")
        try (lines.joined(separator: "\n") + "\n").write(to: file, atomically: true, encoding: .utf8)
        return file
    }

    // MARK: Scanning

    @Test
    func aggregatesKindsExitsAndSuppression() throws {
        let file = try Self.writeLog([
            Self.run(kind: "swift test", shown: 10, total: 500, timestamp: "2026-08-16T10:00:00Z"),
            Self.run(kind: "swift test", exit: 1, shown: 20, total: 1500),
            Self.run(kind: "swift build", shown: 5, total: 100),
            Self.run(kind: "unfiltered", exit: 127),
        ])

        let summary = try #require(RunScan.load(fileURL: file).summary)

        #expect(summary.runs == 4)
        #expect(summary.kinds.map(\.kind) == ["swift test", "swift build", "unfiltered"])
        #expect(summary.kinds.map(\.count) == [2, 1, 1])
        #expect(summary.nonzeroExits == 2)
        #expect(summary.days == ["2026-08-16", "2026-08-18"])
        // Only the three filtered runs contribute lines; the passthrough filtered nothing.
        #expect(summary.filteredRuns == 3)
        #expect(summary.shown == 35)
        #expect(summary.total == 2100)
        #expect(summary.suppressed == 2065)
    }

    /// Summed on both sides, never averaged over per-run ratios.
    ///
    /// The whole point of wrapping a build is the five-thousand-line `xcodebuild`; a mean would let a forty-line `swift build` that compressed badly weigh exactly as much as it and report a worse result than the log holds.
    @Test
    func suppressionIsSummedOnBothSidesRatherThanAveragedOverRatios() throws {
        let file = try Self.writeLog([
            // 50% on its own.
            Self.run(kind: "swift build", shown: 10, total: 20),
            // 1% on its own, and 990 of the 1,010 lines.
            Self.run(kind: "xcodebuild", shown: 10, total: 990),
        ])

        let summary = try #require(RunScan.load(fileURL: file).summary)

        // The mean of the two ratios is 26%; the honest sum/sum is 2%.
        #expect(summary.percent == 2)
        #expect(summary.sentence == "run showed 2% of the output it wrapped (measured over 2 of 2 runs)")
    }

    /// A share that rounds to nothing is still not nothing, and must not be printed as if it were.
    ///
    /// The case this pins: 49 lines shown of 31,581, printed as "run showed 0% of the output it wrapped" — a claim that the filter printed nothing at all, which is the one thing it never did.
    @Test
    func aShareTooSmallToRoundIsPrintedAsUnderOnePercentNotAsNone() throws {
        let file = try Self.writeLog([Self.run(kind: "xcodebuild", shown: 49, total: 31581)])

        let summary = try #require(RunScan.load(fileURL: file).summary)

        #expect(summary.percent == 0)
        #expect(summary.percentText == "<1%")
        #expect(summary.sentence == "run showed <1% of the output it wrapped (measured over 1 of 1 run)")
    }

    /// A run that genuinely showed nothing keeps its zero — the floor is for a nonzero share, not for every small one.
    @Test
    func aRunThatShowedNothingStillPrintsZero() throws {
        let file = try Self.writeLog([Self.run(kind: "xcodebuild", shown: 0, total: 31581)])

        let summary = try #require(RunScan.load(fileURL: file).summary)

        #expect(summary.percentText == "0%")
    }

    /// A window and a root narrow the runs exactly as they narrow the calls.
    ///
    /// The scope arrives already resolved: a trailing fragment is read once, against both logs' roots together, and never again here — see ``LogScopeTests``.
    @Test
    func sinceAndRootNarrowTheRuns() throws {
        let file = try Self.writeLog([
            Self.run(kind: "swift test", root: "/repo/a", timestamp: "2026-08-10T10:00:00Z"),
            Self.run(kind: "swift test", root: "/repo/a", timestamp: "2026-08-18T10:00:00Z"),
            Self.run(kind: "xcodebuild", root: "/other/b", timestamp: "2026-08-18T10:00:00Z"),
        ])
        let scope = try LogScope.resolve("repo/a", among: ["/repo/a", "/other/b"]).get()

        #expect(RunScan.load(fileURL: file, since: "2026-08-15").summary?.runs == 2)
        #expect(RunScan.load(fileURL: file, scope: scope).summary?.runs == 2)
        #expect(RunScan.load(fileURL: file, since: "2026-08-15", scope: scope).summary?.runs == 1)
    }

    /// A run outside any repository records no root, so it cannot answer a question scoped to one.
    @Test
    func aRootlessRunIsDroppedByARootScopeAndCountedWithoutOne() throws {
        let file = try Self.writeLog([
            Self.run(kind: "swift test", root: nil),
            Self.run(kind: "swift test", root: "/repo/a"),
        ])

        #expect(RunScan.load(fileURL: file).summary?.runs == 2)
        #expect(RunScan.load(fileURL: file, scope: LogScope(path: "/repo/a")).summary?.runs == 1)
    }

    /// Absence is reported as absence: this section is additive, and the usage log it sits beside already refuses an unresolvable root in its own words.
    @Test
    func aMissingOrUnreadableLogScansToNothing() throws {
        let missing = try TemporaryDirectory.make("run-absent")
            .appendingPathComponent("run-absent.jsonl")
        #expect(RunScan.load(fileURL: missing).summary == nil)

        let damaged = try Self.writeLog(["not json at all", "{\"nope\":1}"])
        let scan = RunScan.load(fileURL: damaged)
        #expect(scan.summary == nil)
        #expect(scan.malformed == 2)
    }

    // MARK: The `usage` section

    /// The run section exists, states its own subject, and does not touch the headline.
    ///
    /// The `N calls` in `usage — F failures, N calls` means MCP index lookups and is the number every adoption claim rests on. A run is not a lookup — that is the entire reason it keeps its own file — so the count above must be unchanged by the runs below it.
    @Test
    func theRunSectionIsRenderedSeparatelyAndLeavesTheCallCountAlone() throws {
        let usage = try Self.writeUsageLog([Self.usageEntry(), Self.usageEntry()])
        let runs = try Self.writeLog([
            Self.run(kind: "swift test", shown: 10, total: 500),
            Self.run(kind: "swift test", exit: 1, shown: 20, total: 1500),
            Self.run(kind: "unfiltered", exit: 0),
        ])

        let report = UsageReport.render(fileURL: usage, runFileURL: runs)

        #expect(report.contains("usage — 0 failures, 2 calls"))
        #expect(report.contains("runs (sift run — wrapped commands, not index calls):"))
        #expect(report.contains("3 runs, 2026-08-18 → 2026-08-18, 1 nonzero exit"))
        #expect(report.contains("     2  swift test"))
        #expect(report.contains("     1  unfiltered"))
        #expect(report.contains("run showed 2% of the output it wrapped (measured over 2 of 3 runs)"))
        #expect(report.contains("log: \(runs.path)"))
    }

    /// No runs means no section, not a section reporting zero — a standing zero reads as a feature failing on a machine that has simply not used it.
    @Test
    func nothingIsRenderedWhenTheWindowHoldsNoRuns() throws {
        let usage = try Self.writeUsageLog([Self.usageEntry()])
        let runs = try Self.writeLog([Self.run(kind: "swift test", timestamp: "2026-08-01T10:00:00Z")])

        let inWindow = UsageReport.render(fileURL: usage, runFileURL: runs, since: "2026-08-15")

        #expect(!inWindow.contains("runs (sift run"))

        // And with no run log pointed at at all, which is how every existing caller renders.
        #expect(!UsageReport.render(fileURL: usage).contains("runs (sift run"))
    }

    /// A machine that wraps its builds but has not queried the index still sees its runs.
    ///
    /// The usage log's empty state is an early exit, so a section appended only on the success path would tell a machine that has only started wrapping its builds there was nothing to report while its own file filled up.
    @Test
    func theRunSectionSurvivesAnEmptyUsageLog() throws {
        let usage = try TemporaryDirectory.make("usage-none")
            .appendingPathComponent("usage-none.jsonl")
        let runs = try Self.writeLog([Self.run(kind: "swift test", shown: 4, total: 200)])

        let report = UsageReport.render(fileURL: usage, runFileURL: runs)

        #expect(report.contains("no usage recorded yet"))
        #expect(report.contains("runs (sift run — wrapped commands, not index calls):"))
        #expect(report.contains("1 run, 2026-08-18 → 2026-08-18, 0 nonzero exits"))
    }

    /// A window with runs but no filtered ones states the count and stops there, rather than reporting 0% of 0 lines.
    @Test
    func anUnfilteredOnlyWindowStatesNoSuppressionSentence() throws {
        let usage = try Self.writeUsageLog([Self.usageEntry()])
        let runs = try Self.writeLog([Self.run(kind: "unfiltered", exit: 127)])

        let report = UsageReport.render(fileURL: usage, runFileURL: runs)

        #expect(report.contains("1 run, 2026-08-18 → 2026-08-18, 1 nonzero exit"))
        #expect(!report.contains("of the output it wrapped"))
    }
}
