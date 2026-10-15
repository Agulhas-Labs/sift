//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftMCP
import Testing

/// The first line of `sift audit` names the share of every Swift lookup sift served, so the `indexed` row's narrower percentage is not the only one a reader meets.
@Suite(.temporaryDirectories)
struct AuditPlainShareTests {
    private static func write(_ lines: [Data], to directory: URL) throws -> URL {
        let project = directory.appendingPathComponent("projects/-repo")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try Data(lines.flatMap { $0 + [0x0A] }).write(to: project.appendingPathComponent("session.jsonl"))
        return directory.appendingPathComponent("projects")
    }

    /// One lookup in three went to the index: the line reads 33% of all three, whatever the `indexed` row says of the lookups that had a choice.
    @Test func theFirstLineCarriesSiftsServedOverEveryLookupByAnyRoute() throws {
        let directory = try TemporaryDirectory.make("audit-plain-share")
        let projects = try Self.write([
            TranscriptFixture.toolUse("mcp__sift__digest", id: "d1", input: ["target": "Sources/App/Depot.swift"]),
            TranscriptFixture.indexAnswer(id: "d1", text: "tree: App\nSources/App/Depot.swift — module: App"),
            TranscriptFixture.toolUse("Read", id: "r1", input: ["file_path": "/repo/Sources/App/A.swift"]),
            TranscriptFixture.toolResult(id: "r1", isError: false, text: "struct A {}"),
            TranscriptFixture.toolUse("Read", id: "r2", input: ["file_path": "/repo/Sources/App/B.swift"]),
            TranscriptFixture.toolResult(id: "r2", isError: false, text: "struct B {}"),
        ], to: directory)

        let report = TranscriptAudit.render(projectsDirectory: projects, since: nil, timeZone: .gmt)

        #expect(report.hasPrefix("audit — 1 session, 3 Swift lookups by any route, 1 served by sift (33%)\n"), "\(report)")
    }

    /// With no lookups there is no share to name, and a share under half a percent reads `<1%` rather than a bare 0 beside a count above zero.
    @Test func noLookupsPrintNoPercentAndASmallShareIsFloored() {
        #expect(TranscriptAudit.plainShare(served: 0, of: 0).isEmpty)
        #expect(TranscriptAudit.plainShare(served: 1, of: 300) == " (<1%)")
        #expect(TranscriptAudit.plainShare(served: 0, of: 5) == " (0%)")
        #expect(TranscriptAudit.plainShare(served: 4, of: 15) == " (27%)")
    }

    /// 199 of 200 rounds to 100, which beside a count that is not everything reads as all of it: capped at 99%, and only everything is 100%.
    @Test func aShareShortOfEverythingIsCappedAtNinetyNine() {
        #expect(TranscriptAudit.plainShare(served: 199, of: 200) == " (99%)")
        #expect(TranscriptAudit.plainShare(served: 999, of: 1000) == " (99%)")
        #expect(TranscriptAudit.plainShare(served: 200, of: 200) == " (100%)")
    }
}
