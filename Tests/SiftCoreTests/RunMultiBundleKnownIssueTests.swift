//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// Covers `RunReportRenderer`'s known-issue arithmetic for a multi-bundle package, where `report.tally` stays `nil` and no bundle's summary line may be read as a package total.
struct RunMultiBundleKnownIssueTests {
    private static var workingDirectory: URL {
        URL(fileURLWithPath: "/Users/dev/Depot")
    }

    /// A multi-bundle run leaves `report.tally` `nil` — no single tally speaks for the package, and none is invented — but the failing bundle's own known-issue count still prints, labelled by its own tally so it cannot be misread as the package's.
    @Test
    func aFailingBundlesKnownIssueArithmeticIsLabelledByItsOwnBundle() {
        var filter = RunOutputFilter(expecting: .runTally)
        for line in [
            "✔ Test run with 4 tests in 2 suites passed after 0.010 seconds.",
            "✘ Test run with 6 tests in 3 suites failed after 0.020 seconds with 3 issues (including 1 known issue).",
        ] {
            filter.consume(line: line)
        }
        let report = filter.finish()

        // No single tally stands for the two-bundle package, so none is invented.
        #expect(report.tally == nil)
        #expect(report.verdict?.state == .failed)

        let answer = RunReportRenderer(kind: .swiftTest, workingDirectory: Self.workingDirectory)
            .render(report, exitCode: 1, logURL: nil)
        #expect(answer.contains("\n  Swift Testing (bundle 2 of 2, 6 tests in 3 suites): 2 failures, 1 known issue\n"))
    }

    /// The commonest shape of the bug this guards: every bundle in a multi-bundle package passes, and one of them still recorded a known issue — `report.verdict?.line` is `nil` for an all-pass package, since no bundle failed for `multiBundleTallyVerdict()` to quote, so the arithmetic has to be read from `report.summaryLines` instead.
    @Test
    func anAllPassPackageStillPrintsAKnownIssueFromTheBundleThatCarriesIt() {
        var filter = RunOutputFilter(expecting: .runTally)
        for line in [
            "✔ Test run with 4 tests in 2 suites passed after 0.010 seconds.",
            "✔ Test run with 6 tests in 3 suites passed after 0.020 seconds with 1 known issue.",
        ] {
            filter.consume(line: line)
        }
        let report = filter.finish()

        #expect(report.tally == nil)
        #expect(report.verdict?.state == .succeeded)
        #expect(report.verdict?.line == nil)

        let answer = RunReportRenderer(kind: .swiftTest, workingDirectory: Self.workingDirectory)
            .render(report, exitCode: 0, logURL: nil)
        #expect(answer.hasPrefix("✔ swift test\n"))
        #expect(answer.contains("\n  Swift Testing (bundle 2 of 2, 6 tests in 3 suites): 0 failures, 1 known issue\n"))
    }

    /// A known issue in the bundle the verdict does *not* quote prints regardless of which bundle the log names first — the arithmetic is read from every bundle's own summary line, not only the one `multiBundleTallyVerdict()` picked to speak for the failure.
    ///
    /// The passing bundle's position among the two tally lines follows the order they printed in, so it flips between the two runs even though its own counts do not.
    @Test
    func aKnownIssueInTheBundleTheVerdictDoesNotQuotePrintsInEitherOrder() {
        let failingNoKnownIssue = "✘ Test run with 6 tests in 3 suites failed after 0.020 seconds with 2 issues."
        let passingWithKnownIssue = "✔ Test run with 4 tests in 2 suites passed after 0.010 seconds with 1 known issue."
        for (lines, passingBundlePosition) in [
            ([failingNoKnownIssue, passingWithKnownIssue], "bundle 2 of 2"),
            ([passingWithKnownIssue, failingNoKnownIssue], "bundle 1 of 2"),
        ] {
            var filter = RunOutputFilter(expecting: .runTally)
            for line in lines {
                filter.consume(line: line)
            }
            let report = filter.finish()

            #expect(report.tally == nil, "\(lines)")
            #expect(report.verdict?.state == .failed, "\(lines)")

            let answer = RunReportRenderer(kind: .swiftTest, workingDirectory: Self.workingDirectory)
                .render(report, exitCode: 1, logURL: nil)
            // The failing bundle carries no known issue, so it contributes no line — and the passing
            // bundle's line prints either way, labelled by its own tally rather than the failing one's.
            #expect(!answer.contains("Swift Testing: 0 failures"), "\(lines)")
            #expect(answer.contains("\n  Swift Testing (\(passingBundlePosition), 4 tests in 2 suites): 0 failures, 1 known issue\n"), "\(lines)")
        }
    }

    /// Two bundles each carrying a known issue print two labelled lines, never one that sums them — a package-level count would be a number no tool printed.
    @Test
    func twoBundlesEachWithKnownIssuesPrintTwoLinesNeverASum() {
        var filter = RunOutputFilter(expecting: .runTally)
        for line in [
            "✘ Test run with 6 tests in 3 suites failed after 0.020 seconds with 3 issues (including 1 known issue).",
            "✔ Test run with 4 tests in 2 suites passed after 0.010 seconds with 2 known issues.",
        ] {
            filter.consume(line: line)
        }
        let report = filter.finish()

        #expect(report.tally == nil)
        #expect(report.verdict?.state == .failed)

        let answer = RunReportRenderer(kind: .swiftTest, workingDirectory: Self.workingDirectory)
            .render(report, exitCode: 1, logURL: nil)
        #expect(answer.contains("\n  Swift Testing (bundle 1 of 2, 6 tests in 3 suites): 2 failures, 1 known issue\n"))
        #expect(answer.contains("\n  Swift Testing (bundle 2 of 2, 4 tests in 2 suites): 0 failures, 2 known issues\n"))
        // Nothing sums the two: no line reads 2 failures, 3 known issues or any other combination.
        #expect(!answer.contains("3 known issues"))
        #expect(!answer.contains("2 failures, 3"))
    }

    /// Two bundles that agree on both counts print two identical-looking lines, with nothing to tell a reader they are not one line printed twice, unless the label also carries the tally's position.
    ///
    /// This is the shape the repo's own `xcodebuild-test-two-bundles` capture is.
    @Test
    func twoBundlesWithIdenticalCountsAreToldApartByTallyPosition() {
        var filter = RunOutputFilter(expecting: .runTally)
        for line in [
            "✘ Test run with 3 tests in 1 suite failed after 0.001 seconds with 2 issues (including 1 known issue).",
            "✘ Test run with 3 tests in 1 suite failed after 0.001 seconds with 2 issues (including 1 known issue).",
        ] {
            filter.consume(line: line)
        }
        let report = filter.finish()

        #expect(report.tally == nil)
        #expect(report.verdict?.state == .failed)

        let answer = RunReportRenderer(kind: .swiftTest, workingDirectory: Self.workingDirectory)
            .render(report, exitCode: 1, logURL: nil)
        #expect(answer.contains("\n  Swift Testing (bundle 1 of 2, 3 tests in 1 suite): 1 failure, 1 known issue\n"))
        #expect(answer.contains("\n  Swift Testing (bundle 2 of 2, 3 tests in 1 suite): 1 failure, 1 known issue\n"))
    }

    /// A multi-bundle `swift test` whose XCTest half failed still prints a Swift Testing bundle's known-issue arithmetic.
    ///
    /// The verdict is read off XCTest's own counters (``RunOutputFilter/xctestFailed``), which says nothing about whether a *different* bundle's Swift Testing half carried a known issue, so the two counters disagreeing about which line the verdict quotes must not swallow the labelled lines below it.
    @Test
    func aFailingXCTestHalfStillPrintsTheSwiftTestingHalfsKnownIssueArithmetic() {
        var filter = RunOutputFilter(expecting: .runTally)
        for line in [
            "Test Suite 'All tests' started at 2000-01-01 12:00:09.390.",
            "Executed 12 tests, with 3 failures (0 unexpected) in 0.315 (0.318) seconds",
            "Test Suite 'All tests' started at 2000-01-01 12:00:10.735.",
            "Executed 4 tests, with 1 failure (0 unexpected) in 0.003 (0.005) seconds",
            "✔ Test run with 4 tests in 2 suites passed after 0.010 seconds with 1 known issue.",
            "✔ Test run with 6 tests in 3 suites passed after 0.020 seconds with 2 known issues.",
        ] {
            filter.consume(line: line)
        }
        let report = filter.finish()

        // Two XCTest bundles disagree, so the verdict quotes neither counter — same as
        // `RunVerdictTests.twoXCTestBundlesLeaveBothCountersAndTheFailingOneIsNotOverwritten` — while still
        // failing the run on the evidence that one of them recorded a failure.
        #expect(report.tally == nil)
        #expect(report.verdict?.state == .failed)
        #expect(report.verdict?.line == nil)

        let answer = RunReportRenderer(kind: .swiftTest, workingDirectory: Self.workingDirectory)
            .render(report, exitCode: 1, logURL: nil)
        #expect(answer.hasPrefix("✘ swift test — exit 1\n"))
        #expect(answer.contains("\n  Swift Testing (bundle 1 of 2, 4 tests in 2 suites): 0 failures, 1 known issue\n"))
        #expect(answer.contains("\n  Swift Testing (bundle 2 of 2, 6 tests in 3 suites): 0 failures, 2 known issues\n"))
    }

    /// The single-counter shape beside the two-counter one above: one XCTest bundle, so the verdict quotes its one `Executed …` line directly, and the Swift Testing half's known-issue arithmetic still prints beneath it.
    @Test
    func aFailingXCTestSingleCounterStillPrintsTheSwiftTestingHalfsKnownIssueArithmetic() {
        var filter = RunOutputFilter(expecting: .runTally)
        for line in [
            "Test Suite 'All tests' started at 2000-01-01 12:00:09.390.",
            "Executed 12 tests, with 3 failures (0 unexpected) in 0.315 (0.318) seconds",
            "✔ Test run with 4 tests in 2 suites passed after 0.010 seconds with 1 known issue.",
            "✔ Test run with 6 tests in 3 suites passed after 0.020 seconds with 2 known issues.",
        ] {
            filter.consume(line: line)
        }
        let report = filter.finish()

        #expect(report.tally == nil)
        #expect(report.verdict?.state == .failed)
        #expect(report.verdict?.line == "Executed 12 tests, with 3 failures (0 unexpected) in 0.315 (0.318) seconds")

        let answer = RunReportRenderer(kind: .swiftTest, workingDirectory: Self.workingDirectory)
            .render(report, exitCode: 1, logURL: nil)
        #expect(answer.hasPrefix("✘ swift test — exit 1\n"))
        #expect(answer.contains("\n  Swift Testing (bundle 1 of 2, 4 tests in 2 suites): 0 failures, 1 known issue\n"))
        #expect(answer.contains("\n  Swift Testing (bundle 2 of 2, 6 tests in 3 suites): 0 failures, 2 known issues\n"))
    }

    /// A tally line that does not match `RunTestTally.parse`'s pattern is still kept and printed verbatim, because `RunOutputFilter.recordSummary` classifies it on `Test run with `, not on parsing.
    ///
    /// So a reader sees three tally lines above this answer while only two of them yield arithmetic, and numbering has to be counted over the three printed lines, not the two that parsed, or "bundle 2 of 2" would sit beside the wrong one.
    @Test
    func aTallyLineThatDoesNotParseIsSkippedWithoutShiftingTheOthersPosition() {
        var filter = RunOutputFilter(expecting: .runTally)
        for line in [
            "✔ Test run with 4 tests in 2 suites passed after 0.010 seconds with 1 known issue.",
            "✔ Test run with 2 tests in 1 suite passed after 0.001 seconds with 1 warning.",
            "✘ Test run with 6 tests in 3 suites failed after 0.020 seconds with 3 issues (including 1 known issue).",
        ] {
            filter.consume(line: line)
        }
        let report = filter.finish()

        #expect(report.tally == nil)
        #expect(report.summaryLines.count == 3)

        let answer = RunReportRenderer(kind: .swiftTest, workingDirectory: Self.workingDirectory)
            .render(report, exitCode: 1, logURL: nil)
        #expect(answer.contains("\n  Swift Testing (bundle 1 of 3, 4 tests in 2 suites): 0 failures, 1 known issue\n"))
        #expect(answer.contains("\n  Swift Testing (bundle 3 of 3, 6 tests in 3 suites): 2 failures, 1 known issue\n"))
        #expect(!answer.contains("tally 2 of 3"))
    }
}
