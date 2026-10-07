//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftMCP
import Testing

/// Covers what "since" means to the audit — which lookups it counts, and in whose day.
struct TranscriptWindowTests {
    private static func toolUse(_ name: String, at timestamp: String, input: [String: Any] = [:]) -> Data {
        let object: [String: Any] = [
            "type": "assistant",
            "timestamp": timestamp,
            "message": ["content": [["type": "tool_use", "id": "t", "name": name, "input": input]]],
        ]
        return (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
    }

    /// A successful answer to the call above it, at `timestamp`, whose header names the file its digest resolved to.
    private static func answer(at timestamp: String) -> Data {
        let object: [String: Any] = [
            "type": "user",
            "timestamp": timestamp,
            "message": ["content": [["type": "tool_result", "tool_use_id": "t", "content": [["type": "text", "text": "tree: App\nSummaryState — App — SummaryState.swift:2-40"]]]]],
        ]
        return (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
    }

    private static func lookups(_ lines: [Data], since: Date?, until: Date? = nil) -> [SwiftLookup] {
        var state = TranscriptScanState()
        return lines.flatMap { line in
            TranscriptScan.events(line: line, state: &state, since: since, until: until, belowFloor: { _ in false })
                .compactMap { event in
                    guard case let .lookup(lookup) = event else { return nil }
                    return lookup
                }
        }
    }

    private static func instant(_ text: String) -> Date {
        ISO8601DateFormatter().date(from: text) ?? .distantPast
    }

    /// Filtering whole transcripts by modification time would report a session that merely *continued* into today as today's work, carrying yesterday's misses with it — a sweep from the previous day at the top of a report headed "since today".
    @Test
    func onlyLookupsInsideTheWindowAreCounted() {
        let lookups = Self.lookups([
            Self.toolUse("Read", at: "2026-08-01T09:00:00Z", input: ["file_path": "/repo/Yesterday.swift"]),
            Self.toolUse("Read", at: "2026-08-02T09:00:00Z", input: ["file_path": "/repo/Today.swift"]),
        ], since: Self.instant("2026-08-02T00:00:00Z"))

        #expect(lookups == [.cold(file: "/repo/Today.swift", missed: nil)])
    }

    /// Excluded lines must still advance the state, or the window's first read of a file digested before it reads as cold.
    ///
    /// The digest is still in the same context window; only the *reporting* is scoped.
    @Test
    func aDigestBeforeTheWindowStillGuidesAReadInsideIt() {
        let lookups = Self.lookups([
            Self.toolUse("mcp__sift__digest", at: "2026-08-01T23:00:00Z", input: ["target": "SummaryState"]),
            Self.answer(at: "2026-08-01T23:00:01Z"),
            Self.toolUse("Read", at: "2026-08-02T09:00:00Z", input: ["file_path": "/repo/SummaryState.swift", "offset": 5]),
        ], since: Self.instant("2026-08-02T00:00:00Z"))

        #expect(lookups == [.guided(file: "/repo/SummaryState.swift")])
    }

    /// And a file first read before the window is a re-read inside it, not a fresh miss.
    @Test
    func aFileOpenedBeforeTheWindowIsRevisitedInsideIt() {
        let read = { (day: String) in
            Self.toolUse("Read", at: "2026-08-0\(day)T09:00:00Z", input: ["file_path": "/repo/A.swift"])
        }
        let lookups = Self.lookups([read("1"), read("2")], since: Self.instant("2026-08-02T00:00:00Z"))

        #expect(lookups == [.revisited(file: "/repo/A.swift")])
    }

    /// `--until` is exclusive: a lookup timestamped on the until-day itself falls outside the window.
    @Test
    func aLookupOnTheUntilDayIsExcluded() {
        let lookups = Self.lookups([
            Self.toolUse("Read", at: "2026-08-02T09:00:00Z", input: ["file_path": "/repo/Boundary.swift"]),
        ], since: nil, until: Self.instant("2026-08-02T00:00:00Z"))

        #expect(lookups.isEmpty)
    }

    /// A lookup timestamped exactly at `until` is the boundary itself — `<` and `<=` disagree only here, so `aLookupOnTheUntilDayIsExcluded` above (09:00 on the until day) cannot tell them apart.
    @Test
    func aLookupExactlyAtUntilIsExcluded() {
        let boundary = Self.instant("2026-08-02T00:00:00Z")
        let lookups = Self.lookups([
            Self.toolUse("Read", at: "2026-08-02T00:00:00Z", input: ["file_path": "/repo/Boundary.swift"]),
        ], since: nil, until: boundary)

        #expect(lookups.isEmpty)
    }

    /// And a lookup the day before `--until` is still inside the window — the end cuts on its own day, not the one before it.
    @Test
    func aLookupTheDayBeforeUntilIsIncluded() {
        let lookups = Self.lookups([
            Self.toolUse("Read", at: "2026-08-01T09:00:00Z", input: ["file_path": "/repo/Before.swift"]),
        ], since: nil, until: Self.instant("2026-08-02T00:00:00Z"))

        #expect(lookups == [.cold(file: "/repo/Before.swift", missed: nil)])
    }

    /// No window means no filtering at all.
    @Test
    func withoutAWindowEverythingIsCounted() {
        let lookups = Self.lookups([
            Self.toolUse("Read", at: "2026-07-01T09:00:00Z", input: ["file_path": "/repo/Old.swift"]),
        ], since: nil)

        #expect(lookups == [.cold(file: "/repo/Old.swift", missed: nil)])
    }

    /// A line carrying no timestamp cannot be shown to fall outside the window, so it is kept.
    @Test
    func anUndatedLineIsKeptRatherThanDropped() {
        let object: [String: Any] = [
            "type": "assistant",
            "message": ["content": [["type": "tool_use", "id": "t", "name": "Read", "input": ["file_path": "/repo/A.swift"]]]],
        ]
        let line = (try? JSONSerialization.data(withJSONObject: object)) ?? Data()

        #expect(Self.lookups([line], since: Self.instant("2026-08-02T00:00:00Z")) == [.cold(file: "/repo/A.swift", missed: nil)])
    }

    /// `usage` resolves in UTC because the log's day key is UTC.
    ///
    /// `audit` filters on instants and answers a person asking about *their* today, so it resolves locally — sharing one resolution would put the boundary at 01:00 local on UTC+1 and silently drop the first hour of every day.
    @Test
    func theAuditWindowStartsAtLocalMidnightNotUTC() throws {
        let zone = try #require(TimeZone(identifier: "Europe/London"))
        let now = Self.instant("2026-08-02T05:44:00Z")

        let start = try #require(UsageWindow.start(from: "today", now: now, timeZone: zone))

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let parts = calendar.dateComponents([.year, .month, .day, .hour], from: start)

        #expect(parts.day == 2)
        #expect(parts.hour == 0)
        // 00:00 BST is 23:00 UTC the previous day — the hour a UTC resolution would lose.
        #expect(start == Self.instant("2026-08-01T23:00:00Z"))
    }

    /// The log-facing resolution is untouched: its day key really is UTC.
    @Test
    func theUsageWindowStaysOnTheLogsOwnUTCDay() {
        #expect(UsageWindow.firstDay(from: "today", now: Self.instant("2026-08-02T00:30:00Z")) == "2026-08-02")
    }

    /// `--until YYYY-MM-DD` resolves the same way `--since` does — local midnight that day — so 23:59 local the day before is inside the window and 00:00 local that day is outside it.
    @Test
    func theUntilDayResolvesToLocalMidnightSoTheDayBeforeIsInAndItsOwnDayIsOut() throws {
        let zone = try #require(TimeZone(identifier: "Europe/London"))
        let now = Self.instant("2026-08-02T05:44:00Z")
        let until = try #require(UsageWindow.start(from: "2026-08-02", now: now, timeZone: zone))

        let lookups = Self.lookups([
            // 22:59 UTC on the 1st is 23:59 BST — the last minute the window still holds.
            Self.toolUse("Read", at: "2026-08-01T22:59:00Z", input: ["file_path": "/repo/Before.swift"]),
            // 23:00 UTC on the 1st is 00:00 BST on the 2nd — the excluded day itself.
            Self.toolUse("Read", at: "2026-08-01T23:00:00Z", input: ["file_path": "/repo/Boundary.swift"]),
        ], since: nil, until: until)

        #expect(lookups == [.cold(file: "/repo/Before.swift", missed: nil)])
    }
}
