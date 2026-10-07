//
// Copyright © Agulhas Labs
//

import Foundation
import SiftCore
@testable import SiftMCP
import Testing

/// Every face that prints the saving states its baseline and that it leans high, always and once: `usage` in its headline and the report page in the caption under its figure, whether or not a floor note fires beneath them.
@Suite(.temporaryDirectories)
struct SavingBaselineOnceTests {
    /// A usage-log line the server writes at a fixed second: a digest weighs its source, a `where` records no source and so is unweighed.
    private static func logLine(tool: String, target: String, served: Int, source: Int?) -> String {
        var entry: [String: Any] = [
            "ts": "2026-10-01T10:00:00Z", "tool": tool, "target": target, "root": "/repo", "ms": 4, "ok": true,
            "session": "session", "outBytes": served,
        ]
        entry["srcBytes"] = source
        let data = (try? JSONSerialization.data(withJSONObject: entry)) ?? Data()
        return String(bytes: data, encoding: .utf8) ?? ""
    }

    /// A usage log of one digest, with a `where` beside it when `unweighed` says so, which is what makes the floor note fire.
    private static func log(in directory: URL, unweighed: Bool) throws -> URL {
        let file = directory.appendingPathComponent("usage.jsonl")
        var lines = [logLine(tool: "digest", target: "Depot", served: 1000, source: 41000)]
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

    /// `usage` with nothing unweighed has no floor note, and still says the figure leans high, in its headline.
    @Test(arguments: [false, true])
    func usageStatesTheBaselineOnceInItsHeadline(unweighed: Bool) throws {
        let directory = try TemporaryDirectory.make("baseline-once-usage")

        let report = try UsageReport.render(fileURL: Self.log(in: directory, unweighed: unweighed))
        let headline = report.split(separator: "\n").first { $0.hasPrefix("estimated savings — ") }

        #expect(headline?.hasSuffix("; \(TokenEstimate.baseline)") == true)
        #expect(Self.occurrences(of: "leans high", in: report) == 1)
        #expect(report.contains("leaves out what was not weighed") == unweighed)
    }

    /// The report page says it in the caption under its figure, once, floor note or none.
    @Test(arguments: [false, true])
    func theReportPageStatesTheBaselineOnceUnderItsFigure(unweighed: Bool) throws {
        let directory = try TemporaryDirectory.make("baseline-once-page")

        let page = try Self.page(in: directory, unweighed: unweighed)
        let caption = Self.captionUnderSavingsFigure(page)

        #expect(caption?.contains("<p class=\"caption\">") == true)
        #expect(caption?.contains(TokenEstimate.baseline) == true)
        #expect(Self.occurrences(of: "leans high", in: page) == 1)
        #expect(page.contains("leaves out what was not weighed") == unweighed)
    }
}
