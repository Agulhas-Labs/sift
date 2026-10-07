//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftMCP
import Testing

/// Covers the floor note's second reason on its own: whether a `--since` window reaches back past the day the CLI began logging, compared as instants rather than as days.
///
/// A suite of its own so the day-versus-instant arithmetic is pinned without growing `UsageReportTests` past its own line budget.
@Suite(.temporaryDirectories)
struct UsageFloorOnsetTests {
    private static func writeLog(_ lines: [String]) throws -> URL {
        let file = try TemporaryDirectory.make("usage-onset").appendingPathComponent("usage.jsonl")
        try (lines.joined(separator: "\n") + "\n").write(to: file, atomically: true, encoding: .utf8)
        return file
    }

    private static func entry(tool: String, target: String? = nil, timestamp: String, via: String? = nil, bytes: (out: Int, source: Int)? = nil, served: Int? = nil) -> String {
        var object: [String: Any] = ["tool": tool, "root": "/repo/a", "ms": 10, "ok": true, "ts": timestamp]
        object["via"] = via
        if let target {
            object["target"] = target
        }
        if let bytes {
            object["outBytes"] = bytes.out
            object["srcBytes"] = bytes.source
        }
        if let served {
            object["outBytes"] = served
        }
        let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return String(data: data ?? Data(), encoding: .utf8) ?? ""
    }

    /// A window whose `--since` day starts before the CLI's own first logged call, hours before it, still reaches past the onset — the two instants are compared, not the two days.
    ///
    /// The CLI began logging at mid-afternoon on its onset day; a call earlier that same morning is outside the log for the same reason a call the day before would be, and comparing days alone reads the two as equal and drops the second floor reason. `--since` naming that whole day names its midnight, which is before the onset instant.
    @Test
    func theFloorNamesAGapWithinTheOnsetsOwnDay() throws {
        let file = try Self.writeLog([
            Self.entry(tool: "run", timestamp: "2026-09-10T14:00:00Z", via: "cli"),
            Self.entry(tool: "digest", target: "Measured", timestamp: "2026-09-10T09:00:00Z", bytes: (out: 100, source: 1000)),
            Self.entry(tool: "where", target: "Unpriced", timestamp: "2026-09-10T09:30:00Z", served: 4000),
        ])

        let savings = try #require(UsageScan.load(fileURL: file, since: "2026-09-10").get().savings)

        #expect(savings.floorNote?.hasSuffix("a lookup served before its face began logging is not in the log to weigh at all.") == true)
    }
}
