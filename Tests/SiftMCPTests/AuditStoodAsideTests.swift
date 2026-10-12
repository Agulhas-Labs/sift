//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftMCP
import Testing

/// A lookup the hook let run while it was backing off, or after its answer ran out of time, is still a miss in `cold`, and the audit names the cause on a row under it.
@Suite(.temporaryDirectories)
struct AuditStoodAsideTests {
    /// Two whole reads of Swift files no index call located, so two cold misses, and the log beside them.
    private static func session(logging notes: [Note]) throws -> Session {
        let projects = try TemporaryDirectory.make("projects")
        let transcript = projects.appendingPathComponent("stood-aside.jsonl")
        let lines = [
            TranscriptFixture.toolUse("Read", id: "r1", input: ["file_path": "/repo/Catalogue.swift"]),
            TranscriptFixture.toolResult(id: "r1", isError: false, text: "struct Catalogue {}"),
            TranscriptFixture.toolUse("Read", id: "r2", input: ["file_path": "/repo/BayGeometry.swift"]),
            TranscriptFixture.toolResult(id: "r2", isError: false, text: "struct BayGeometry {}"),
        ]
        try (lines.joined(separator: [0x0A]) + Data([0x0A])).write(to: transcript)
        let log = projects.appendingPathComponent("suppressions.jsonl")
        for note in notes {
            SuppressionLog(fileURL: log).note(symbol: note.symbol, directory: "/repo", rule: "answerWithheld", call: note.call, fields: note.fields)
        }
        return Session(projects: projects, transcript: transcript, log: log)
    }

    /// A `backingOff` row on a cold whole Read's call lands in the `backed off` row, and the miss count is the one the same transcript has without the log row.
    @Test func aBackingOffRowNamesTheColdReadAndLeavesTheMissCount() throws {
        let plain = try Self.session(logging: []).report
        let stood = try Self.session(logging: [Note(symbol: "backingOff", call: "r1")]).report

        #expect(plain.contains("cold           2  went around the index"), "\(plain)")
        #expect(plain.contains("backed off   0  of those"), "\(plain)")
        #expect(stood.contains("cold           2  went around the index"), "\(stood)")
        #expect(stood.contains("backed off   1  of those, let through while the hook stood aside after an answer of that shape ran past its time budget (0 overruns)"), "\(stood)")
        #expect(stood.contains("over time    0  of those"), "\(stood)")
        #expect(stood.contains("served by sift — 0% of the lookups that had a choice"), "\(stood)")
    }

    /// An `overTime` row naming a shape is an overrun, and one naming none is not.
    ///
    /// A row naming none is a call whose budget was spent before anything was asked. Both are misses on the `over time` row.
    @Test func anOverTimeRowIsAnOverrunOnlyWhereAShapeRanOut() throws {
        let stood = try Self.session(logging: [
            Note(symbol: "overTime", call: "r1", fields: ["shapes": ["read"], "backoff": 300]),
            Note(symbol: "overTime", call: "r2", fields: ["shapes": [String]()]),
        ]).report

        #expect(stood.contains("cold           2  went around the index"), "\(stood)")
        #expect(stood.contains("over time    2  of those, a lookup whose own answer ran out of time"), "\(stood)")
        #expect(stood.contains("backed off   0  of those, let through while the hook stood aside after an answer of that shape ran past its time budget (1 overrun)"), "\(stood)")

        let none = try Self.session(logging: [Note(symbol: "overTime", call: "r1", fields: ["shapes": [String]()])]).report
        #expect(none.contains("time budget (0 overruns)"), "\(none)")
    }

    /// The cause rides on the call id alone: a call the log does not name, or a verdict that moves a lookup out of `cold`, is not counted here.
    @Test func onlyTheNamedCallsAreCounted() throws {
        let stood = try Self.session(logging: [Note(symbol: "backingOff", call: "elsewhere"), Note(symbol: "notSmaller", call: "r2")]).report

        #expect(stood.contains("backed off   0  of those"), "\(stood)")
        #expect(stood.contains("cold           1  went around the index"), "\(stood)")
    }

    /// The readers keep the two meanings apart: `callsLetThrough` never returns a stood-aside call, which would move it out of `cold`, and `callsStoodAside` never returns a worth verdict.
    @Test func theTwoLogReadersDoNotOverlap() throws {
        let log = try Self.session(logging: [
            Note(symbol: "backingOff", call: "c1"), Note(symbol: "overTime", call: "c2", fields: ["shapes": [String]()]), Note(symbol: "failed", call: "c3"), Note(symbol: "overSize", call: "c4"), Note(symbol: "notSmaller", call: "c5"),
        ]).log

        #expect(SuppressionLog.callsStoodAside(in: log) == ["c1": .backingOff, "c2": .overTime])
        #expect(SuppressionLog.callsLetThrough(in: log) == ["c5": .notSmaller])
    }

    /// Overruns are counted inside the window by their stamp, and an older row with no `shapes` key counts in none.
    @Test func overrunsAreCountedWithinTheWindow() throws {
        let log = try Self.session(logging: [
            Note(symbol: "overTime", call: "c1", fields: ["shapes": ["read"], "backoff": 60]),
            Note(symbol: "overTime", call: "c2"),
            Note(symbol: "backingOff", call: "c3"),
        ]).log

        #expect(SuppressionLog.overruns(in: log) == 1)
        #expect(SuppressionLog.overruns(in: log, since: Date().addingTimeInterval(-3600), until: Date().addingTimeInterval(3600)) == 1)
        #expect(SuppressionLog.overruns(in: log, since: Date().addingTimeInterval(3600)) == 0)
        #expect(SuppressionLog.overruns(in: log, until: Date().addingTimeInterval(-3600)) == 0)
    }

    /// A transcript whose lines are stamped `lateness` hours back, under `cwd`, beside a log holding the hand-written `rows`.
    private static func stampedSession(cwd: String, lateness: Double, rows: [[String: Any]]) throws -> Session {
        let projects = try TemporaryDirectory.make("projects")
        let transcript = projects.appendingPathComponent("stamped.jsonl")
        let stamp = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-lateness * 3600))
        let lines = [
            TranscriptFixture.toolUse("Read", id: "r1", input: ["file_path": "/repo/Catalogue.swift"], cwd: cwd),
            TranscriptFixture.toolResult(id: "r1", isError: false, text: "struct Catalogue {}"),
        ].map { line -> Data in
            var object = (try? JSONSerialization.jsonObject(with: line) as? [String: Any]) ?? [:]
            object["timestamp"] = stamp
            return (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
        }
        try (lines.joined(separator: [0x0A]) + Data([0x0A])).write(to: transcript)
        let log = projects.appendingPathComponent("suppressions.jsonl")
        let body = try rows.map { try JSONSerialization.data(withJSONObject: $0) }
        try (body.joined(separator: [0x0A]) + Data([0x0A])).write(to: log)
        return Session(projects: projects, transcript: transcript, log: log)
    }

    /// An overrun row logged `lateness` days back from `dir`.
    private static func overrun(lateness: Double, dir: String) -> [String: Any] {
        [
            "ts": ISO8601DateFormatter().string(from: Date().addingTimeInterval(-lateness * 86400)), "rule": "answerWithheld", "symbol": "overTime",
            "dir": dir, "shapes": ["read"], "call": "x\(lateness)",
        ]
    }

    /// With no window (`--transcript`), an overrun is counted only if it falls in the span the transcript covers: one logged thirty days before it is not this session's.
    @Test func anOverrunOutsideTheTranscriptsSpanIsNotCounted() throws {
        let session = try Self.stampedSession(cwd: "/repo", lateness: 2, rows: [Self.overrun(lateness: 30, dir: "/repo"), Self.overrun(lateness: 0.04, dir: "/repo")])
        let report = TranscriptAudit.render(projectsDirectory: session.projects, transcript: session.transcript.path, suppressionLog: session.log)

        #expect(report.contains("time budget (1 overrun)"), "\(report)")
    }

    /// With a root, an overrun logged under another directory is not counted; one under the root is.
    @Test func anOverrunLoggedUnderAnotherDirectoryIsNotCountedWithARoot() throws {
        let session = try Self.stampedSession(cwd: "/repo/app", lateness: 2, rows: [Self.overrun(lateness: 0.04, dir: "/elsewhere"), Self.overrun(lateness: 0.05, dir: "/repo/app")])
        let rooted = TranscriptAudit.render(projectsDirectory: session.projects, transcript: session.transcript.path, root: "/repo", suppressionLog: session.log)
        let unrooted = TranscriptAudit.render(projectsDirectory: session.projects, transcript: session.transcript.path, suppressionLog: session.log)

        #expect(rooted.contains("time budget (1 overrun)"), "\(rooted)")
        #expect(unrooted.contains("time budget (2 overruns)"), "\(unrooted)")
    }

    /// A call the log names both let through on worth and backed off scores as not worth whichever row came last, and a back-off row on a call the hook answered changes nothing.
    @Test func theLetThroughVerdictOutranksABackOff() throws {
        let worth = try Self.session(logging: [Note(symbol: "notSmaller", call: "r1")]).report
        for notes in [
            [Note(symbol: "notSmaller", call: "r1"), Note(symbol: "backingOff", call: "r1")],
            [Note(symbol: "backingOff", call: "r1"), Note(symbol: "notSmaller", call: "r1")],
        ] {
            let both = try Self.session(logging: notes).report

            #expect(both.contains("backed off   0  of those"), "\(both)")
            #expect(both.contains("cold           1  went around the index"), "\(both)")
            #expect(both.contains("not worth      1  not worth the round trips it would have cost to answer these"), "\(both)")
            #expect(worth.contains("not worth      1  not worth the round trips it would have cost to answer these"), "\(worth)")
        }

        let answered = try Self.session(logging: [Note(symbol: "backingOff", call: "r1")])
        let answeredLog = AnsweredLog.fileURL(besideSuppressionLog: answered.log)
        try Data("{\"call\":\"r1\",\"ts\":\"\(ISO8601DateFormatter().string(from: Date()))\"}\n".utf8).write(to: answeredLog)
        let plain = try Self.session(logging: []).report
        let withAnswer = answered.report

        #expect(!withAnswer.contains("backed off   1"), "\(withAnswer)")
        #expect(withAnswer.contains("backed off   0  of those"), "\(withAnswer)")
        #expect(plain.contains("backed off   0  of those"), "\(plain)")
    }

    /// A stood-aside lookup is a cold miss in the tally, and a retraction takes both counts back.
    @Test func aStoodAsideLookupIsAColdMissAndIsRetractedWhole() {
        var tally = TranscriptTally(indexed: 1)
        tally.fold(.lookup(.stoodAside(file: "Sources/App/Depot.swift", why: .backingOff)))

        #expect(tally.cold == 1)
        #expect(tally.stoodAside.backingOff == 1)
        #expect(tally.shareText == "50%")

        tally.fold(.lookupRetracted(.stoodAside(file: "Sources/App/Depot.swift", why: .backingOff)))
        #expect(tally == TranscriptTally(indexed: 1))
    }
}

extension AuditStoodAsideTests {
    /// One suppression-log row to write: the withholding logged for a call, with any fields beside it.
    private struct Note {
        let symbol: String
        let call: String
        var fields: [String: Any] = [:]
    }

    /// A transcript and the log beside it.
    private struct Session {
        let projects: URL
        let transcript: URL
        let log: URL

        var report: String {
            TranscriptAudit.render(projectsDirectory: projects, transcript: transcript.path, suppressionLog: log)
        }
    }
}
