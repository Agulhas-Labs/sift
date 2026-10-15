//
// Copyright © Agulhas Labs
//

import ArgumentParser
import Foundation
@testable import SiftCLI
@testable import SiftMCP
import Testing

/// Covers `sift audit --by`: the summary as one line per day or week, drawn from the one scan of the transcripts.
@Suite(.temporaryDirectories)
struct AuditTrendTests {
    /// One dated call as the harness writes it: an index digest, or a whole read of a file of its own.
    private static func call(_ name: String, id: String, at stamp: String) -> String {
        let input: [String: Any] = name == "Read" ? ["file_path": "/repo/File\(id).swift"] : ["target": "Alpha"]
        let object: [String: Any] = [
            "type": "assistant",
            "timestamp": stamp,
            "message": ["content": [["type": "tool_use", "id": id, "name": name, "input": input]]],
        ]
        let data = (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
        return String(bytes: data, encoding: .utf8) ?? ""
    }

    /// A projects tree whose one session made, in UTC: one index call and one cold read on the 6th of October 2026, three and one on the 7th, and one and nine on the 13th.
    private static func projects() throws -> URL {
        let root = try TemporaryDirectory.make("audit-trend").appendingPathComponent("audit")
        let directory = root.appendingPathComponent("-Users-someone-Developer-App")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var lines = [
            call("mcp__sift__digest", id: "a1", at: "2026-10-06T10:00:00Z"),
            call("Read", id: "a2", at: "2026-10-06T11:00:00Z"),
        ]
        for index in 1 ... 3 {
            lines.append(call("mcp__sift__digest", id: "b\(index)", at: "2026-10-07T10:0\(index):00Z"))
        }
        lines.append(call("Read", id: "b4", at: "2026-10-07T12:00:00Z"))
        lines.append(call("mcp__sift__digest", id: "c0", at: "2026-10-13T09:00:00Z"))
        for index in 1 ... 9 {
            lines.append(call("Read", id: "c\(index)", at: "2026-10-13T10:0\(index):00Z"))
        }
        let transcript = directory.appendingPathComponent("11112222-3333.jsonl")
        try (lines.joined(separator: "\n") + "\n").write(to: transcript, atomically: true, encoding: .utf8)
        return root
    }

    /// A tool result as the harness writes it, dated; `isError` marks the failure flag.
    private static func result(id: String, at stamp: String, isError: Bool) -> String {
        var block: [String: Any] = ["type": "tool_result", "tool_use_id": id, "content": [["type": "text", "text": "boom"]]]
        if isError {
            block["is_error"] = true
        }
        let object: [String: Any] = ["type": "user", "timestamp": stamp, "message": ["content": [block]]]
        let data = (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
        return String(bytes: data, encoding: .utf8) ?? ""
    }

    /// A call with no timestamp at all.
    private static func undatedCall(id: String) -> String {
        let object: [String: Any] = [
            "type": "assistant",
            "message": ["content": [["type": "tool_use", "id": id, "name": "Read", "input": ["file_path": "/repo/File\(id).swift"]]]],
        ]
        let data = (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
        return String(bytes: data, encoding: .utf8) ?? ""
    }

    /// A projects tree whose one session holds `lines`.
    private static func projects(holding lines: [String]) throws -> URL {
        let root = try TemporaryDirectory.make("audit-trend").appendingPathComponent("audit")
        let directory = root.appendingPathComponent("-Users-someone-Developer-App")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let transcript = directory.appendingPathComponent("11112222-3333.jsonl")
        try (lines.joined(separator: "\n") + "\n").write(to: transcript, atomically: true, encoding: .utf8)
        return root
    }

    /// The `cold` count a summary's own row prints.
    private static func coldCount(in report: String, sourceLocation: SourceLocation = #_sourceLocation) throws -> Int {
        let row = try #require(report.components(separatedBy: "\n").first { $0.hasPrefix("  cold  ") }, sourceLocation: sourceLocation)
        return try #require(row.split(separator: " ").dropFirst().first.flatMap { Int($0) }, sourceLocation: sourceLocation)
    }

    private static func date(_ stamp: String, sourceLocation: SourceLocation = #_sourceLocation) throws -> Date {
        try #require(ISO8601DateFormatter().date(from: stamp), sourceLocation: sourceLocation)
    }

    /// Weeks start on a Monday and the first is clipped to the window's start, which names it; a week with no lookups reads `choice 0`; the numbers line up.
    @Test
    func aWeeklyTrendHasOneAlignedLinePerWeekClippedToTheWindow() throws {
        let report = try TranscriptAudit.render(
            projectsDirectory: Self.projects(),
            since: Self.date("2026-10-06T00:00:00Z"),
            until: Self.date("2026-10-26T00:00:00Z"),
            timeZone: .gmt,
            summary: true,
            trend: .week
        )
        let lines = report.components(separatedBy: "\n")

        #expect(lines.count == 7, "\(report)")
        #expect(lines[0].hasPrefix("audit — 1 session"), "\(report)")
        #expect(lines[0].contains("16 Swift lookups by any route, 5 served by sift"), "\(report)")
        #expect(lines[1].hasPrefix("live: "), "\(report)")
        #expect(lines[2] == "2026-10-06  choice  6  indexed 67%  voluntary 67%  cold 2  answered 0", "\(report)")
        #expect(lines[3] == "2026-10-12  choice 10  indexed 10%  voluntary 10%  cold 9  answered 0", "\(report)")
        #expect(lines[4] == "2026-10-19  choice 0", "\(report)")
    }

    /// A day is a window of its own, an empty day in the span included.
    @Test
    func aDailyTrendHasOneLinePerDayIncludingTheEmptyOnes() throws {
        let report = try TranscriptAudit.render(
            projectsDirectory: Self.projects(),
            since: Self.date("2026-10-06T00:00:00Z"),
            until: Self.date("2026-10-09T00:00:00Z"),
            timeZone: .gmt,
            summary: true,
            trend: .day
        )
        let lines = report.components(separatedBy: "\n")

        #expect(Array(lines.dropFirst(2).dropLast(2)) == [
            "2026-10-06  choice 2  indexed 50%  voluntary 50%  cold 1  answered 0",
            "2026-10-07  choice 4  indexed 75%  voluntary 75%  cold 1  answered 0",
            "2026-10-08  choice 0",
        ], "\(report)")
    }

    /// With no window start the span begins on the first day a lookup landed on and ends on the last.
    @Test
    func aTrendWithoutAWindowSpansTheDaysThatHaveLookups() throws {
        let report = try TranscriptAudit.render(
            projectsDirectory: Self.projects(),
            timeZone: .gmt,
            summary: true,
            trend: .week
        )
        let lines = report.components(separatedBy: "\n")

        #expect(Array(lines.dropFirst(2).dropLast(2)) == [
            "2026-10-06  choice  6  indexed 67%  voluntary 67%  cold 2  answered 0",
            "2026-10-12  choice 10  indexed 10%  voluntary 10%  cold 9  answered 0",
        ], "\(report)")
    }

    /// The trend is a form of the summary, so it has no form for one transcript, a replay, the share lines or a name to unredact.
    @Test(arguments: [
        ["--by", "week", "--transcript", "x.jsonl"],
        ["--by", "week", "--replay"],
        ["--by", "week", "--share"],
        ["--by", "week", "--unredact"],
        ["--by", "day", "--scan-diff"],
        ["--by", "day", "--against", "other"],
        ["--by", "day", "--shapes", "shapes.json"],
        ["--by", "day", "--sample", "3"],
        ["--by", "month"],
    ])
    func theTrendIsRefusedWithFlagsItMakesMeaningless(arguments: [String]) {
        #expect(throws: (any Error).self) {
            try AuditCommand.parse(arguments)
        }
    }

    /// Either window length, alone or with a window, parses.
    @Test(arguments: ["day", "week"])
    func eitherWindowLengthParses(length: String) throws {
        let command = try AuditCommand.parse(["--by", length, "--since", "2026-10-06"])

        #expect(command.trendLength == length)
    }

    /// A call that errors after midnight is taken back on the day it was counted, so the rows sum to the span.
    @Test
    func aFailedCallStraddlingMidnightIsTakenBackOnTheDayOfTheCall() throws {
        let london = try #require(TimeZone(identifier: "Europe/London"))
        let projects = try Self.projects(holding: [
            Self.call("mcp__sift__digest", id: "a1", at: "2026-10-06T22:59:59Z"),
            Self.result(id: "a1", at: "2026-10-06T23:00:01Z", isError: true),
            Self.call("Read", id: "a2", at: "2026-10-07T10:00:00Z"),
        ])
        let summary = TranscriptAudit.render(projectsDirectory: projects, timeZone: london, summary: true)
        let report = TranscriptAudit.render(projectsDirectory: projects, timeZone: london, summary: true, trend: .day)
        let lines = report.components(separatedBy: "\n")

        #expect(summary.contains("1 Swift lookup by any route, 0 served by sift"), "\(summary)")
        #expect(Array(lines.dropFirst(2).prefix(2)) == [
            "2026-10-06  choice 0",
            "2026-10-07  choice 1  indexed 0%  voluntary 0%  cold 1  answered 0",
        ], "\(report)")

        // Windowed so that the result falls past the end: the correction still lands inside the span.
        let windowed = try TranscriptAudit.render(
            projectsDirectory: projects,
            since: Self.date("2026-10-05T23:00:00Z"),
            until: Self.date("2026-10-06T23:00:00Z"),
            timeZone: london,
            summary: true,
            trend: .day
        )
        #expect(windowed.contains("0 served by sift"), "\(windowed)")
        #expect(windowed.contains("2026-10-06  choice 0\n"), "\(windowed)")
    }

    /// A cold lookup the hook log rescores after midnight is retracted and rescored on the day of the call.
    @Test
    func aRescoreStraddlingMidnightStaysOnTheDayOfTheCall() throws {
        let london = try #require(TimeZone(identifier: "Europe/London"))
        let projects = try Self.projects(holding: [
            Self.call("mcp__sift__digest", id: "d1", at: "2026-10-06T10:00:00Z"),
            Self.result(id: "d1", at: "2026-10-06T10:00:01Z", isError: false),
            Self.call("Read", id: "r1", at: "2026-10-06T22:59:59Z"),
            Self.result(id: "r1", at: "2026-10-06T23:00:01Z", isError: false),
        ])
        let log = projects.appendingPathComponent("suppressions.jsonl")
        SuppressionLog(fileURL: log).note(symbol: "notSmaller", directory: "/repo", rule: "answerWithheld", call: "r1", fields: [:])
        let summary = TranscriptAudit.render(projectsDirectory: projects, timeZone: london, suppressionLog: log, summary: true)
        let report = TranscriptAudit.render(projectsDirectory: projects, timeZone: london, suppressionLog: log, summary: true, trend: .day)
        let lines = report.components(separatedBy: "\n")

        #expect(try Self.coldCount(in: summary) == 0, "\(summary)")
        #expect(Array(lines.dropFirst(2).dropLast(2)) == [
            "2026-10-06  choice 1  indexed 100%  voluntary 100%  cold 0  answered 0",
        ], "\(report)")
    }

    /// Lookups whose lines carry no time are named on a last row, and the row is absent when every lookup is dated.
    @Test
    func undatedLookupsAreCountedOnALastLine() throws {
        let undated = try TranscriptAudit.render(
            projectsDirectory: Self.projects(holding: [
                Self.call("Read", id: "d1", at: "2026-10-06T10:00:00Z"),
                Self.undatedCall(id: "u1"),
                Self.undatedCall(id: "u2"),
            ]),
            timeZone: .gmt,
            summary: true,
            trend: .day
        )
        let dated = try TranscriptAudit.render(projectsDirectory: Self.projects(), timeZone: .gmt, summary: true, trend: .week)

        #expect(undated.contains("3 Swift lookups by any route"), "\(undated)")
        #expect(undated.components(separatedBy: "\n").dropLast(2).last == "2 lookups carry no time, counted in the first line but in no window", "\(undated)")
        #expect(!dated.contains("carry no time"), "\(dated)")
    }

    /// A repeat of a tool call id on an undated line is a lookup of its own: it neither dates the earlier call's correction nor leaves a false undated count behind.
    @Test
    func aRepeatedIdOnAnUndatedLineDoesNotDateAnotherCallsCorrection() throws {
        let projects = try Self.projects(holding: [
            Self.call("Read", id: "r1", at: "2026-10-09T10:00:00Z"),
            Self.undatedCall(id: "r1"),
            Self.result(id: "r1", at: "2026-10-10T10:00:00Z", isError: true),
            Self.call("Read", id: "r2", at: "2026-10-10T11:00:00Z"),
        ])
        let report = try TranscriptAudit.render(
            projectsDirectory: projects,
            since: Self.date("2026-10-10T00:00:00Z"),
            until: Self.date("2026-10-12T00:00:00Z"),
            timeZone: .gmt,
            summary: true,
            trend: .day
        )
        let lines = report.components(separatedBy: "\n")

        #expect(report.contains("1 Swift lookup by any route, 0 served by sift"), "\(report)")
        #expect(Array(lines.dropFirst(2).prefix(2)) == [
            "2026-10-10  choice 1  indexed 0%  voluntary 0%  cold 1  answered 0",
            "2026-10-11  choice 0",
        ], "\(report)")
        #expect(!report.contains("carry no time"), "\(report)")
    }

    /// An undated call that errors is taken back from the undated count as a dated one is from its day, so the note goes.
    @Test
    func anUndatedCallThatErrorsLeavesNoUndatedCount() throws {
        let projects = try Self.projects(holding: [
            Self.call("Read", id: "d1", at: "2026-10-06T10:00:00Z"),
            Self.undatedCall(id: "u1"),
            Self.result(id: "u1", at: "2026-10-06T10:00:05Z", isError: true),
        ])
        let report = TranscriptAudit.render(projectsDirectory: projects, timeZone: .gmt, summary: true, trend: .day)

        #expect(report.contains("1 Swift lookup by any route"), "\(report)")
        #expect(!report.contains("carry no time"), "\(report)")
    }

    /// The summary's closing note survives the trend, after the rows.
    @Test
    func theTrendKeepsTheClosingNote() throws {
        let report = try TranscriptAudit.render(projectsDirectory: Self.projects(), timeZone: .gmt, summary: true, trend: .week)

        #expect(report.hasSuffix("cold 9  answered 0\n\nlists: sift audit without --summary"), "\(report)")
    }
}
