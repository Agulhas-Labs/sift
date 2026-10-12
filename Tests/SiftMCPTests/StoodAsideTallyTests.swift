//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCLI
@testable import SiftMCP
import Testing

/// Every tally that counts misses names the lookups the hook stood aside from the same way: the audit's, the replay's own, and the scan windows the dump and the differ read.
@Suite(.temporaryDirectories)
struct StoodAsideTallyTests {
    /// The replay's own audit tally names a stood-aside call under `cold`, as the scan's does, and keeps the miss count.
    @Test func theReplaysAuditTallyReceivesTheStoodAsideCauses() throws {
        let projects = try TemporaryDirectory.make("projects")
        let transcript = projects.appendingPathComponent("replayed.jsonl")
        let lines = [
            TranscriptFixture.toolUse("Read", id: "r1", input: ["file_path": "/repo/Catalogue.swift"]),
            TranscriptFixture.toolResult(id: "r1", isError: false, text: "struct Catalogue {}"),
            TranscriptFixture.toolUse("Read", id: "r2", input: ["file_path": "/repo/BayGeometry.swift"]),
            TranscriptFixture.toolResult(id: "r2", isError: false, text: "struct BayGeometry {}"),
        ]
        try (lines.joined(separator: [0x0A]) + Data([0x0A])).write(to: transcript)
        let log = projects.appendingPathComponent("suppressions.jsonl")
        SuppressionLog(fileURL: log).note(symbol: "backingOff", directory: "/repo", rule: "answerWithheld", call: "r1", fields: [:])
        let probes = ReplayProbes(
            since: nil, until: nil, timeZone: .current,
            belowFloor: { _ in false }, couldAnswer: { _, _ in true }, memberExists: { _, _, _ in true },
            loggedLetThrough: SuppressionLog.callsLetThrough(in: log),
            stoodAside: SuppressionLog.callsStoodAside(in: log)
        )

        let context = TranscriptReplay.replay(transcript, session: transcript, isSubagent: false, probes: probes, hook: FixedVerdictHook())

        #expect(context.tally.cold == 2)
        #expect(context.tally.stoodAside.backingOff == 1)
    }

    /// A context that could not reach the index has its cold windows relabelled `unreachable`, the batched and stood-aside ones with them.
    @Test func aDumpRelabelsEveryColdMissInAnUnreachableContext() throws {
        let projects = try TemporaryDirectory.make("projects")
        let directory = projects.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let transcript = directory.appendingPathComponent("unreachable.jsonl")
        let refusals = (0 ..< TranscriptTally.refusalsWithoutAnIndexCall).flatMap { index in
            [
                TranscriptFixture.toolUse("Read", id: "x\(index)", input: ["file_path": "/repo/Refused\(index).swift"]),
                TranscriptFixture.toolResult(id: "x\(index)", isError: true, text: TranscriptFixture.refusal(call: "digest Refused\(index)")),
            ]
        }
        let reads = [
            TranscriptFixture.toolUse("Read", id: "plain", input: ["file_path": "/repo/Catalogue.swift"]),
            TranscriptFixture.toolResult(id: "plain", isError: false, text: "struct Catalogue {}"),
            TranscriptFixture.toolUse("Read", id: "stood", input: ["file_path": "/repo/BayGeometry.swift"]),
            TranscriptFixture.toolResult(id: "stood", isError: false, text: "struct BayGeometry {}"),
            TranscriptFixture.toolUse("Read", id: "batched", input: ["file_path": "/repo/Depot.swift"]),
            TranscriptFixture.toolResult(id: "batched", isError: false, text: "struct Depot {}"),
        ]
        try ((refusals + reads).joined(separator: [0x0A]) + Data([0x0A])).write(to: transcript)
        let log = projects.appendingPathComponent("suppressions.jsonl")
        SuppressionLog(fileURL: log).note(symbol: "backingOff", directory: "/repo", rule: "answerWithheld", call: "stood", fields: [:])
        SuppressionLog(fileURL: log).note(symbol: "otherStatementsRun", directory: "/repo", rule: "answerWithheld", call: "batched", fields: [:])
        let taken = TranscriptSnapshot.take(projectsDirectory: projects, since: nil, transcript: nil)
        defer { taken.indexes.close() }

        let windows = ScanDumpRequest(snapshot: taken, since: nil, until: nil, suppressionLog: log).windows()

        for call in ["plain", "stood", "batched"] {
            #expect(windows.first { $0.call == call }?.classification == "unreachable", "\(call): \(windows.map(\.classification))")
        }
    }

    /// The differ's cold summary counts a batched or stood-aside window with the plain cold ones.
    @Test func theDiffersColdSummaryCountsEveryColdMiss() {
        let classes = ["cold", "batched", "stoodAside(backingOff)", "stoodAside(overTime)"]
        let theirs = classes.enumerated().map { Self.window("c\($0.offset)", $0.element) }
        let ours = classes.indices.map { Self.window("c\($0)", "guided") }

        let lines = ScanDiff.lines(theirs: theirs, ours: ours, redactor: nil)

        #expect(lines.last == "  scan differs on 4 of 4 windows — guided 0 → 4, cold 4 → 0 (its → this one's)", "\(lines)")
    }

    private static func window(_ call: String, _ classification: String) -> ScoredWindow {
        ScoredWindow(session: "s", call: call, classification: classification, file: "/repo/Depot.swift", locator: nil)
    }
}
