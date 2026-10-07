//
// Copyright © Agulhas Labs
//

import Foundation
import SiftCore
@testable import SiftMCP
import Testing

/// Every face states the index's saving gross: the usage log's figure, labelled, with its baseline, and one line counting the digests whose file was then read whole.
///
/// Counted from the share, never priced, never subtracted. Built from a real transcript and usage log.
@Suite(.temporaryDirectories)
struct GrossSavingScenarioTests {
    private static var relative: String {
        "Sources/App/Depot.swift"
    }

    /// The count line for one digest read whole afterwards, as every face with a scan prints it.
    private static var oneReadAnyway: String {
        "1 digest was followed by a whole read of its file; its saving is not subtracted, so the figure leans high"
    }

    /// A checkout holding one file well above the digest floor, the digest answer the index would serve for it, and a second digest's claim beside it in the log.
    private static func scenario(reading: (_ file: String, _ cwd: String) -> [Data], via: String? = nil) throws -> Scenario {
        let directory = try TemporaryDirectory.make("gross-saving")
        let file = directory.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let body = (0 ..< 400).map { "    func member\($0)() -> Int { \($0) }" }.joined(separator: "\n")
        let source = "public struct Depot {\n\(body)\n}\n"
        try source.write(to: file, atomically: true, encoding: .utf8)
        let answer = "tree: App  head: 0000000  dirty: 0  parse_errors: 0\n\(relative) — module: App\n"
            + "imports: Foundation\n\npublic struct Depot — 400 members  :1-402"
        let cwd = directory.path
        let digest = via == "cli"
            ? [
                TranscriptFixture.toolUse("Bash", id: "d1", input: ["command": "sift digest \(relative)"], cwd: cwd),
                TranscriptFixture.toolResult(id: "d1", isError: false, text: answer),
            ]
            : [
                TranscriptFixture.toolUse("mcp__sift__digest", id: "d1", input: ["target": relative], cwd: cwd),
                TranscriptFixture.indexAnswer(id: "d1", text: answer),
            ]
        let project = directory.appendingPathComponent("projects/-repo")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try Data(stamped(digest + reading(file.path, cwd)).flatMap { $0 + [0x0A] }).write(to: project.appendingPathComponent("session.jsonl"))
        let log = directory.appendingPathComponent("usage.jsonl")
        try [
            logLine(target: relative, served: answer.utf8.count, source: source.utf8.count, via: via),
            logLine(target: "Ledger", served: 1000, source: 41000, via: nil),
        ].joined(separator: "\n").appending("\n").write(to: log, atomically: true, encoding: .utf8)
        return Scenario(directory: directory, file: file.path, log: log, gross: source.utf8.count - answer.utf8.count + 40000)
    }

    /// The lines as Claude Code writes them: under the session the log's lines name, half a second after the second they were logged at.
    private static func stamped(_ lines: [Data]) -> [Data] {
        lines.map { line in
            var object = (try? JSONSerialization.jsonObject(with: line) as? [String: Any]) ?? [:]
            object["sessionId"] = "session"
            object["timestamp"] = "2026-10-01T10:00:00.500Z"
            return (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
        }
    }

    private static func logLine(target: String, served: Int, source: Int, via: String?) -> String {
        var entry: [String: Any] = [
            "ts": "2026-10-01T10:00:00Z", "tool": "digest", "target": target, "root": "/repo", "ms": 4, "ok": true,
            "session": "session", "outBytes": served, "srcBytes": source,
        ]
        entry["via"] = via
        let data = (try? JSONSerialization.data(withJSONObject: entry)) ?? Data()
        return String(bytes: data, encoding: .utf8) ?? ""
    }

    private static func wholeRead(_ file: String, cwd: String) -> [Data] {
        [
            TranscriptFixture.toolUse("Read", id: "r1", input: ["file_path": file], cwd: cwd),
            TranscriptFixture.toolResult(id: "r1", isError: false, text: "1\tpublic struct Depot {"),
        ]
    }

    private static func page(_ scenario: Scenario) -> String {
        ReportPage.render(ReportData.assemble(
            logURL: scenario.log,
            projectsDirectory: scenario.directory.appendingPathComponent("projects"),
            roots: [],
            since: nil,
            root: nil,
            includeScratch: true,
            now: Date(),
            moduleHealth: { _ in nil }
        ))
    }

    /// No wording of the netting this replaced survives on a face.
    private static func carriesNoNetting(_ text: String) -> Bool {
        !text.contains("withdrawn") && !text.contains("withdraws") && !text.contains("their digests claimed")
            && !text.contains("nets ") && !text.contains("netted") && !text.contains("net of")
    }

    /// `audit` states the usage log's gross saving, its baseline, and the one count line, and nothing withdrawn.
    @Test
    func theAuditStatesTheGrossFigureAndCountsTheReadAnyway() throws {
        let scenario = try Self.scenario(reading: Self.wholeRead)

        let report = TranscriptAudit.render(projectsDirectory: scenario.directory.appendingPathComponent("projects"), usageLog: scenario.log)

        #expect(report.contains("    saving    \(TokenEstimate.saved(bytes: scenario.gross)), \(TokenEstimate.basis(bytes: scenario.gross)): every measured call the usage log holds for this window"))
        #expect(report.contains("    gross     \(Self.oneReadAnyway)"))
        #expect(Self.carriesNoNetting(report))
    }

    /// `usage` reads the log alone: it says its figure is gross and points at `sift audit` for the count.
    @Test
    func usageSaysGrossAndPointsAtTheAudit() throws {
        let scenario = try Self.scenario(reading: Self.wholeRead)

        let report = UsageReport.render(fileURL: scenario.log)

        #expect(report.contains("estimated savings — \(TokenEstimate.saved(bytes: scenario.gross)), \(TokenEstimate.basis(bytes: scenario.gross)): "))
        #expect(report.contains("the figure above is gross: a digest or answer whose file was then read whole anyway still counts, which this log cannot see; sift audit counts those reads"))
        #expect(Self.carriesNoNetting(report))
    }

    /// The report page leads with the gross figure, states its basis in gross bytes, and counts the read anyway in one line.
    @Test
    func theReportPageLeadsWithTheGrossFigure() throws {
        let scenario = try Self.scenario(reading: Self.wholeRead)

        let page = Self.page(scenario)

        #expect(page.contains("<p class=\"figure\">\(TokenEstimate.saved(bytes: scenario.gross))</p>"))
        #expect(page.contains("<p class=\"caption\">\(TokenEstimate.basis(bytes: scenario.gross)) — "))
        #expect(page.contains("<p class=\"caption\">\(Self.oneReadAnyway)</p>"))
        #expect(Self.carriesNoNetting(page))
    }

    /// The figure is the log's and nothing else: deleting the checkout after the digest and the read moves nothing.
    @Test
    func deletingTheCheckoutChangesNothingInTheFigure() throws {
        let scenario = try Self.scenario(reading: Self.wholeRead)
        let figure = "<p class=\"figure\">\(TokenEstimate.saved(bytes: scenario.gross))</p>"
        #expect(Self.page(scenario).contains(figure))

        try FileManager.default.removeItem(atPath: scenario.directory.appendingPathComponent("Sources").path)

        #expect(Self.page(scenario).contains(figure))
    }

    /// A shell `cat` of the digested file is that read too: in the share's read-whole count and in the line every face prints from it.
    @Test(arguments: [nil, "cli"])
    func aShellCatAfterADigestIsCounted(via: String?) throws {
        let scenario = try Self.scenario(reading: { file, cwd in
            [
                TranscriptFixture.toolUse("Bash", id: "c1", input: ["command": "cat \(file)"], cwd: cwd),
                TranscriptFixture.toolResult(id: "c1", isError: false, text: "public struct Depot {"),
            ]
        }, via: via)
        let projects = scenario.directory.appendingPathComponent("projects")

        let tallies = TranscriptAudit.tallies(projectsDirectory: projects)
        let report = TranscriptAudit.render(projectsDirectory: projects, usageLog: scenario.log)

        #expect(tallies.totals.readWholeAfterDigest == 1)
        #expect(tallies.totals.cold == 0)
        #expect(report.contains("    gross     \(Self.oneReadAnyway)"))
        #expect(Self.page(scenario).contains("<p class=\"caption\">\(Self.oneReadAnyway)</p>"))
    }

    /// The share counts the whole read after the digest as a miss, whatever the usage log priced for the digest.
    @Test
    func theShareCountsTheReadAnywayAsAMiss() throws {
        let scenario = try Self.scenario(reading: Self.wholeRead)
        let transcript = scenario.directory.appendingPathComponent("projects/-repo/session.jsonl")

        let tally = TranscriptFixture.scored(transcript: transcript)

        #expect(tally.shareText == "50%")
        #expect(tally.total == 2)
    }
}

private extension GrossSavingScenarioTests {
    struct Scenario {
        let directory: URL
        let file: String
        let log: URL
        /// Both log lines' source less what they served: the figure every face states.
        let gross: Int
    }
}
