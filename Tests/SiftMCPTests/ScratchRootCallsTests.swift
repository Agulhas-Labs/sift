//
// Copyright © Agulhas Labs
//

import Foundation
import SiftCore
@testable import SiftMCP
import Testing

/// Calls made against probe and scratch roots are not use: `usage` and `report` leave them out, say how many, and `--include-scratch` brings them back.
@Suite(.temporaryDirectories)
struct ScratchRootCallsTests {
    private static let tools = ["digest", "where", "search"]
    private static let scratch = [
        "/tmp/probe", "/private/tmp/probe", "/var/folders/ab/cd/T/probe",
        SiftPaths.accountHome.path + "/Library/Caches/probe", "/work/Depot/.build/verify",
    ]

    /// One real call per tool kind, and five scratch calls, one for each kind of scratch root.
    private static func log(in directory: URL, realRoot: String = "/work/Depot") -> URL {
        let log = directory.appendingPathComponent("usage.jsonl")
        let usage = UsageLog(fileURL: log)
        for tool in tools {
            usage.record(tool: tool, target: "Real", root: realRoot, milliseconds: 5, succeeded: true, answer: AnswerBytes(served: 100, source: 1000), session: "s")
        }
        for (index, root) in scratch.enumerated() {
            usage.record(tool: tools[index % tools.count], target: "Probe", root: root, milliseconds: 5, succeeded: true, answer: AnswerBytes(served: 100, source: 1000), session: "s")
        }
        return log
    }

    @Test
    func scratchCallsAreLeftOutOfTheTotalsAndNoted() throws {
        let log = try Self.log(in: TemporaryDirectory.make("scratch-usage"))

        let report = UsageReport.render(fileURL: log)

        #expect(report.contains("3 calls"))
        #expect(report.contains("5 calls against scratch roots (temporary, cache or .build directories) not counted"))
        #expect(!report.contains("probe"))
        #expect(report.contains("/work/Depot"))
    }

    @Test
    func includeScratchRestoresTodaysTotals() throws {
        let log = try Self.log(in: TemporaryDirectory.make("scratch-include"))

        let report = UsageReport.render(fileURL: log, includeScratch: true)

        #expect(report.contains("8 calls"))
        #expect(!report.contains("against scratch roots"))
        #expect(report.contains("/tmp/probe"))
    }

    @Test
    func aRepositoryNamedBuildIsReal() throws {
        let log = try Self.log(in: TemporaryDirectory.make("scratch-build"), realRoot: "/work/build")

        let report = UsageReport.render(fileURL: log)

        #expect(report.contains("3 calls"))
        #expect(report.contains("/work/build"))
    }

    @Test
    func theReportPageCountsTheSameCalls() throws {
        let directory = try TemporaryDirectory.make("scratch-report")
        let log = Self.log(in: directory)
        let now = Date()
        func assemble(includeScratch: Bool) -> ReportData {
            ReportData.assemble(
                logURL: log, projectsDirectory: directory, roots: [], since: nil, root: nil,
                includeScratch: includeScratch, now: now
            )
        }

        let real = assemble(includeScratch: false)
        #expect(real.calls == 3)
        #expect(real.roots.map(\.root) == ["/work/Depot"])
        #expect(real.scratchNote == "5 calls against scratch roots (temporary, cache or .build directories) not counted")
        #expect(ReportPage.render(real).contains("5 calls against scratch roots"))

        let everything = assemble(includeScratch: true)
        #expect(everything.calls == 8)
        #expect(everything.scratchNote == nil)
    }

    /// The share is drawn from transcripts, so a session recorded in a scratch directory is left out of it as its calls are.
    @Test
    func aSessionRecordedInScratchDoesNotJoinTheShare() throws {
        let directory = try TemporaryDirectory.make("scratch-share")
        let log = Self.log(in: directory)
        let project = directory.appendingPathComponent("projects/-probe", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        var lookup = try #require(JSONSerialization.jsonObject(with: TranscriptFixture.toolUse(
            "Read", id: "a", input: ["file_path": "/probe/BayGeometry.swift"], cwd: "/tmp/probe"
        )) as? [String: Any])
        lookup["timestamp"] = "2026-08-11T12:00:00Z"
        try JSONSerialization.data(withJSONObject: lookup).write(to: project.appendingPathComponent("11112222-3333.jsonl"))
        func share(includeScratch: Bool) -> ReportData.Share? {
            ReportData.assemble(
                logURL: log, projectsDirectory: directory.appendingPathComponent("projects"), roots: [], since: nil, root: nil,
                includeScratch: includeScratch, now: Date()
            ).share
        }

        #expect(share(includeScratch: false) == nil)
        #expect(share(includeScratch: true)?.tally.total == 1)
    }

    @Test
    func theScratchTestIsByPathComponent() {
        #expect(ScratchRoot.contains("/work/Depot/.build/verify"))
        #expect(ScratchRoot.contains("/tmp/x"))
        #expect(!ScratchRoot.contains("/work/build"))
        #expect(!ScratchRoot.contains("/work/tmpfoo"))
        #expect(!ScratchRoot.contains("/work/Depot/.builder"))
    }
}
