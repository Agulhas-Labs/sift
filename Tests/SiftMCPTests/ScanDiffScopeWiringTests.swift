//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftMCP
import Testing

/// `audit --scan-diff --root`: how another binary's windows are joined to this build's under a scope, and how the options reach the scan.
@Suite(.temporaryDirectories) struct ScanDiffScopeWiringTests {
    /// Windows an older binary keys by a promoted agent's own file name join this build's, which key it by its parent, so nothing diffs.
    @Test func anOlderBinarysPromotedAgentWindowsJoinTheParents() throws {
        let (_, taken) = try Self.snapshot()
        defer { taken.indexes.close() }
        let scoped = taken.scoped(to: "/nowhere/orchard")
        let ours = ScanDumpRequest(snapshot: scoped, since: nil, until: nil, suppressionLog: nil).windows()
        let theirs = ours.map { window in
            ScoredWindow(session: window.session == "outside" ? "agent-a1" : window.session, call: window.call, part: window.part, classification: window.classification, file: window.file, locator: window.locator)
        }

        let raw = ScanDiff.lines(theirs: theirs, ours: ours, redactor: nil)
        let joined = ScanDiff.lines(theirs: scoped.attributing(theirs), ours: ours, redactor: nil)

        #expect(ours.contains { $0.session == "outside" }, "\(ours)")
        #expect(raw.last?.hasPrefix("  scan differs on 2 of 3 windows") == true, "\(raw)")
        #expect(joined.last?.hasPrefix("  scan differs on 0 of 2 windows") == true, "\(joined)")
    }

    /// The plan scopes the snapshot to the root and carries the all-windows option to the listing.
    @Test func theScanPlanScopesTheSnapshotAndListsAsAsked() throws {
        let (projects, taken) = try Self.snapshot()
        defer { taken.indexes.close() }

        let scoped = ScanDiffPlan(taken: taken, root: "/nowhere/orchard", allWindows: true, since: nil, until: nil, projectsDirectory: projects, redactor: nil)
        let whole = ScanDiffPlan(taken: taken, root: nil, allWindows: false, since: nil, until: nil, projectsDirectory: projects, redactor: nil)

        #expect(scoped.snapshot.sessions.map(\.lastPathComponent).sorted() == ["agent-a1.jsonl", "inside.jsonl"])
        #expect(scoped.listsAll)
        #expect(scoped.refusal == nil)
        #expect(whole.snapshot.sessions.count == 2)
        #expect(!whole.listsAll)
    }

    /// A root no transcript ran in is refused with the plain audit's answer, naming where the sessions did run.
    @Test func aRootNoSessionRanInIsRefused() throws {
        let (projects, taken) = try Self.snapshot()
        defer { taken.indexes.close() }

        let plan = ScanDiffPlan(taken: taken, root: "/nowhere/orchard/none", allWindows: false, since: Date(timeIntervalSince1970: 0), until: nil, projectsDirectory: projects, redactor: nil)

        #expect(plan.snapshot.sessions.isEmpty)
        #expect(plan.refusal?.hasPrefix("no session in that window ran in /nowhere/orchard/none or below it") == true, "\(plan.refusal ?? "nil")")
    }

    /// Two sessions, one in the orchard and one elsewhere with a subagent in the orchard, and the snapshot of them.
    private static func snapshot() throws -> (URL, TranscriptSnapshot) {
        let projects = try TemporaryDirectory.make("projects")
        let directory = projects.appendingPathComponent("project", isDirectory: true)
        let agents = directory.appendingPathComponent("outside/subagents", isDirectory: true)
        try FileManager.default.createDirectory(at: agents, withIntermediateDirectories: true)
        try write("inside", cwd: "/nowhere/orchard/app", call: "i1", in: directory)
        try write("outside", cwd: "/nowhere/elsewhere", call: "o1", in: directory)
        try write("agent-a1", cwd: "/nowhere/orchard", call: "a1", in: agents)
        return (projects, TranscriptSnapshot.take(projectsDirectory: projects, since: nil, transcript: nil))
    }

    /// A transcript named `name` in `directory` holding one ranged read, `call`, recorded in `cwd`.
    private static func write(_ name: String, cwd: String, call: String, in directory: URL) throws {
        let lines = [
            TranscriptFixture.toolUse("Read", id: call, input: ["file_path": "/nowhere/Sources/\(call).swift", "offset": 10, "limit": 20], cwd: cwd),
            TranscriptFixture.toolResult(id: call, isError: false, text: "struct Depot"),
        ]
        try Data(lines.joined(separator: [0x0A])).write(to: directory.appendingPathComponent("\(name).jsonl"))
    }
}
