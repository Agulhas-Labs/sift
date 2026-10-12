//
// Copyright © Agulhas Labs
//

import Foundation
import SiftCore
@testable import SiftMCP
import Testing

/// An intercepted whole-file read is priced against what one `Read` returns at most, so a document outline stays out of the saving and a huge file is credited no more than that window.
@Suite(.temporaryDirectories)
struct UsageSavingsCounterfactualTests {
    /// What the hook records for a whole file longer than one `Read`: the bytes of its first 2,000 lines.
    static let readBytes = 100_000

    private func log(_ name: String, _ calls: [(target: String, answer: AnswerBytes)]) throws -> URL {
        let url = try TemporaryDirectory.make(name).appendingPathComponent("usage.jsonl")
        for call in calls {
            UsageLog(fileURL: url).record(
                tool: "digest", target: call.target, root: "/repo", milliseconds: 40, succeeded: true,
                answer: call.answer, session: "s1", via: "hook", intercepted: "file", readBytes: min(call.answer.source ?? 0, Self.readBytes)
            )
        }
        return url
    }

    @Test
    func aMarkdownOutlineIsLeftOutOfTheHeadlineSaving() throws {
        let url = try log("usage-markdown", [
            ("Docs/Designs/Depot/NEXT_SESSION.md", AnswerBytes(served: 4900, source: 184_600)),
            ("Sources/App/Depot.swift", AnswerBytes(served: 3000, source: 23000)),
        ])

        let scan = try UsageScan.load(fileURL: url).get()
        let savings = try #require(scan.savings)

        #expect(savings.total.source == 23000)
        #expect(savings.total.calls == 1)
        #expect(scan.markdown?.row.calls == 1)
        #expect(scan.markdown?.row.served == 4900)
        #expect(scan.markdown?.row.source == 184_600)
    }

    @Test
    func theUsageSummaryReportsMarkdownOnItsOwnLineNotAsSaved() throws {
        let url = try log("usage-markdown-line", [
            ("Docs/Designs/Depot/NEXT_SESSION.md", AnswerBytes(served: 4900, source: 184_600)),
            ("Sources/App/Depot.swift", AnswerBytes(served: 3000, source: 23000)),
        ])

        let report = UsageReport.render(fileURL: url)

        #expect(report.contains("Markdown outlines: 1 call, 4.9 kB served for 184 kB of documents"))
        #expect(report.contains("~5.0k tokens saved on 1 intercepted read (file or window asked for − answer served) — 20 kB gross"))
    }

    @Test
    func aFileLongerThanOneReadIsCreditedOnlyTheReadWindow() throws {
        let url = try log("usage-window", [("Sources/App/Depot.swift", AnswerBytes(served: 6000, source: 900_000))])

        let savings = try #require(try UsageScan.load(fileURL: url).get().savings)

        #expect(savings.total.source == Self.readBytes)
        #expect(savings.total.saved == Self.readBytes - 6000)
    }

    @Test
    func aFileWithinOneReadIsCreditedInFull() throws {
        let url = try log("usage-within-window", [("Sources/App/Depot.swift", AnswerBytes(served: 3000, source: 23000))])

        let savings = try #require(try UsageScan.load(fileURL: url).get().savings)

        #expect(savings.total.source == 23000)
    }

    private func spacedLog(_ name: String, target: String, answer: AnswerBytes, parts: [MeasuredAnswer.Part] = []) throws -> URL {
        let url = try TemporaryDirectory.make(name).appendingPathComponent("usage.jsonl")
        UsageLog(fileURL: url).record(
            tool: "digest", target: target, root: "/repo", milliseconds: 40, succeeded: true,
            answer: answer, session: "s1", via: "hook", intercepted: "file", readBytes: Self.readBytes, parts: parts
        )
        return url
    }

    private func part(_ target: String, _ source: Int) -> MeasuredAnswer.Part {
        MeasuredAnswer.Part(target: target, file: nil, servedInstead: false, source: source)
    }

    @Test(arguments: ["Docs/Big.md Sources/App/Depot.swift", "Sources/App/Depot.swift Docs/Big.md"])
    func aSpacedMixedTargetWithoutPartsIsCodeInEitherOrder(_ target: String) throws {
        let url = try spacedLog("usage-spaced-mixed", target: target, answer: AnswerBytes(served: 8000, source: 900_000))

        let scan = try UsageScan.load(fileURL: url).get()
        let savings = try #require(scan.savings)

        #expect(savings.total.source == Self.readBytes)
        #expect(scan.markdown == nil)
    }

    @Test
    func aSpacedMarkdownOnlyTargetIsMarkdownWhateverItsLastWord() throws {
        let url = try spacedLog("usage-spaced-markdown", target: "Docs/A.md Docs/B.md", answer: AnswerBytes(served: 8000, source: 300_000))

        let scan = try UsageScan.load(fileURL: url).get()

        #expect(scan.savings == nil)
        #expect(scan.markdown?.row.source == 300_000)
    }

    @Test(arguments: ["Docs/Big.md Sources/App/Depot.swift", "Sources/App/Depot.swift Docs/Big.md"])
    func aMixedCallWithPartsIsSplitPartByPart(_ target: String) throws {
        let names = target.split(separator: " ").map(String.init)
        let parts = names.map { part($0, $0.hasSuffix(".md") ? 184_000 : 900_000) }
        let url = try spacedLog("usage-parts", target: target, answer: AnswerBytes(served: 10000, source: 1_084_000), parts: parts)

        let scan = try UsageScan.load(fileURL: url).get()
        let savings = try #require(scan.savings)
        let markdown = try #require(scan.markdown)

        #expect(savings.total.source == Self.readBytes)
        #expect(markdown.row.source == 184_000)
        #expect(savings.total.served + markdown.row.served == 10000)
    }

    @Test
    func aWindowOfOnlyMarkdownIsReportedByUsageNotCalledUnmeasured() throws {
        let url = try log("usage-markdown-only", [("Docs/Big.md", AnswerBytes(served: 4900, source: 184_600))])

        let report = UsageReport.render(fileURL: url)

        #expect(report.contains("Markdown outlines: 1 call, 4.9 kB served for 184 kB of documents"))
        #expect(!report.contains("   1  Markdown outlines: 1 call"))
    }

    @Test
    func aWindowOfOnlyMarkdownStatesNoSavingOnTheReportPage() throws {
        let url = try log("usage-markdown-page", [("Docs/Big.md", AnswerBytes(served: 4900, source: 184_600))])
        let projects = url.deletingLastPathComponent().appendingPathComponent("projects")
        try FileManager.default.createDirectory(at: projects, withIntermediateDirectories: true)

        let page = ReportPage.render(ReportData.assemble(
            logURL: url, projectsDirectory: projects, roots: [], since: nil, root: nil, now: Date(), moduleHealth: { _ in nil }
        ))

        #expect(page.contains("No saving is priced in this window"))
        #expect(page.contains("Markdown outlines: 1 call"))
    }

    @Test
    func theAuditNamesMarkdownOutlinesWhetherOrNotCodeCallsMeasured() throws {
        let only = try log("usage-markdown-audit-only", [("Docs/Big.md", AnswerBytes(served: 4900, source: 184_600))])
        let mixed = try log("usage-markdown-audit-mixed", [
            ("Docs/Big.md", AnswerBytes(served: 4900, source: 184_600)),
            ("Sources/App/Depot.swift", AnswerBytes(served: 3000, source: 23000)),
        ])

        let onlyLine = try #require(AuditLoggedSaving.line(only, since: nil, until: nil, root: nil))
        let mixedLine = try #require(AuditLoggedSaving.line(mixed, since: nil, until: nil, root: nil))

        #expect(onlyLine.contains("the usage log prices no call for this window, and holds Markdown outlines beside"))
        #expect(onlyLine.contains("Markdown outlines: 1 call, 4.9 kB served"))
        #expect(mixedLine.contains("Markdown outlines apart"))
        #expect(mixedLine.contains("Markdown outlines: 1 call, 4.9 kB served"))
    }

    @Test
    func theMarkdownLineSitsAfterTheSubagentLine() throws {
        let url = try TemporaryDirectory.make("usage-markdown-order").appendingPathComponent("usage.jsonl")
        for (target, answer) in [
            ("Docs/Big.md", AnswerBytes(served: 4900, source: 184_600)),
            ("Sources/App/Depot.swift", AnswerBytes(served: 3000, source: 23000)),
        ] {
            UsageLog(fileURL: url).record(
                tool: "digest", target: target, root: "/repo", milliseconds: 40, succeeded: true,
                answer: answer, agent: "a1", session: "s1", via: "hook", intercepted: "file"
            )
        }

        let report = UsageReport.render(fileURL: url)
        let subagent = try #require(report.range(of: "subagent")?.lowerBound)
        let markdown = try #require(report.range(of: "Markdown outlines:")?.lowerBound)

        #expect(subagent < markdown)
    }
}
