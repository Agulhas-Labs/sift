//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCLI
import SiftCore
@testable import SiftMCP
import Testing

/// `audit --replay` as the command puts it together: one snapshot for both passes, and the audit's own counts printed as the audit's beside the replayed share.
@Suite(.temporaryDirectories)
struct AuditCommandTests {
    /// A transcript that grows after the snapshot is counted as the snapshot held it in the audit section and the replay section alike, since the command hands both passes the one snapshot it took.
    @Test func bothSectionsCountTheSnapshotOfATranscriptThatGrowsAfterIt() async throws {
        let root = try await InPlaceAnswerTests.indexedRepository()
        let members = (1 ... 40).map { "    func part\($0)() -> Int {\n        let count = \($0)\n        return count * 2\n    }" }
        try ("/// A gizmo.\nstruct Gizmo {\n" + members.joined(separator: "\n") + "\n}\n")
            .write(to: root.appendingPathComponent("Sources/App/Gizmo.swift"), atomically: true, encoding: .utf8)
        try await SiftEngine(directory: root).ensureFresh()
        let transcript = try TemporaryDirectory.make("projects").appendingPathComponent("replayed-session.jsonl")
        let lines = try TranscriptFixture.answeredCall("mcp__sift__digest", id: "d1", input: ["target": "Alpha"]) + [
            TranscriptAuditReplayTests.call("cat Sources/App/Depot.swift", id: "c1", cwd: root.path, at: "2026-09-20T10:00:00Z"),
            TranscriptFixture.toolResult(id: "c1", isError: false, text: "struct Depot"),
        ]
        try Data(lines.joined(separator: [0x0A]) + [0x0A]).write(to: transcript)
        let snapshot = TranscriptSnapshot.take(projectsDirectory: transcript.deletingLastPathComponent(), since: nil, transcript: transcript.path)

        // The session goes on working after the snapshot: a second cold lookup lands before either pass reads.
        let later = try [
            TranscriptAuditReplayTests.call("cat Sources/App/Gizmo.swift", id: "c2", cwd: root.path, at: "2026-09-20T10:01:00Z"),
            TranscriptFixture.toolResult(id: "c2", isError: false, text: "struct Gizmo"),
        ]
        let handle = try FileHandle(forWritingTo: transcript)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(later.joined(separator: [0x0A])))
        try handle.close()

        let report = try await Self.report(snapshot: snapshot, of: transcript)

        #expect(report.contains("  cold           1  went around the index  ← the misses"), "\(report)")
        #expect(report.contains("  cold            1  the lookups the audit calls cold"), "\(report)")
        #expect(report.contains { $0.contains("— the audit's own 50% —") }, "\(report)")
    }

    /// The share line prints the counts it is handed as the audit's, pooled and for each day, whatever the replay's own walk counted.
    @Test func theShareLinePrintsTheAuditsHandedCounts() async throws {
        let transcript = try TemporaryDirectory.make("projects").appendingPathComponent("replayed-session.jsonl")
        let lines = TranscriptFixture.answeredCall("mcp__sift__digest", id: "d1", input: ["target": "Alpha"])
        try Data(lines.joined(separator: [0x0A]) + [0x0A]).write(to: transcript)
        var tally = TranscriptTally()
        tally.indexed = 3
        tally.cold = 1
        let audited = AuditTallies(tallies: [transcript.path: tally], byDay: [transcript.path: ["2026-09-20": tally]])
        let hook = try HookReplay(directory: TemporaryDirectory.make("hook-replay"), timeBudget: InPlaceAnswerTests.roomy)

        let report = await InPlaceAnswerTests.onItsOwnThread {
            TranscriptReplay.sections(
                projectsDirectory: transcript.deletingLastPathComponent(),
                since: nil,
                transcript: transcript.path,
                hook: hook,
                audited: audited
            ).report
        }

        #expect(report.contains { $0.hasPrefix("  replayed share") && $0.contains("— the audit's own 75% —") }, "\(report)")
        #expect(report.contains { $0.hasPrefix("    2026-09-20") && $0.contains("— the audit's own 75% —") }, "\(report)")
    }

    /// `--summary` keeps the share and the replay's own per-day rows and drops the lists a re-measure re-reads nothing from — the worst-cold-transcripts list and what the searches were reaching for among them.
    @Test func summaryDropsTheListsAndKeepsTheShareAndThePerDayRows() async throws {
        let root = try TemporaryDirectory.make("projects").appendingPathComponent("projects")
        let project = root.appendingPathComponent("-Users-someone-Developer-App")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let transcript = project.appendingPathComponent("11112222-3333.jsonl")
        let cwd = try TemporaryDirectory.make("repo")
        let lines = try [
            TranscriptAuditReplayTests.call("cat Sources/App/Depot.swift", id: "c1", cwd: cwd.path, at: "2026-09-20T10:00:00Z"),
            TranscriptFixture.toolResult(id: "c1", isError: false, text: "struct Depot"),
            TranscriptAuditReplayTests.call("grep -rn ParcelGateway Sources --include=*.swift", id: "c2", cwd: cwd.path, at: "2026-09-20T10:01:00Z"),
            TranscriptFixture.toolResult(id: "c2", isError: false, text: "no matches"),
        ]
        try Data(lines.joined(separator: [0x0A]) + [0x0A]).write(to: transcript)
        let snapshot = TranscriptSnapshot.take(projectsDirectory: root, since: nil, transcript: transcript.path)

        let narrow = try await Self.report(snapshot: snapshot, of: transcript, summary: true)
        let full = try await Self.report(snapshot: snapshot, of: transcript, summary: false)

        #expect(narrow.contains { $0.contains("served by sift") }, "\(narrow)")
        #expect(narrow.contains { $0.hasPrefix("    2026-09-20") }, "\(narrow)")
        #expect(!narrow.contains { $0.contains("cold lookups, worst first") }, "\(narrow)")
        #expect(!narrow.contains { $0.contains("what the searches were reaching for") }, "\(narrow)")

        #expect(full.contains { $0.contains("served by sift") }, "\(full)")
        #expect(full.contains { $0.hasPrefix("    2026-09-20") }, "\(full)")
        #expect(full.contains { $0.contains("cold lookups, worst first") }, "\(full)")
        #expect(full.contains { $0.contains("what the searches were reaching for") }, "\(full)")
    }
}

private extension AuditCommandTests {
    /// `AuditCommand.report` over `snapshot` with the replay, as `audit --replay` runs it, under the roomy time budget and on a thread of its own, split into lines.
    static func report(snapshot: TranscriptSnapshot, of transcript: URL, summary: Bool = false) async throws -> [String] {
        let scratch = try TemporaryDirectory.make("replay")
        let report = await InPlaceAnswerTests.onItsOwnThread {
            AuditCommand.report(
                snapshot: snapshot,
                projectsDirectory: transcript.deletingLastPathComponent(),
                since: nil,
                transcript: transcript.path,
                replay: true,
                scratch: scratch,
                timeBudget: InPlaceAnswerTests.roomy,
                summary: summary
            ).report
        }
        return report.components(separatedBy: "\n")
    }
}
