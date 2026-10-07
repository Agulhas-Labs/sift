//
// Copyright © Agulhas Labs
//

import Foundation
import SiftCore
@testable import SiftMCP
import Testing

/// `usage` reads the log alone, which never records a whole read after a digest, so its saving is gross and the summary says so and where those reads are counted.
@Suite(.temporaryDirectories)
struct UsageGrossNoteTests {
    /// A log of MCP digests and no in-place answer still says its figure is gross.
    @Test
    func aDigestOnlySavingIsLabelledGross() throws {
        let log = try TemporaryDirectory.make("usage-gross").appendingPathComponent("usage.jsonl")
        UsageLog(fileURL: log).record(
            tool: "digest", target: "Sources/App/Depot.swift", root: "/repo", milliseconds: 80, succeeded: true,
            answer: AnswerBytes(served: 3000, source: 23000), session: "s1"
        )

        let report = UsageReport.render(fileURL: log)

        #expect(report.contains("        the figure above is gross: a digest or answer whose file was then read whole anyway still counts, "
                + "which this log cannot see; sift audit counts those reads"))
    }
}
