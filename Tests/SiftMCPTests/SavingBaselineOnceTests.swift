//
// Copyright © Agulhas Labs
//

import Foundation
import SiftCore
@testable import SiftMCP
import Testing

/// Every face that prints the saving states what it was priced on, always and once, and none says it leans high: `usage` in its headline and the report page in the caption under its figure, whether or not an unpriced call sits beside it.
@Suite(.temporaryDirectories)
struct SavingBaselineOnceTests {
    /// A usage-log line at a fixed second: an intercepted window carries what the hook intercepted, a `where` records no source and so is unpriced.
    private static func logLine(tool: String, target: String, served: Int, source: Int?, intercepted: String? = nil) -> String {
        var entry: [String: Any] = [
            "ts": "2026-10-01T10:00:00Z", "tool": tool, "target": target, "root": "/repo", "ms": 4, "ok": true,
            "session": "session", "outBytes": served,
        ]
        entry["srcBytes"] = source
        if let intercepted {
            entry["via"] = "hook"
            entry["intercepted"] = intercepted
        }
        let data = (try? JSONSerialization.data(withJSONObject: entry)) ?? Data()
        return String(bytes: data, encoding: .utf8) ?? ""
    }

    /// A usage log of one intercepted window, with a `where` beside it when `unweighed` says so, which is what adds the unpriced count.
    private static func log(in directory: URL, unweighed: Bool) throws -> URL {
        let file = directory.appendingPathComponent("usage.jsonl")
        var lines = [logLine(tool: "digest", target: "Depot", served: 1000, source: 41000, intercepted: "window")]
        if unweighed {
            lines.append(logLine(tool: "where", target: "Depot", served: 90, source: nil))
        }
        try (lines.joined(separator: "\n") + "\n").write(to: file, atomically: true, encoding: .utf8)
        return file
    }

    /// The report page over that log and the transcript of the context that made the digest call.
    private static func page(in directory: URL, unweighed: Bool) throws -> String {
        let log = try log(in: directory, unweighed: unweighed)
        let lines = [
            TranscriptFixture.toolUse("mcp__sift__digest", id: "d1", input: ["target": "Depot"], cwd: "/repo"),
            TranscriptFixture.indexAnswer(id: "d1", text: "tree: App  head: 0000000  dirty: 0  parse_errors: 0\npublic struct Depot — 400 members  :1-402"),
        ]
        let project = directory.appendingPathComponent("projects/-repo")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try Data(lines.flatMap { $0 + [0x0A] }).write(to: project.appendingPathComponent("session.jsonl"))
        return ReportPage.render(ReportData.assemble(
            logURL: log,
            projectsDirectory: directory.appendingPathComponent("projects"),
            roots: [],
            since: nil,
            root: nil,
            now: Date(),
            moduleHealth: { _ in nil }
        ))
    }

    /// The line right under the Estimated savings section's figure.
    private static func captionUnderSavingsFigure(_ page: String) -> Substring? {
        let lines = page.split(separator: "\n")
        guard let section = lines.firstIndex(where: { $0.contains("Estimated savings") }),
              let figure = lines[section...].firstIndex(where: { $0.contains("<p class=\"figure\">") }),
              figure + 1 < lines.count
        else { return nil }
        return lines[figure + 1]
    }

    private static func occurrences(of text: String, in report: String) -> Int {
        report.components(separatedBy: text).count - 1
    }

    /// `usage` states what the figure was priced on once in its headline, with or without unpriced calls beside it, and never says it leans high.
    @Test(arguments: [false, true])
    func usageStatesTheBaselineOnceInItsHeadline(unweighed: Bool) throws {
        let directory = try TemporaryDirectory.make("baseline-once-usage")

        let report = try UsageReport.render(fileURL: Self.log(in: directory, unweighed: unweighed))
        let headline = report.split(separator: "\n").first { $0.hasPrefix("estimated savings — ") }

        #expect(headline?.contains("(\(TokenEstimate.baseline))") == true)
        #expect(Self.occurrences(of: TokenEstimate.baseline, in: report) == 1)
        #expect(!report.contains("leans high"))
        #expect(report.contains("other call unpriced") == unweighed)
    }

    /// The report page says it in the caption under its figure, once, unpriced calls or none.
    @Test(arguments: [false, true])
    func theReportPageStatesTheBaselineOnceUnderItsFigure(unweighed: Bool) throws {
        let directory = try TemporaryDirectory.make("baseline-once-page")

        let page = try Self.page(in: directory, unweighed: unweighed)
        let caption = Self.captionUnderSavingsFigure(page)

        #expect(caption?.contains("<p class=\"caption\">") == true)
        #expect(caption?.contains(TokenEstimate.baseline) == true)
        #expect(Self.occurrences(of: TokenEstimate.baseline, in: page) == 1)
        #expect(!page.contains("leans high"))
        #expect(page.contains("other call unpriced") == unweighed)
    }
}
