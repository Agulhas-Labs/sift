//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftMCP
import Testing

/// `usage`'s latency figures are the server's: a call another face answered is counted, and its time kept apart.
@Suite(.temporaryDirectories)
struct UsageLatencyTests {
    /// An answer the advice hook gave in place is counted with its tool but left out of the percentiles, and the report says so: it was timed from a fresh process that opened the index, which the server's calls never pay.
    @Test
    func answersInPlaceAreLeftOutOfTheLatency() throws {
        let directory = try TemporaryDirectory.make("latency").appendingPathComponent("latency")
        defer { try? FileManager.default.removeItem(at: directory) }
        let log = directory.appendingPathComponent("usage.jsonl")
        let usage = UsageLog(fileURL: log)
        for milliseconds in [5, 6, 7] {
            usage.record(tool: "digest", target: "Depot", root: "/repo", milliseconds: milliseconds, succeeded: true, session: nil)
        }
        usage.record(
            tool: "digest", target: "Sources/App/Depot.swift", root: "/repo", milliseconds: 900, succeeded: true,
            answer: AnswerBytes(served: 1, source: 2), session: "s1", via: "hook"
        )

        let report = UsageReport.render(fileURL: log, runFileURL: directory.appendingPathComponent("runs.jsonl"))
        let digest = report.split(separator: "\n").first { $0.hasPrefix("  digest") }.map(String.init)

        #expect(digest == "  digest       4   p50 6ms   p90 7ms")
        #expect(report.contains("  answered elsewhere: 1 in place by the advice hook — counted above, left out of p50/p90"))
    }
}
