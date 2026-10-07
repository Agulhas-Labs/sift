//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// Covers what `run --without` compares two runs by: every test a run started and finished, the passes as much as the failures.
struct RunTestOutcomesTests {
    /// Both frameworks' finishing lines are read off a real capture, and a pass is recorded as surely as a failure.
    @Test
    func aCaptureYieldsEveryTestAndHowItEnded() throws {
        let outcomes = try TestSources.runReport("swift-test-fail").testOutcomes

        #expect(outcomes["shoutingWorks()"] == RunTestOutcomes.Tally(started: 1, failed: 1))
        #expect(outcomes["sizeIsCarried()"] == RunTestOutcomes.Tally(started: 1, failed: 1))
        #expect(outcomes["-[WidgetTests.LegacyWidgetTests testDoubling]"] == RunTestOutcomes.Tally(started: 1, passed: 1))
        #expect(outcomes["-[WidgetTests.LegacyWidgetTests testNaming]"] == RunTestOutcomes.Tally(started: 1, failed: 1))
        // Three Swift Testing functions and two XCTest methods — the run's own tally is none of them.
        #expect(outcomes.names.count == 5)
    }

    /// The same capture's green twin reports every test as passed, which is the half a failure listing never carries.
    @Test
    func aPassingCaptureReportsEveryTestPassed() throws {
        let outcomes = try TestSources.runReport("swift-test-pass").testOutcomes

        #expect(outcomes.names.count == 4)
        #expect(outcomes.tallies.values.allSatisfy { $0.passed == 1 && $0.failed == 0 })
    }

    /// A run that never reached its tests reports none, which is how an answer tells "did not compile" from "failed".
    @Test
    func aRunThatNeverReachedItsTestsReportsNone() throws {
        #expect(try TestSources.runReport("swift-test-linkerror").testOutcomes.isEmpty)
    }

    /// The run's own lines begin with the same word as a test's, and a comment printed under a failure can quote a finishing line word for word; neither is a test.
    @Test
    func theRunsOwnLinesAndAQuotedFinishingLineAreNotTests() {
        var outcomes = RunTestOutcomes()
        for line in [
            "\u{10F7C8}  Test run started.",
            "\u{10105B}  Test run with 2 tests in 1 suite passed after 0.001 seconds.",
            "↳ Test shoutingWorks() passed after 0.001 seconds.",
            "\u{100135}  Test shoutingWorks() passed after 0.001 seconds.",
            "Test Suite 'All tests' passed at 2000-01-01 12:00:00.103.",
            "\u{10105B}  Suite WidgetTests passed after 0.001 seconds.",
            "\u{1008A4}  Test shoutingWorks() recorded an issue at WidgetTests.swift:10:9: Expectation failed: it passed after all",
        ] {
            outcomes.read(line)
        }

        #expect(outcomes.isEmpty)
    }

    /// A display name is read to its closing quote, so words inside it that look like the framework's own cannot move where the name ends.
    @Test
    func aDisplayNameIsReadWholeWhateverItSays() {
        var outcomes = RunTestOutcomes()
        outcomes.read("\u{1008A4}  Test \"The grid passed after a rotation\" failed after 0.002 seconds with 1 issue.")

        #expect(outcomes["\"The grid passed after a rotation\""] == RunTestOutcomes.Tally(failed: 1))
        #expect(outcomes.names.count == 1)
    }

    /// A parameterized test is filed under its function's name, not under the count of cases it ran.
    @Test
    func aParameterizedTestIsFiledUnderItsFunctionsName() {
        var outcomes = RunTestOutcomes()
        outcomes.read("\u{10105B}  Test sizeIsCarried(size:) with 3 test cases passed after 0.004 seconds.")

        #expect(outcomes["sizeIsCarried(size:)"] == RunTestOutcomes.Tally(passed: 1))
    }

    /// A skipped test is its own outcome, in both frameworks' spellings, and a start with no end stays a start.
    @Test
    func skippedAndUnfinishedTestsAreKeptApart() {
        var outcomes = RunTestOutcomes()
        for line in [
            "Test Case '-[WidgetTests.LegacyWidgetTests testNaming]' skipped (0.000 seconds).",
            "\u{100100}  Test sizeIsCarried() skipped: \"not on this platform\"",
            "\u{10F7C8}  Test shoutingWorks() started.",
        ] {
            outcomes.read(line)
        }

        #expect(outcomes["-[WidgetTests.LegacyWidgetTests testNaming]"] == RunTestOutcomes.Tally(skipped: 1))
        #expect(outcomes["sizeIsCarried()"] == RunTestOutcomes.Tally(skipped: 1))
        #expect(outcomes["shoutingWorks()"] == RunTestOutcomes.Tally(started: 1))
    }

    /// Two suites that each declare a function of one name print one name twice, and both finishing lines are counted rather than one standing for the other.
    @Test
    func oneNamePrintedTwiceIsCountedTwice() {
        var outcomes = RunTestOutcomes()
        outcomes.read("\u{10105B}  Test shoutingWorks() passed after 0.001 seconds.")
        outcomes.read("\u{1008A4}  Test shoutingWorks() failed after 0.001 seconds with 1 issue.")

        #expect(outcomes["shoutingWorks()"] == RunTestOutcomes.Tally(passed: 1, failed: 1))
    }

    /// A test that fails and is retried yields one attempt per iteration, each under the iteration its own start line named — which is what tells the attempt that may be timed from the ones that may not.
    @Test
    func aRetriedTestYieldsAnAttemptPerIteration() throws {
        var outcomes = RunTestOutcomes()
        for line in try TestSources.runOutput("xcodebuild-retry-iterations").components(separatedBy: "\n") {
            outcomes.read(line)
        }

        #expect(outcomes.attempts["-[DemoUnitTests.CalculatorTests testFailsOnce]"] == [
            RunTestOutcomes.Attempt(ending: .failed, seconds: 0.172, iteration: 1),
            RunTestOutcomes.Attempt(ending: .passed, seconds: 0.001, iteration: 2),
        ])
        // A test that passed first time ran once, under the iteration its own line named.
        #expect(outcomes.attempts["-[DemoUnitTests.CalculatorTests testAddition]"] == [
            RunTestOutcomes.Attempt(ending: .passed, seconds: 0.001, iteration: 1),
        ])
        #expect(outcomes.attempts["-[DemoUnitTests.CalculatorTests testSkipsWhenUnsupported]"] == [
            RunTestOutcomes.Attempt(ending: .skipped, seconds: 0.004, iteration: 1),
        ])
        // Swift Testing's third repetition is the highest iteration anything in this capture named.
        #expect(outcomes.iterations == 3)
    }

    /// A repeated test's second start is a start like any other: a reader that asks for ` started.` exactly counts the first attempt and silently none of the rest, so the count says once where the transcript shows twice.
    @Test
    func aSwiftTestingRepetitionIsCountedAsAStart() {
        var outcomes = RunTestOutcomes()
        outcomes.read("\u{200B}◇ Test aKnownFormattingIssuePasses() started.")
        outcomes.read("◇ Test aKnownFormattingIssuePasses() started (repetition 2).")

        #expect(outcomes["aKnownFormattingIssuePasses()"] == RunTestOutcomes.Tally(started: 2))
    }

    /// Swift Testing spells a retry's start `started (repetition 2).`, and each attempt keeps the repetition its own start named.
    @Test
    func aSwiftTestingRepetitionIsReadAsAnAttemptOfItsOwn() {
        var outcomes = RunTestOutcomes()
        for line in [
            "\u{200B}◇ Test aKnownFormattingIssuePasses() started.",
            "━ Test aKnownFormattingIssuePasses() failed after 0.007 seconds with 1 issue.",
            "◇ Test aKnownFormattingIssuePasses() started (repetition 2).",
            "━ Test aKnownFormattingIssuePasses() passed after 0.002 seconds with 1 known issue.",
        ] {
            outcomes.read(line)
        }

        #expect(outcomes.attempts["aKnownFormattingIssuePasses()"] == [
            RunTestOutcomes.Attempt(ending: .failed, seconds: 0.007, iteration: 1),
            RunTestOutcomes.Attempt(ending: .passed, seconds: 0.002, iteration: 2),
        ])
        #expect(outcomes.iterations == 2)
    }

    /// A Swift Testing skip names a reason and no duration, which is `nil` seconds rather than a test that took no time; a run that repeats nothing ran one iteration.
    @Test
    func aSkipWithNoDurationCarriesNoSeconds() {
        var outcomes = RunTestOutcomes()
        outcomes.read("\u{200B}➜ Test multipliesLargeNumbers() skipped: \"not ready\"")

        #expect(outcomes.attempts["multipliesLargeNumbers()"] == [RunTestOutcomes.Attempt(ending: .skipped)])
        #expect(outcomes.iterations == 1)
    }
}
