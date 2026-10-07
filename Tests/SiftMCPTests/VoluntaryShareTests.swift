//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCLI
@testable import SiftMCP
import Testing

/// Covers the voluntary share: the lookups the agent chose the index for, out of those that had a choice, which the headline share hides by counting the hook's own answers.
@Suite(.temporaryDirectories)
struct VoluntaryShareTests {
    /// The first trial figures: 22 indexed, 2 of them the hook's, 3 cold.
    @Test
    func aTrialWithTwoHookAnswersReadsEightyPercentVoluntary() {
        let tally = TranscriptTally(indexed: 22, cold: 3, answered: 2)

        #expect(tally.voluntary == 20)
        #expect(tally.voluntaryShareText == "80% = (22 indexed − 2 answered) / (22 indexed + 3 cold)")
        #expect(TranscriptAudit.voluntaryLine(tally)
            == "  voluntary   \(TranscriptAudit.pad(20))  chosen by the agent, not answered by the hook — 80% = (22 indexed − 2 answered) / (22 indexed + 3 cold) of the lookups that had a choice")
    }

    /// The second trial figures: seven indexed, none answered by the hook, thirteen cold.
    @Test
    func aTrialWithNoHookAnswersReadsThirtyFivePercentVoluntary() {
        let tally = TranscriptTally(indexed: 7, cold: 13, answered: 0)

        #expect(tally.voluntaryShareText == "35% = (7 indexed − 0 answered) / (7 indexed + 13 cold)")
    }

    /// No lookup had a choice, so there is no share to state, and a small nonzero one is never printed as zero.
    @Test
    func anEmptyDenominatorIsNotAvailableAndASmallShareIsFloored() {
        #expect(TranscriptTally().voluntaryShareText == nil)
        #expect(TranscriptAudit.voluntaryLine(TranscriptTally()).contains("— n/a of the lookups"))
        #expect(TranscriptTally(indexed: 1, cold: 300).voluntaryShareText?.hasPrefix("<1% = ") == true)
    }

    /// The share flag's whole output: the headline and the voluntary share, each with its fraction, and nothing else.
    @Test
    func theShareFlagPrintsExactlyTwoLines() {
        let lines = TranscriptAudit.shareLines(TranscriptTally(indexed: 22, cold: 3, answered: 2))

        #expect(lines.count == 2)
        #expect(lines[0] == "served by sift — 88% = 22 / 25 of the lookups that had a choice")
        #expect(lines[1] == "voluntary — 80% = (22 indexed − 2 answered) / (22 indexed + 3 cold) of the lookups that had a choice")
    }

    /// The full report and the summary both carry the row, straight under the indexed one, and the share-only report is the two lines alone.
    @Test
    func theAuditPrintsTheRowInBothFormsAndShareOnlyCutsTheRest() throws {
        let root = try TemporaryDirectory.make("voluntary").appendingPathComponent("projects")
        let directory = root.appendingPathComponent("-Users-someone-Developer-App")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let read: [String: Any] = [
            "type": "assistant",
            "message": ["content": [["type": "tool_use", "id": "a", "name": "Read", "input": ["file_path": "/repo/Depot.swift"]]]],
        ]
        let line = try String(bytes: JSONSerialization.data(withJSONObject: read), encoding: .utf8) ?? ""
        try (line + "\n").write(to: directory.appendingPathComponent("11112222-3333.jsonl"), atomically: true, encoding: .utf8)

        let summary = TranscriptAudit.render(projectsDirectory: root, summary: true).components(separatedBy: "\n")
        let full = TranscriptAudit.render(projectsDirectory: root).components(separatedBy: "\n")
        let only = TranscriptAudit.render(projectsDirectory: root, shareOnly: true).components(separatedBy: "\n")

        for report in [summary, full] {
            let indexed = try #require(report.firstIndex { $0.hasPrefix("  indexed ") })
            #expect(report[indexed + 1].hasPrefix("  voluntary "), "\(report)")
            #expect(report[indexed + 1].contains("0% = (0 indexed − 0 answered) / (0 indexed + 1 cold)"), "\(report)")
        }

        #expect(only.count == 2, "\(only)")
        #expect(only[1].hasPrefix("voluntary — "), "\(only)")
    }

    /// The flag has no replay form, so the two together are refused before anything runs.
    @Test
    func theShareFlagRefusesReplay() throws {
        #expect(throws: (any Error).self) { try AuditCommand.parse(["--share", "--replay"]) }
        #expect(throws: Never.self) { try AuditCommand.parse(["--share", "--since", "today", "--root", "x"]) }
    }
}
