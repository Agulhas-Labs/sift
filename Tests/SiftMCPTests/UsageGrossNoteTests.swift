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
    /// A log of one intercepted read still says its figure is gross.
    @Test
    func aDigestOnlySavingIsLabelledGross() throws {
        let log = try TemporaryDirectory.make("usage-gross").appendingPathComponent("usage.jsonl")
        UsageLog(fileURL: log).record(
            tool: "digest", target: "Sources/App/Depot.swift", root: "/repo", milliseconds: 80, succeeded: true,
            answer: AnswerBytes(served: 3000, source: 23000), session: "s1", via: "hook", intercepted: "window"
        )

        let report = UsageReport.render(fileURL: log)

        #expect(report.contains("        the figure above is gross: an answer whose file was then read whole anyway is taken back only by a re-run or whole read "
                + "the hook let through; sift audit counts those reads"))
    }
}
