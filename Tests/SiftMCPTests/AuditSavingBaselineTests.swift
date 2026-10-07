//
// Copyright © Agulhas Labs
//

import Foundation
import SiftCore
@testable import SiftMCP
import Testing

/// `audit` states the baseline every saving is priced against, so the figure can be bounded rather than read as measured.
@Suite(.temporaryDirectories)
struct AuditSavingBaselineTests {
    /// The summary carries the baseline line, with the ratio and the direction the estimate leans.
    @Test
    func theSummaryStatesTheSavingsBaseline() throws {
        let projects = try TemporaryDirectory.make("audit-baseline").appendingPathComponent("projects")
        let session = projects.appendingPathComponent("-repo")
        try FileManager.default.createDirectory(at: session, withIntermediateDirectories: true)
        let lines = [TranscriptFixture.toolUse("Read", id: "r1", input: ["file_path": "/repo/Sources/App/Depot.swift"], cwd: "/repo")]
        try Data(lines.flatMap { $0 + [0x0A] }).write(to: session.appendingPathComponent("session.jsonl"))

        let report = TranscriptAudit.render(projectsDirectory: projects, summary: true)

        #expect(report.contains("    baseline  a saving is the source a digest replaced less the bytes it served, at 4 bytes a token, "
                + "priced as if each file would otherwise be read whole; a ranged read or a grep costs less, so the figure leans high"))
    }
}
