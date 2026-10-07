//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// Covers what a `sift run` answer leaves out because another line of the same answer already says it.
///
/// Each case pins one repetition: the measurement line over a lone failure, a `↳` note restating the expectation above it, the `in …` line naming the failing test a second time, the tool's own tallies under a plain totals line, and the blank line and `sift run:` prefix around the receipt. Each also pins the case where the repetition is not one, and the line stays.
@Suite(.temporaryDirectories)
struct RunOutputTrimTests {
    @Test
    func aLoneFailureListsWithNoMeasurementLineAboveIt() {
        let answer = Self.answer(Self.failing(["aFailingTest()"]), exitCode: 1)

        #expect(!answer.contains { $0.contains("1 failure ·") })
        #expect(answer[1] == "  aFailingTest() — DepotStoreTests.swift:12:9")
    }

    @Test
    func severalFailuresKeepTheMeasurementLineThatGroupsThem() {
        let answer = Self.answer(Self.failing(["aFailingTest()", "aTest()"]), exitCode: 1)

        #expect(answer.contains { $0.hasPrefix("2 failures · ") })
    }

    @Test
    func aNoteRestatingTheExpectationFoldsIntoTheMessageWithNoAdjacencyMarker() {
        let answer = Self.answer(Self.failing(["aFailingTest()"]), exitCode: 1)

        #expect(answer[2] == "    Expectation failed: depot.count == 2 → false depot.count → 1")
        #expect(!answer.contains { $0.contains("↳") || $0.contains("(by adjacency)") })
    }

    @Test
    func aNoteThatRestatesNothingKeepsItsOwnLineAndItsMarker() {
        let log = [
            "✘ Test aFailingTest() recorded an issue at DepotStoreTests.swift:12:9: Expectation failed: depot.count == 0",
            "↳ the depot was restocked before the check",
            "✘ Test aFailingTest() failed after 0.010 seconds with 1 issue.",
            "✘ Test run with 1 test in 1 suite failed after 0.010 seconds with 1 issue.",
        ]
        let answer = Self.answer(log, exitCode: 1)

        #expect(answer.contains("    ↳ the depot was restocked before the check (by adjacency)"))
    }

    @Test
    func aFailureInsideItsOwnTestNamesTheBodyOnItsHeadingInsteadOfALineBeneath() async throws {
        let root = try TestSources.makeTempRepo()
        try TestSources.write(Self.gridSource, to: Self.gridPath, in: root)
        try TestSources.commitAll(in: root, message: "sources")
        try await SiftEngine(directory: root).ensureFresh()
        let location = "ChartGridTests.swift:10:9"
        let sites = RunFailureSites.resolving([location], inRepositoryAt: root)
        let log = [
            "✘ Test theGridReflowsAtAccessibilitySizes() recorded an issue at \(location): Expectation failed: grid.columns == 2",
            "✘ Test run with 1 test in 1 suite failed after 0.010 seconds with 1 issue.",
        ]
        let answer = Self.answer(log, exitCode: 1, sites: sites, in: root)

        #expect(answer[1] == "  theGridReflowsAtAccessibilitySizes() — \(Self.gridPath):10 (body :8-12)")
        #expect(!answer.contains { $0.contains("(syntactic)") })
    }

    @Test
    func aPlainPassIsItsHeadlineItsTotalsAndItsReceipt() {
        let log = [
            "Build complete! (0.49s)",
            "✔ Test run with 29 tests in 4 suites passed after 0.047 seconds.",
        ]
        let logURL = URL(fileURLWithPath: "/Users/dev/Widget/.sift/runs/run-a.log")
        let answer = Self.answer(log, exitCode: 0, logURL: logURL)

        #expect(answer == [
            "✔ swift test",
            "totals: ✔ passed · Swift Testing 29 tests in 4 suites",
            "raw: .sift/runs/run-a.log (2 lines in, 3 out)",
        ])
    }

    @Test
    func aTotalsLineWithAnAnomalyKeepsTheToolsOwnLinesAsItsEvidence() {
        let log = ["✔ Test run with 29 tests in 4 suites passed after 0.047 seconds."]
        let answer = Self.answer(log, exitCode: 1)

        #expect(answer.contains("  Test run with 29 tests in 4 suites passed after 0.047 seconds."))
        #expect(answer.contains { $0.hasPrefix("totals: ⚠ exit code disagrees") })
    }

    /// A lone failure the log is too short to list is sampled, and the sample leads with no measurement line either: the form is the log's call, and the lone entry reads the same in both.
    @Test
    func aLoneFailureSampledRatherThanListedHasNoMeasurementLineEither() {
        let failure = RunFailureShape.Failure(name: "aFailingTest()", location: "DepotStoreTests.swift:12:9", message: "Expectation failed: depot.count == 2")
        var budget = RunFailureCensus.listingBudget
        let sampled = RunFailureShape.of([failure], changedFiles: .of([])).rendered(within: 0, spending: &budget)

        #expect(sampled == ["  aFailingTest() — DepotStoreTests.swift:12:9", "    Expectation failed: depot.count == 2"])
    }

    /// Swift Testing prints the user's comment before the expression's evaluation, so a comment whose text before its arrow is the expression's last word is not the expression restated: it keeps its own line and its tag, and the message is not given the comment as its value.
    @Test
    func aCommentEndingOnTheExpressionsLastWordIsNotFoldedInAsItsValue() {
        let log = [
            "✘ Test aFailingTest() recorded an issue at DepotStoreTests.swift:12:9: Expectation failed: depot.count == expected",
            "↳ expected → really",
            "↳ depot.count == expected → false",
            "✘ Test aFailingTest() failed after 0.010 seconds with 1 issue.",
            "✘ Test run with 1 test in 1 suite failed after 0.010 seconds with 1 issue.",
        ]
        let answer = Self.answer(log, exitCode: 1)

        #expect(answer.contains("    Expectation failed: depot.count == expected"))
        #expect(answer.contains { $0.hasPrefix("    ↳ expected → really") && $0.hasSuffix("(by adjacency)") })
    }

    /// A lone XCTest counter that will not parse states no `not summed`, and its line is the only one in the answer that says a test failed: it stays, beside every other tool line, under a totals line that reads as a pass.
    @Test
    func aLoneUnreadableCounterKeepsTheToolsOwnLines() {
        let log = [
            "Executed 3 tests, with 1 failure in 0.073 (0.074) seconds",
            "✔ Test run with 29 tests in 4 suites passed after 0.047 seconds.",
        ]
        let answer = Self.answer(log, exitCode: 0)

        #expect(answer.contains { $0.hasPrefix("totals: ✔ passed · XCTest counter 1 unreadable") })
        #expect(answer.contains("  Executed 3 tests, with 1 failure in 0.073 (0.074) seconds"))
        #expect(answer.contains("  Test run with 29 tests in 4 suites passed after 0.047 seconds."))
    }

    /// Several counters with one unreadable are stated `not summed`, and keep the tool's own lines just as a lone unreadable one does.
    @Test
    func severalCountersWithOneUnreadableKeepTheToolsOwnLines() {
        let log = [
            "Test Suite 'All tests' started at 2000-01-01 12:00:00.100.",
            "Executed 3 tests, with 0 failures (0 unexpected) in 0.073 (0.074) seconds",
            "Test Suite 'All tests' started at 2000-01-01 12:00:01.200.",
            "Executed 3 tests, with 1 failure in 0.073 (0.074) seconds",
            "✔ Test run with 29 tests in 4 suites passed after 0.047 seconds.",
        ]
        let answer = Self.answer(log, exitCode: 0)

        #expect(answer.contains { $0.hasPrefix("totals: ✔ passed · XCTest 2 counters, not summed") })
        #expect(answer.contains("  Executed 3 tests, with 1 failure in 0.073 (0.074) seconds"))
        #expect(answer.contains("  Test run with 29 tests in 4 suites passed after 0.047 seconds."))
    }

    static var gridPath: String {
        "Tests/LibTests/ChartGridTests.swift"
    }

    /// A test file whose `theGridReflowsAtAccessibilitySizes()` spans lines 8-12, with the failing line 10 inside it.
    static var gridSource: String {
        """
        //
        // Copyright © Agulhas Labs
        //

        import Testing

        struct ChartGridTests {
            @Test
            func theGridReflowsAtAccessibilitySizes() {
                let columns = 1
                _ = columns
            }
        }

        """
    }

    /// One Swift Testing failure whose `↳` note restates its expectation, per name in `names`, and the run's closing tally.
    static func failing(_ names: [String]) -> [String] {
        names.flatMap { name in
            [
                "✘ Test \(name) recorded an issue at DepotStoreTests.swift:12:9: Expectation failed: depot.count == 2",
                "↳ depot.count == 2 → false depot.count → 1",
                "✘ Test \(name) failed after 0.010 seconds with 1 issue.",
            ]
        } + ["✘ Test run with \(names.count) test\(names.count == 1 ? "" : "s") in 1 suite failed after 0.010 seconds with \(names.count) issue\(names.count == 1 ? "" : "s")."]
    }

    /// The answer a plain `swift test` over `log` renders, line by line.
    static func answer(_ log: [String], exitCode: Int32, sites: RunFailureSites = .none, logURL: URL? = nil, in directory: URL = URL(fileURLWithPath: "/Users/dev/Widget")) -> [String] {
        var filter = RunOutputFilter(invokedAs: ["swift", "test"])
        for line in log {
            filter.consume(line: line)
        }
        let report = filter.finish(exitCode: exitCode)
        return RunReportRenderer(kind: .swiftTest, workingDirectory: directory, changedFiles: .of([]), sites: sites)
            .render(report, exitCode: exitCode, logURL: logURL)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
    }
}
