//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftMCP
import Testing

/// Covers the dates the audit's findings carry.
///
/// The default window is a week, and a report shared without dates reads every miss as current — days after an update may have fixed the behaviour behind most of them.
@Suite(.temporaryDirectories)
struct TranscriptAuditDateTests {
    private static func toolUse(_ name: String, id: String = "t1", at timestamp: String? = nil, input: [String: Any] = [:]) -> String {
        var object: [String: Any] = [
            "type": "assistant",
            "message": ["content": [["type": "tool_use", "id": id, "name": name, "input": input]]],
        ]
        if let timestamp {
            object["timestamp"] = timestamp
        }
        let data = (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
        return String(bytes: data, encoding: .utf8) ?? ""
    }

    /// A digest's answer text, for the follow-up scan to parse members out of.
    private static func digestAnswer(id: String, text: String) -> String {
        let object: [String: Any] = [
            "type": "user",
            "message": ["content": [["type": "tool_result", "tool_use_id": id, "content": [["type": "text", "text": text]]]]],
        ]
        let data = (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
        return String(bytes: data, encoding: .utf8) ?? ""
    }

    /// A result line in the shape the transcript writes it — the call's id and, on a failure, the error flag, and never the tool's name, which a real result does not carry.
    private static func toolResult(id: String, isError: Bool) -> String {
        var result: [String: Any] = ["type": "tool_result", "tool_use_id": id]
        if isError {
            result["is_error"] = true
        }
        let object: [String: Any] = ["type": "user", "message": ["content": [result]]]
        let data = (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
        return String(bytes: data, encoding: .utf8) ?? ""
    }

    /// Builds a `projects/<project>/<session>.jsonl` tree, optionally with subagent transcripts beside it.
    private static func projects(session: [String], subagents: [[String]] = []) throws -> URL {
        let root = try TemporaryDirectory.make("audit-dates").appendingPathComponent("audit-dates")
        let directory = root.appendingPathComponent("-Users-someone-Developer-App")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let transcript = directory.appendingPathComponent("11112222-3333.jsonl")
        try (session.joined(separator: "\n") + "\n").write(to: transcript, atomically: true, encoding: .utf8)

        if !subagents.isEmpty {
            let agents = directory.appendingPathComponent("11112222-3333").appendingPathComponent("subagents")
            try FileManager.default.createDirectory(at: agents, withIntermediateDirectories: true)
            for (index, lines) in subagents.enumerated() {
                try (lines.joined(separator: "\n") + "\n")
                    .write(to: agents.appendingPathComponent("agent-\(index).jsonl"), atomically: true, encoding: .utf8)
            }
        }
        return root
    }

    /// The day the report will print for an instant.
    ///
    /// Resolved locally, as the report does, so these tests hold on any machine's timezone rather than only where local midday matches UTC's day.
    private static func localDay(_ instant: String, sourceLocation: SourceLocation = #_sourceLocation) throws -> String {
        let date = try #require(ISO8601DateFormatter().date(from: instant), sourceLocation: sourceLocation)
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = .current
        return formatter.string(from: date)
    }

    /// The reason this suite exists: a transcript row names the day its misses happened, so a report covering a week cannot pass off an old miss as a current one.
    @Test
    func aTranscriptsMissesCarryTheDayTheyHappened() throws {
        let day = try Self.localDay("2026-08-04T12:00:00Z")
        let root = try Self.projects(session: [
            Self.toolUse("Read", id: "a", at: "2026-08-04T12:00:00Z", input: ["file_path": "/repo/BayGeometry.swift"]),
        ])

        let report = TranscriptAudit.render(projectsDirectory: root)

        #expect(report.contains("App · 11112222 · \(day)"))
    }

    /// Misses spread over several days render as the span, not silently as one of them.
    @Test
    func missesSpanningDaysShowTheSpan() throws {
        let first = try Self.localDay("2026-08-04T12:00:00Z")
        let last = try Self.localDay("2026-08-07T12:00:00Z")
        let root = try Self.projects(session: [
            Self.toolUse("Read", id: "a", at: "2026-08-04T12:00:00Z", input: ["file_path": "/repo/BayGeometry.swift"]),
            Self.toolUse("Read", id: "b", at: "2026-08-07T12:00:00Z", input: ["file_path": "/repo/DepotCatalog.swift"]),
        ])

        let report = TranscriptAudit.render(projectsDirectory: root)

        #expect(report.contains("\(first) – \(last)"))
    }

    /// A line with no timestamp still counts; it just renders undated rather than inventing a day.
    @Test
    func anUndatedMissRendersWithoutADate() throws {
        let root = try Self.projects(session: [
            Self.toolUse("Read", id: "a", input: ["file_path": "/repo/BayGeometry.swift"]),
        ])

        let report = TranscriptAudit.render(projectsDirectory: root)

        #expect(report.contains("BayGeometry.swift"))
        #expect(report.range(of: #"\d{4}-\d{2}-\d{2}"#, options: .regularExpression) == nil)
    }

    /// A retracted read is struck with the day it rode in on, or a span still names a day whose only miss was taken back.
    @Test
    func aRetractedMissTakesItsDayWithIt() throws {
        let kept = try Self.localDay("2026-08-04T12:00:00Z")
        let retracted = try Self.localDay("2026-08-07T12:00:00Z")
        let root = try Self.projects(session: [
            Self.toolUse("Read", id: "a", at: "2026-08-04T12:00:00Z", input: ["file_path": "/repo/BayGeometry.swift"]),
            Self.toolUse("Read", id: "b", at: "2026-08-07T12:00:00Z", input: ["file_path": "/repo/DepotCatalog.swift"]),
            Self.toolResult(id: "b", isError: true),
        ])

        let report = TranscriptAudit.render(projectsDirectory: root)

        #expect(report.contains(kept))
        #expect(!report.contains(retracted))
    }

    /// The cross-context list is the one meant to be acted on, so it says when the rediscovery last happened.
    @Test
    func repeatedColdFilesNameTheLastDaySeen() throws {
        let last = try Self.localDay("2026-08-07T12:00:00Z")
        let read = { (id: String, stamp: String) in
            Self.toolUse("Read", id: id, at: stamp, input: ["file_path": "/repo/FeedState.swift"])
        }
        let root = try Self.projects(
            session: [read("a", "2026-08-04T12:00:00Z")],
            subagents: [[read("b", "2026-08-07T12:00:00Z")]]
        )

        let report = TranscriptAudit.render(projectsDirectory: root)

        #expect(report.contains("FeedState.swift · last \(last)"))
    }

    /// A file read whole after its digest is dated too — a week-old one may predate a change that made the read unnecessary.
    @Test
    func filesReadWholeAfterTheirDigestAreDated() throws {
        let day = try Self.localDay("2026-08-05T12:01:00Z")
        let root = try Self.projects(session: [
            Self.toolUse("mcp__sift__digest", id: "a", at: "2026-08-05T12:00:00Z", input: ["target": "SummaryState"]),
            Self.digestAnswer(id: "a", text: "tree: App  head: 0000000  dirty: 0  parse_errors: 0\nSummaryState — App — SummaryState.swift:2-40"),
            Self.toolUse("Read", id: "b", at: "2026-08-05T12:01:00Z", input: ["file_path": "/repo/SummaryState.swift"]),
        ])

        let report = TranscriptAudit.render(projectsDirectory: root)

        #expect(report.contains("read whole after its digest — the files"))
        #expect(report.contains("SummaryState.swift · \(day)"))
    }

    /// A container read back after being shown as a count is dated too — the very row that says a digest withheld names may itself predate the change that put them there.
    @Test
    func collapsedContainerReadsAreDated() throws {
        let day = try Self.localDay("2026-08-05T12:02:00Z")
        let answer = """
        head: abc1234  dirty: 0  parse_errors: 0  semantic: syntactic-only
        Sources/Models/CrateData.swift — module: LibCore

        struct CrateData — 12 members  :9-200
            let width: Double?  :100
            enum Kind — 9 cases/members  :120-200
        """
        let root = try Self.projects(session: [
            Self.toolUse("mcp__sift__digest", id: "a", at: "2026-08-05T12:00:00Z", input: ["target": "Sources/Models/CrateData.swift"]),
            Self.digestAnswer(id: "a", text: answer),
            Self.toolUse("Read", id: "b", at: "2026-08-05T12:02:00Z", input: ["file_path": "/repo/Sources/Models/CrateData.swift", "offset": 120, "limit": 30]),
        ])

        let report = TranscriptAudit.render(projectsDirectory: root)

        #expect(report.contains("a container the digest showed as a count"))
        #expect(report.contains("1× enum Kind · \(day)"))
    }

    /// The day a finding names is the caller's local day, not UTC's — pinned on a timestamp half an hour before a UTC midnight, which lands on different days either side of it.
    @Test
    func theDayAFindingNamesResolvesInTheGivenZone() throws {
        let ahead = try #require(TimeZone(secondsFromGMT: 3600))
        let root = try Self.projects(session: [
            Self.toolUse("Read", id: "a", at: "2026-08-06T23:30:00Z", input: ["file_path": "/repo/BayGeometry.swift"]),
        ])

        let local = TranscriptAudit.render(projectsDirectory: root, timeZone: ahead)
        let utc = TranscriptAudit.render(projectsDirectory: root, timeZone: .gmt)

        #expect(local.contains("2026-08-07"))
        #expect(!local.contains("2026-08-06"))
        #expect(utc.contains("2026-08-06"))
    }

    /// A search carries no identity to strike by, so its retraction drops the newest recorded day — the documented bound, exact whenever a result lands beside its call.
    @Test
    func aRetractedSearchDropsTheNewestRecordedDay() throws {
        let root = try Self.projects(session: [
            Self.toolUse("Grep", id: "a", at: "2026-08-04T12:00:00Z", input: ["output_mode": "content", "pattern": "DepotStore", "type": "swift"]),
            Self.toolUse("Grep", id: "b", at: "2026-08-07T12:00:00Z", input: ["output_mode": "content", "pattern": "DepotCatalog", "type": "swift"]),
            Self.toolResult(id: "a", isError: true),
        ])

        let report = TranscriptAudit.render(projectsDirectory: root, timeZone: .gmt)

        #expect(report.contains("+ 1 Swift-flavoured search"))
        #expect(report.contains("2026-08-04"))
        #expect(!report.contains("2026-08-07"))
    }
}
