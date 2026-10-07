//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCLI
import SiftCore
@testable import SiftMCP
import Testing

/// `audit --replay --summary`: the replay section cut to its narrowest reading, with and without `--against`.
@Suite(.temporaryDirectories)
struct ReplaySummaryShapeTests {
    /// Without `--against`, `--summary` drops the still-cold rule rows and every shape block beneath them, keeping only the replayed share.
    @Test func summaryDropsStillColdRowsAndShapeBlocks() {
        var context = ContextReplay()
        context.count(.stillCold("noLookup"), day: "2026-09-20", call: ReplayColdCall(text: "sed -n 95,135p Sources/Orchard/Alpha.swift"))
        context.count(.stillCold("noLookup"), day: "2026-09-20", call: ReplayColdCall(text: "sed -n 1,30p Sources/Orchard/Beta.swift"))

        let full = TranscriptReplay.render([context], unredacted: true)
        let narrow = TranscriptReplay.render([context], unredacted: true, summary: true)

        #expect(full.contains("         2  noLookup"), "\(full)")
        #expect(full.contains { $0.contains("sed -n <range> <file>") }, "\(full)")

        #expect(!narrow.contains { $0.contains("still cold") }, "\(narrow)")
        #expect(!narrow.contains { $0.contains("noLookup") }, "\(narrow)")
        #expect(!narrow.contains { $0.contains("sed -n <range> <file>") }, "\(narrow)")
        #expect(narrow.contains { $0.hasPrefix("  replayed share") }, "\(narrow)")
    }

    /// Combined with `--replay`, `--summary` drops the audit's own lists (the worst-cold-transcripts list) as well as the replay's structure, keeping the share the audit and the replay each print.
    @Test func summaryWithReplayDropsTheAuditsOwnListsToo() async throws {
        let root = try TemporaryDirectory.make("projects").appendingPathComponent("projects")
        let project = root.appendingPathComponent("-Users-someone-Developer-App")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let transcript = project.appendingPathComponent("11112222-3333.jsonl")
        let cwd = try TemporaryDirectory.make("repo")
        let lines = try [
            TranscriptAuditReplayTests.call("cat Sources/App/Depot.swift", id: "c1", cwd: cwd.path, at: "2026-09-20T10:00:00Z"),
            TranscriptFixture.toolResult(id: "c1", isError: false, text: "struct Depot"),
        ]
        try Data(lines.joined(separator: [0x0A]) + [0x0A]).write(to: transcript)
        let snapshot = TranscriptSnapshot.take(projectsDirectory: root, since: nil, transcript: transcript.path)
        let scratch = try TemporaryDirectory.make("replay")

        let report = await InPlaceAnswerTests.onItsOwnThread {
            AuditCommand.report(
                snapshot: snapshot,
                projectsDirectory: root,
                since: nil,
                transcript: transcript.path,
                replay: true,
                scratch: scratch,
                timeBudget: InPlaceAnswerTests.roomy,
                summary: true
            ).report
        }
        let narrow = report.components(separatedBy: "\n")

        #expect(!narrow.contains { $0.contains("cold lookups, worst first") }, "\(narrow)")
        #expect(!narrow.contains { $0.contains("still cold") }, "\(narrow)")
        #expect(!narrow.contains { $0.hasPrefix("  recovered") }, "\(narrow)")
        #expect(narrow.contains { $0.hasPrefix("  replayed share") }, "\(narrow)")
    }

    /// With `--against`, rows that differ only in which suppression-logged rule a call now lands on fold into one, in the summary shape only.
    @Test func summaryFoldsRowsThatOnlyDifferByTheirLoggedRule() {
        var context = ContextReplay()
        let theirs = ReplayVerdict(token: "allowed", rule: "noLookup")
        context.compare(
            theirs,
            with: ReplayVerdict(token: "in-place", rule: ReplayVerdict.logged("AlphaRule")),
            payload: ["tool_name": "Bash", "tool_input": ["command": "cat Sources/App/Alpha.swift"]]
        )
        context.compare(
            theirs,
            with: ReplayVerdict(token: "in-place", rule: ReplayVerdict.logged("BetaRule")),
            payload: ["tool_name": "Bash", "tool_input": ["command": "cat Sources/App/Beta.swift"]]
        )

        let full = ReplayComparison.lines([context])
        let narrow = ReplayComparison.lines([context], summary: true)

        #expect(full.contains { $0.contains("noLookup → AlphaRule (logged)") }, "\(full)")
        #expect(full.contains { $0.contains("noLookup → BetaRule (logged)") }, "\(full)")

        #expect(!narrow.contains { $0.contains("AlphaRule") || $0.contains("BetaRule") }, "\(narrow)")
        #expect(narrow.contains { $0.contains("2  noLookup → <rule> (logged)") }, "\(narrow)")
        #expect(narrow.contains { $0.hasPrefix("  differ") }, "\(narrow)")
    }
}
