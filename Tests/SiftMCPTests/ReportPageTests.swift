//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
@testable import SiftMCP
import Testing

/// Covers the `report` page: what it leads with, what it refuses to invent, and that it renders identically with nothing to fetch.
@Suite(.temporaryDirectories)
struct ReportPageTests {
    // MARK: Fixtures

    static func writeLog(_ lines: [String], in directory: URL) throws -> URL {
        let file = directory.appendingPathComponent("usage.jsonl")
        try (lines.joined(separator: "\n") + "\n").write(to: file, atomically: true, encoding: .utf8)
        return file
    }

    static func entry(
        tool: String,
        target: String? = nil,
        root: String = "/repo/a",
        succeeded: Bool = true,
        error: String? = nil,
        timestamp: String = "2026-08-14T10:00:00Z",
        bytes: (out: Int, source: Int)? = nil,
        agent: String? = nil
    ) -> String {
        var object: [String: Any] = ["tool": tool, "root": root, "ms": 10, "ok": succeeded, "ts": timestamp]
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
        let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return String(data: data ?? Data(), encoding: .utf8) ?? ""
    }

    /// `now` sits a few days after the fixtures, so a `7d` window holds them and a `today` window does not.
    static var now: Date {
        ISO8601DateFormatter().date(from: "2026-08-16T12:00:00Z") ?? Date()
    }

    /// One `<projects>/<project>/<session>.jsonl` tree, in the shape the audit's sweep enumerates.
    private static func transcripts(_ lines: [String], in directory: URL) throws -> URL {
        let root = directory.appendingPathComponent("projects", isDirectory: true)
        let project = root.appendingPathComponent("-Users-someone-Developer-App", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try (lines.joined(separator: "\n") + "\n")
            .write(to: project.appendingPathComponent("11112222-3333.jsonl"), atomically: true, encoding: .utf8)
        return root
    }

    private static func toolUse(_ name: String, id: String, at timestamp: String, input: [String: Any], cwd: String? = nil) -> String {
        var object: [String: Any] = [
            "type": "assistant",
            "timestamp": timestamp,
            "message": ["content": [["type": "tool_use", "id": id, "name": name, "input": input]]],
        ]
        object["cwd"] = cwd
        let data = (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
        return String(bytes: data, encoding: .utf8) ?? ""
    }

    /// One `run.jsonl` line, in the shape `sift run` writes.
    private static func runEntry(
        kind: String,
        exit: Int = 0,
        root: String = "/repo/a",
        shown: Int? = nil,
        total: Int? = nil,
        timestamp: String = "2026-08-14T10:00:00Z"
    ) -> String {
        var object: [String: Any] = ["kind": kind, "exit": exit, "ms": 100, "ts": timestamp, "root": root]
        if let shown, let total {
            object["shown"] = shown
            object["total"] = total
        }
        let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return String(data: data ?? Data(), encoding: .utf8) ?? ""
    }

    private static func writeRunLog(_ lines: [String], in directory: URL) throws -> URL {
        let file = directory.appendingPathComponent("run.jsonl")
        try (lines.joined(separator: "\n") + "\n").write(to: file, atomically: true, encoding: .utf8)
        return file
    }

    static func assemble(
        log: URL,
        runLog: URL? = nil,
        projects: URL,
        roots: [String] = [],
        since: String? = "7d",
        root: String? = nil,
        health: @escaping (String) -> SessionPrimer.ModuleHealth? = { _ in nil }
    ) -> ReportData {
        ReportData.assemble(
            logURL: log,
            runLogURL: runLog,
            projectsDirectory: projects,
            roots: roots,
            since: since,
            root: root,
            now: now,
            timeZone: TimeZone(identifier: "UTC") ?? .current,
            moduleHealth: health
        )
    }

    // MARK: Conditions

    /// Nothing awaiting a human renders as nothing at all — not an empty heading, which is a counter by another name.
    @Test
    func noConditionsRenderNoSection() throws {
        let directory = try TemporaryDirectory.make("report")
        let log = try Self.writeLog([Self.entry(tool: "digest", target: "Widget")], in: directory)

        let page = ReportPage.render(Self.assemble(log: log, projects: directory, roots: ["/repo/a"]))

        #expect(!page.contains("Awaiting you"))
        #expect(!page.contains("class=\"conditions\""))
    }

    /// A condition names the repository it holds in and the command that clears it.
    @Test
    func aConditionNamesItsRootAndTheCommandToRun() throws {
        let directory = try TemporaryDirectory.make("report")
        let log = try Self.writeLog([Self.entry(tool: "digest", target: "Widget")], in: directory)
        let data = Self.assemble(log: log, projects: directory, roots: ["/work/Monorepo"]) { _ in
            SessionPrimer.ModuleHealth(guessed: 279, files: 279)
        }

        let page = ReportPage.render(data)

        #expect(data.conditions.count == 1)
        #expect(page.contains("Awaiting you"))
        #expect(page.contains("Monorepo"))
        #expect(page.contains("279 of 279"))
        #expect(page.contains("sift init /work/Monorepo"))
    }

    /// The threshold is the primer's: a handful of loose files outside any manifest is not a condition.
    @Test
    func aFewLooseFilesAreNotACondition() throws {
        let directory = try TemporaryDirectory.make("report")
        let log = try Self.writeLog([Self.entry(tool: "digest", target: "Widget")], in: directory)
        let data = Self.assemble(log: log, projects: directory, roots: ["/repo/a"]) { _ in
            SessionPrimer.ModuleHealth(guessed: 2, files: 646)
        }

        #expect(data.conditions.isEmpty)
        #expect(!ReportPage.render(data).contains("Awaiting you"))
    }

    // MARK: Savings

    /// The page's savings figure is the one `usage` prints — the same aggregation, not a second one.
    @Test
    func savingsMatchTheUsageSummaryForTheSameLog() throws {
        let directory = try TemporaryDirectory.make("report")
        let log = try Self.writeLog([
            Self.entry(tool: "digest", target: "Widget", bytes: (out: 900, source: 9000)),
            Self.entry(tool: "digest", target: "Engine", bytes: (out: 100, source: 1000)),
        ], in: directory)

        let data = Self.assemble(log: log, projects: directory)

        #expect(data.savings?.percent == 10)
        #expect(UsageReport.render(fileURL: log).contains(data.savings?.sentence ?? "no sentence"))
        #expect(ReportPage.render(data).contains("measured over 2 of 2 calls"))
    }

    /// Unmeasured calls stay in the denominator and out of the ratio: a partial aggregate is never printed as a total.
    @Test
    func aMixedLogStatesHowManyCallsItMeasured() throws {
        let directory = try TemporaryDirectory.make("report")
        let log = try Self.writeLog([
            Self.entry(tool: "digest", target: "Widget", bytes: (out: 500, source: 1000)),
            Self.entry(tool: "where", target: "Widget"),
            Self.entry(tool: "search", target: "kind:func"),
        ], in: directory)

        let data = Self.assemble(log: log, projects: directory)

        #expect(data.savings?.percent == 50)
        #expect(data.savings?.measured == 1)
        #expect(data.savings?.calls == 3)
        #expect(ReportPage.render(data).contains("measured over 1 of 3 calls"))
    }

    /// A log where nothing measured itself says so rather than rendering a zero, which would read as "saved nothing".
    @Test
    func anUnmeasuredLogSaysSoRatherThanShowingZero() throws {
        let directory = try TemporaryDirectory.make("report")
        let log = try Self.writeLog([Self.entry(tool: "where", target: "Widget")], in: directory)

        let data = Self.assemble(log: log, projects: directory)

        #expect(data.savings == nil)
        #expect(ReportPage.render(data).contains("No call in this window measured itself"))
    }

    // MARK: Wrapped runs

    /// The runs get one line of their own, naming their subject and their window, and never blend into the savings figure above them.
    ///
    /// Both are compression measured against a real original, and they are different originals — source a digest stood in for, against build output a filter dropped. One figure taken for the other, or the two added, would be a number about nothing.
    @Test
    func wrappedRunsGetTheirOwnLineWithoutMovingTheSavingsFigure() throws {
        let directory = try TemporaryDirectory.make("report")
        let log = try Self.writeLog([Self.entry(tool: "digest", target: "Widget", bytes: (out: 900, source: 9000))], in: directory)
        let runLog = try Self.writeRunLog([
            Self.runEntry(kind: "swift test", shown: 10, total: 500),
            Self.runEntry(kind: "xcodebuild", exit: 65, shown: 20, total: 1500),
        ], in: directory)

        let data = Self.assemble(log: log, runLog: runLog, projects: directory)
        let page = ReportPage.render(data)

        #expect(data.savings?.percent == 10)
        #expect(data.runs?.runs == 2)
        #expect(page.contains("Build output, window 7d:"))
        #expect(page.contains("2 runs wrapped in"))
        #expect(page.contains("run showed 2% of the output it wrapped (measured over 2 of 2 runs)"))
        #expect(page.contains("1 exited nonzero"))
    }

    /// No run log, or none in the window, means no line at all — a standing zero would report a feature as failing on a machine that has simply not used it.
    @Test
    func aMissingRunLogAddsNothingToThePage() throws {
        let directory = try TemporaryDirectory.make("report")
        let log = try Self.writeLog([Self.entry(tool: "digest", target: "Widget")], in: directory)

        #expect(!ReportPage.render(Self.assemble(log: log, projects: directory)).contains("Build output, window"))

        let stale = try Self.writeRunLog([Self.runEntry(kind: "swift test", timestamp: "2026-07-01T10:00:00Z")], in: directory)
        let data = Self.assemble(log: log, runLog: stale, projects: directory)
        #expect(data.runs == nil)
        #expect(!ReportPage.render(data).contains("Build output, window"))
    }

    /// `--root` narrows the runs with everything else it narrows, since the log records the repository each run happened in.
    @Test
    func aRootNarrowsTheRunsToo() throws {
        let directory = try TemporaryDirectory.make("report")
        let log = try Self.writeLog([Self.entry(tool: "digest", target: "Widget")], in: directory)
        let runLog = try Self.writeRunLog([
            Self.runEntry(kind: "swift test", root: "/repo/a"),
            Self.runEntry(kind: "xcodebuild", root: "/repo/b"),
        ], in: directory)

        #expect(Self.assemble(log: log, runLog: runLog, projects: directory).runs?.runs == 2)
        #expect(Self.assemble(log: log, runLog: runLog, projects: directory, root: "/repo/a").runs?.runs == 1)
    }

    // MARK: Scope

    /// A call outside the window appears in no section of the page — not in the counts, not in the roots, not in the targets.
    @Test
    func aCallOutsideTheWindowAppearsNowhere() throws {
        let directory = try TemporaryDirectory.make("report")
        let log = try Self.writeLog([
            Self.entry(tool: "digest", target: "InsideTheWindow", timestamp: "2026-08-14T10:00:00Z"),
            Self.entry(tool: "digest", target: "LongBeforeTheWindow", root: "/repo/ancient", succeeded: false, error: "no type named LongBeforeTheWindow", timestamp: "2026-01-02T10:00:00Z", bytes: (out: 10, source: 10000)),
        ], in: directory)

        let data = Self.assemble(log: log, projects: directory, since: "2d")
        let page = ReportPage.render(data)

        #expect(data.calls == 1)
        #expect(!page.contains("LongBeforeTheWindow"))
        #expect(!page.contains("/repo/ancient"))
        #expect(data.failures.isEmpty)
        #expect(data.savings == nil)
        #expect(page.contains("InsideTheWindow"))
    }

    /// A root narrows every log-derived section together, and the page says which root it narrowed to.
    @Test
    func aRootNarrowsEverySectionAndIsStated() throws {
        let directory = try TemporaryDirectory.make("report")
        let log = try Self.writeLog([
            Self.entry(tool: "digest", target: "Wanted", root: "/work/Wanted/app"),
            Self.entry(tool: "digest", target: "Unwanted", root: "/work/Unwanted"),
        ], in: directory)

        let data = Self.assemble(log: log, projects: directory, root: "Wanted")
        let page = ReportPage.render(data)

        #expect(data.calls == 1)
        #expect(data.rootScope == .resolved("/work/Wanted"))
        #expect(!page.contains("Unwanted"))
        #expect(page.contains("scoped to /work/Wanted"))
    }

    /// A `--root` that names no one directory is stated in the header, and no section carries a figure.
    ///
    /// The page's version of the defect the CLI face avoids by printing the refusal alone: a header that omits the scope reads exactly like an unscoped machine-wide report — while the run caption sits near the top having quietly picked one of the candidates, and the reason sits far below it.
    @Test
    func anUnresolvedRootIsStatedInTheHeaderAndNoRunFigureIsDrawn() throws {
        let directory = try TemporaryDirectory.make("report")
        let log = try Self.writeLog([Self.entry(tool: "digest", target: "Widget", root: "/work/Catalogue")], in: directory)
        let runLog = try Self.writeRunLog([
            Self.runEntry(kind: "swift test", root: "/personal/Catalogue", shown: 4, total: 200),
        ], in: directory)

        let data = Self.assemble(log: log, runLog: runLog, projects: directory, root: "Catalogue")
        let page = ReportPage.render(data)

        #expect(data.rootScope == ReportData.RootScope.unresolved(argument: "Catalogue"))
        #expect(data.runs == nil)
        #expect(data.calls == 0)
        #expect(page.contains("--root Catalogue named no one directory — nothing below is scoped"))
        #expect(!page.contains("wrapped in"))
    }

    /// A root filter scopes the share too, exactly as it scopes the calls: a transcript recorded outside the resolved root contributes nothing to it.
    @Test
    func aTranscriptOutsideTheRootDoesNotJoinTheShare() throws {
        let directory = try TemporaryDirectory.make("report")
        let log = try Self.writeLog([Self.entry(tool: "digest", target: "Wanted", root: "/work/Wanted")], in: directory)
        let projects = try Self.transcripts([
            Self.toolUse("Read", id: "a", at: "2026-08-11T12:00:00Z", input: ["file_path": "/repo/BayGeometry.swift"], cwd: "/work/Elsewhere"),
        ], in: directory)

        let data = Self.assemble(log: log, projects: projects, root: "Wanted")

        #expect(data.share == nil)
    }

    /// The other half of the same rule: a transcript recorded inside the resolved root — or a directory beneath it — does join the share.
    @Test
    func aTranscriptInsideTheRootJoinsTheShare() throws {
        let directory = try TemporaryDirectory.make("report")
        let log = try Self.writeLog([Self.entry(tool: "digest", target: "Wanted", root: "/work/Wanted")], in: directory)
        let projects = try Self.transcripts([
            Self.toolUse("Read", id: "a", at: "2026-08-11T12:00:00Z", input: ["file_path": "/repo/BayGeometry.swift"], cwd: "/work/Wanted/app"),
        ], in: directory)

        let data = Self.assemble(log: log, projects: projects, root: "Wanted")

        #expect(data.share?.tally.total == 1)
    }

    /// The trend is one bar per day, drawn from the same sweep the audit reports, and a share the whole window shared would hide a week that fell.
    @Test
    func theShareIsBrokenOutPerDay() throws {
        let directory = try TemporaryDirectory.make("report")
        let log = try Self.writeLog([Self.entry(tool: "digest", target: "Widget")], in: directory)
        let projects = try Self.transcripts([
            Self.toolUse("mcp__sift__digest", id: "a", at: "2026-08-11T12:00:00Z", input: ["target": "Widget"]),
            Self.toolUse("Read", id: "b", at: "2026-08-12T12:00:00Z", input: ["file_path": "/repo/BayGeometry.swift"]),
            Self.toolUse("Read", id: "c", at: "2026-08-12T13:00:00Z", input: ["file_path": "/repo/DepotCatalog.swift"]),
        ], in: directory)

        let data = Self.assemble(log: log, projects: projects)

        #expect(data.share?.byDay == [
            ReportData.DayShare(day: "2026-08-11", indexed: 1, total: 1, share: 100, shareText: "100%"),
            ReportData.DayShare(day: "2026-08-12", indexed: 0, total: 2, share: 0, shareText: "0%"),
        ])
        #expect(data.share?.tally.share == 33)
        #expect(ReportPage.render(data).contains("<svg class=\"trend\""))
    }

    /// The page prints the same share the status line does, floor and all.
    ///
    /// The figure at the top of the page is the glanced-at kind, and a rounded 0 there says the index went unused across the whole window while the status line for the same transcripts said `<1%`.
    @Test
    func aNonzeroShareNeverPrintsAsZero() throws {
        let directory = try TemporaryDirectory.make("report")
        let log = try Self.writeLog([Self.entry(tool: "digest", target: "Widget")], in: directory)
        var lines = [Self.toolUse("mcp__sift__digest", id: "a", at: "2026-08-11T12:00:00Z", input: ["target": "Widget"])]
        for index in 0 ..< 200 {
            lines.append(Self.toolUse(
                "Read",
                id: "r\(index)",
                at: "2026-08-11T12:00:00Z",
                input: ["file_path": "/repo/File\(index).swift"]
            ))
        }
        let projects = try Self.transcripts(lines, in: directory)

        let data = Self.assemble(log: log, projects: projects)

        #expect(data.share?.tally.share == 0)
        // One of 201 rounds to 0, and 0 is the one thing this share is not.
        #expect(ReportPage.render(data).contains("<p class=\"figure\">&lt;1%</p>"))
    }

    /// The trend's bars carry the same floor the headline above them does.
    ///
    /// The trend renders nothing at all for a single day, which is why a per-day test cannot see this: a headline reading `<1%` over a bar labelled a bare `0`, whose tooltip says `0% — 1 of 201`, contradicts itself about one measurement.
    @Test
    func aNonzeroDayIsNotLabelledZeroOnTheTrend() throws {
        let directory = try TemporaryDirectory.make("report")
        let log = try Self.writeLog([Self.entry(tool: "digest", target: "Widget")], in: directory)
        var lines = [Self.toolUse("mcp__sift__digest", id: "a", at: "2026-08-11T12:00:00Z", input: ["target": "Widget"])]
        for index in 0 ..< 200 {
            lines.append(Self.toolUse(
                "Read",
                id: "r\(index)",
                at: "2026-08-11T12:00:00Z",
                input: ["file_path": "/repo/File\(index).swift"]
            ))
        }
        // A second day, so the trend is drawn at all.
        lines.append(Self.toolUse("mcp__sift__digest", id: "b", at: "2026-08-12T12:00:00Z", input: ["target": "Widget"]))
        let projects = try Self.transcripts(lines, in: directory)

        let page = ReportPage.render(Self.assemble(log: log, projects: projects))

        #expect(page.contains("<svg class=\"trend\""))
        #expect(page.contains("2026-08-11: &lt;1% — 1 of 201"))
        #expect(page.contains(">&lt;1%</text>"))
        #expect(!page.contains(">0</text>"))
        // The day that really is whole keeps its own number.
        #expect(page.contains("2026-08-12: 100% — 1 of 1"))
    }

    /// A lookup made before the window contributes to no day and to no total.
    @Test
    func lookupsBeforeTheWindowAreNotSwept() throws {
        let directory = try TemporaryDirectory.make("report")
        let log = try Self.writeLog([Self.entry(tool: "digest", target: "Widget")], in: directory)
        let projects = try Self.transcripts([
            Self.toolUse("Read", id: "a", at: "2026-01-02T12:00:00Z", input: ["file_path": "/repo/LongAgo.swift"]),
            Self.toolUse("Read", id: "b", at: "2026-08-12T12:00:00Z", input: ["file_path": "/repo/Recent.swift"]),
        ], in: directory)

        let data = Self.assemble(log: log, projects: projects)

        #expect(data.share?.tally.cold == 1)
        #expect(data.share?.byDay.map(\.day) == ["2026-08-12"])
    }

    /// A condition in a repository outside the scoped root is not this report's business.
    @Test
    func conditionsAreScopedByRootToo() throws {
        let directory = try TemporaryDirectory.make("report")
        let log = try Self.writeLog([Self.entry(tool: "digest", target: "Wanted", root: "/work/Wanted")], in: directory)

        let data = Self.assemble(log: log, projects: directory, roots: ["/work/Wanted", "/work/Elsewhere"], root: "Wanted") { _ in
            SessionPrimer.ModuleHealth(guessed: 100, files: 100)
        }

        #expect(data.conditions.map(\.root) == ["/work/Wanted"])
    }

    // MARK: Failures

    /// Failures group by their recorded reason and carry the days they happened on, so a shared page is never read as a list of current issues.
    @Test
    func failuresCarryTheirDays() throws {
        let directory = try TemporaryDirectory.make("report")
        let log = try Self.writeLog([
            Self.entry(tool: "search", succeeded: false, error: "\"worktree\" is not field:value", timestamp: "2026-08-11T09:00:00Z"),
            Self.entry(tool: "search", succeeded: false, error: "\"worktree\" is not field:value", timestamp: "2026-08-13T09:00:00Z"),
            Self.entry(tool: "digest", succeeded: false, error: "no root", timestamp: "2026-08-14T09:00:00Z"),
        ], in: directory)

        let data = Self.assemble(log: log, projects: directory)
        let page = ReportPage.render(data)

        #expect(data.failures.first?.count == 2)
        #expect(page.contains("2026-08-11 – 2026-08-13"))
        #expect(page.contains("2026-08-14"))
        #expect(page.contains("is not field:value"))
    }

    // MARK: The file itself

    /// Nothing on the page is fetched, because it has to render the same on a machine with no network as it does here.
    @Test
    func thePageRequestsNothingFromTheNetwork() throws {
        let directory = try TemporaryDirectory.make("report")
        let log = try Self.writeLog([
            Self.entry(tool: "digest", target: "Widget", bytes: (out: 1, source: 2)),
            Self.entry(tool: "where", succeeded: false, error: "build the project"),
        ], in: directory)
        let data = Self.assemble(log: log, projects: directory, roots: ["/work/Monorepo"]) { _ in
            SessionPrimer.ModuleHealth(guessed: 50, files: 50)
        }

        let page = ReportPage.render(data)

        #expect(!page.contains("http://"))
        #expect(!page.contains("https://"))
        #expect(!page.contains("<script"))
        #expect(!page.contains("<link"))
        #expect(!page.contains("@import"))
        #expect(page.hasPrefix("<!doctype html>"))
        #expect(page.hasSuffix("</html>"))
    }

    /// Anything from the log lands in markup, so a target or reason carrying `<` cannot close a tag.
    @Test
    func loggedTextIsEscapedIntoTheMarkup() throws {
        let directory = try TemporaryDirectory.make("report")
        let log = try Self.writeLog([
            Self.entry(tool: "digest", target: "Array<Widget>", succeeded: false, error: "no type named <script>alert(1)</script>"),
        ], in: directory)

        let page = ReportPage.render(Self.assemble(log: log, projects: directory))

        #expect(page.contains("Array&lt;Widget&gt;"))
        #expect(!page.contains("<script>alert(1)"))
        #expect(page.contains("&lt;script&gt;alert(1)"))
    }

    /// A missing log is a state to report, not a page of zeroes that reads as "nothing was used".
    @Test
    func aMissingLogIsStatedRatherThanRenderedAsZero() throws {
        let directory = try TemporaryDirectory.make("report")

        let data = Self.assemble(log: directory.appendingPathComponent("absent.jsonl"), projects: directory)

        #expect(data.logNote == "no usage recorded yet — the log is missing or empty")
        #expect(ReportPage.render(data).contains("no usage recorded yet"))
    }
}
