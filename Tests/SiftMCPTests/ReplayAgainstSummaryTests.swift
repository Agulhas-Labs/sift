//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCLI
@testable import SiftMCP
import Testing

/// `audit --replay --against --summary`: the comparison alone, closed by a share verdict a gate can expect and the command for the audit body.
struct ReplayAgainstSummaryTests {
    /// With `--summary` the comparison ends on the verdict line, and without it the verdict is not printed.
    @Test func theSummaryEndsOnTheShareVerdict() {
        var context = ContextReplay()
        context.compare(
            ReplayVerdict(token: "allowed", rule: "noLookup"),
            with: ReplayVerdict(token: "in-place", rule: "ShellAdvice"),
            payload: ["tool_name": "Bash", "tool_input": ["command": "cat Sources/App/Alpha.swift"]]
        )

        let narrow = ReplayComparison.lines([context], summary: true)
        let full = ReplayComparison.lines([context])

        #expect(narrow.last?.hasPrefix("  share: ") == true, "\(narrow)")
        #expect(narrow.contains { $0.hasPrefix("  replayed share") }, "\(narrow)")
        #expect(!full.contains { $0.contains("share: ") }, "\(full)")
    }

    /// Equal fractions read `share: unchanged` even where the counts differ, and unequal ones read the signed move in points.
    @Test func theVerdictIsUnchangedOnlyForEqualFractions() {
        #expect(ReplayComparison.verdict(was: (1, 2), now: (2, 4)) == "  share: unchanged")
        #expect(ReplayComparison.verdict(was: (0, 0), now: (0, 5)) == "  share: unchanged")
        #expect(ReplayComparison.verdict(was: (8, 10), now: (4, 5)) == "  share: unchanged")
        #expect(ReplayComparison.verdict(was: (8, 10), now: (83, 100)) == "  share: moved +3.0")
        #expect(ReplayComparison.verdict(was: (5, 10), now: (38, 100)) == "  share: moved -12.0")
        #expect(ReplayComparison.verdict(was: (5815, 7259), now: (5816, 7259)) == "  share: moved +0.0")
    }

    /// The report is the window line, the comparison and the closing command echoing the window, with nothing of the audit body.
    @Test func theReportNamesTheWindowAndTheCommandForTheBody() {
        let text = AuditCommand.againstSummary(["  differ  1  of the 1 calls in the window"], window: "--since 7d")
        let lines = text.split(separator: "\n").map(String.init)

        #expect(lines.count == 3, "\(lines)")
        #expect(lines.first?.hasSuffix("window --since 7d") == true, "\(lines)")
        #expect(lines.last == "  the audit body: sift audit --replay --since 7d --summary", "\(lines)")
        #expect(AuditCommand.windowArguments(sinceValue: "2d", until: "today", all: false, transcript: nil) == "--since 2d --until today")
    }
}
