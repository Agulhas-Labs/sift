//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// Covers the live tally a running `sift run` reads its progress from: which phase the run is in, what it is doing, and how its time splits.
struct RunLiveTallyTests {
    private static let start = Date(timeIntervalSinceReferenceDate: 0)

    /// A capture's lines, each arriving one second after the last, the first one second after the start.
    private static func fedByTheSecond(_ name: String, upTo end: Int? = nil) throws -> (tally: RunLiveTally, lines: [String]) {
        let lines = try TestSources.runOutput(name).components(separatedBy: "\n")
        var tally = RunLiveTally(startedAt: start)
        for (index, line) in lines.prefix(end ?? lines.count).enumerated() {
            tally.consume(line: line, now: start.addingTimeInterval(Double(index + 1)))
        }
        return (tally, lines)
    }

    /// The run is building until the first line of a test process, and the time that line arrived is where its build time ends and its test time begins.
    @Test
    func theFirstTestLineEndsTheBuildAndStartsTheTestClock() throws {
        let lines = try TestSources.runOutput("swift-test-fail").components(separatedBy: "\n")
        let opening = try #require(lines.firstIndex { $0.hasPrefix("Test Suite 'All tests' started") })
        let built = try Self.fedByTheSecond("swift-test-fail", upTo: opening)

        #expect(built.tally.state.phase == .building)
        #expect(built.tally.state.phaseStartedAt == Self.start)
        // The capture's last step before its tests is linking the test product.
        #expect(built.tally.state.current?.hasPrefix("Linking Widget") == true)

        var whole = try Self.fedByTheSecond("swift-test-fail").tally
        let durations = whole.finish(now: Self.start.addingTimeInterval(100))

        #expect(whole.state.phase == .testing)
        #expect(whole.state.testingStartedAt == Self.start.addingTimeInterval(Double(opening + 1)))
        #expect(whole.state.phaseStartedAt == Self.start.addingTimeInterval(Double(opening + 1)))
        #expect(durations == RunLiveState.Durations(buildMs: (opening + 1) * 1000, testMs: (99 - opening) * 1000))
    }

    /// A build that runs no test is building to its last line, and all of its time is build time.
    @Test
    func aRunWithNoTestLineSpendsAllItsTimeBuilding() throws {
        var tally = try Self.fedByTheSecond("swift-build-success").tally
        let durations = tally.finish(now: Self.start.addingTimeInterval(42.5))

        #expect(tally.state.phase == .building)
        #expect(tally.state.testingStartedAt == nil)
        #expect(tally.state.warnings == 2)
        #expect(durations == RunLiveState.Durations(buildMs: 42500, testMs: nil))
    }

    /// Under `swift test --parallel` there is no suite line and no start line: the first `[k/N] Testing …` line starts the tests and names the one running, and counts nothing.
    @Test
    func aParallelRunStartsTestingOnItsFirstProgressLine() throws {
        let tally = try Self.fedByTheSecond("swift-test-parallel-filter-pass").tally

        #expect(tally.state.phase == .testing)
        #expect(tally.state.testingStartedAt == Self.start.addingTimeInterval(5))
        #expect(tally.state.current == "GadgetTests.LegacyTests/testGamma")
        #expect(tally.state.tests == RunLiveState.Tests())
    }

    /// `xcodebuild test-without-building` with parallel testing prints no test line of its own; its closing `Testing started` is the only one, so its test time is what follows that line, and its debug line quoting the same words is no test line.
    @Test
    func xcodebuildsClosingTestingStartedIsTheOnlyTestLineOfAParallelRun() throws {
        let lines = try TestSources.runOutput("xcodebuild-parallel-test-unparenthesised").components(separatedBy: "\n")
        let debug = try #require(lines.firstIndex { $0.hasSuffix("-- Testing started completed.") })
        let closing = try #require(lines.lastIndex { $0 == "Testing started" })
        let beforeTheClosingLine = try Self.fedByTheSecond("xcodebuild-parallel-test-unparenthesised", upTo: closing).tally

        #expect(debug < closing)
        #expect(beforeTheClosingLine.state.phase == .building)

        var tally = try Self.fedByTheSecond("xcodebuild-parallel-test-unparenthesised", upTo: closing + 1).tally
        let durations = tally.finish(now: Self.start.addingTimeInterval(Double(closing + 1)))

        #expect(tally.state.phase == .testing)
        #expect(durations == RunLiveState.Durations(buildMs: (closing + 1) * 1000, testMs: 0))
    }

    /// A suite's ending, a run's tally and a parameterized test's cases are no tests, and a test run again is still one test, counted by how it last ended.
    @Test
    func aSuiteIsNoTestAndARepeatedTestIsCountedOnce() {
        var tally = RunLiveTally(startedAt: Self.start)
        for line in [
            "◇ Test run started.",
            "◇ Suite WidgetTests started.",
            "◇ Test shoutingWorks() started.",
            "✔ Test shoutingWorks() passed after 0.001 seconds.",
            "◇ Test sizeIsCarried(size:) started.",
            "✔ Test sizeIsCarried(size:) with 3 test cases passed after 0.001 seconds.",
            "◇ Test shoutingWorks() started (repetition 2).",
            "✘ Test shoutingWorks() failed after 0.001 seconds with 1 issue.",
            "✘ Suite WidgetTests failed after 0.002 seconds with 1 issue.",
            "✘ Test run with 2 tests in 1 suite failed after 0.002 seconds with 1 issue.",
            "Test Suite 'LegacyWidgetTests' passed at 2000-01-01 12:00:00.461.",
        ] {
            tally.consume(line: line, now: Self.start)
        }

        #expect(tally.state.tests == RunLiveState.Tests(passed: 1, failed: 1))
    }

    /// A test plan's retry replaces the failed attempt with the passing one, so XCTest's nine tests read as nine, not as the ten attempts its own counter adds up, beside the seven Swift Testing's run tally names, one of them run three times.
    @Test
    func aRetriedTestCountsOnceByItsLastAttempt() throws {
        let tally = try Self.fedByTheSecond("xcodebuild-retry-iterations").tally

        #expect(tally.state.tests == RunLiveState.Tests(passed: 14, skipped: 2))
    }

    /// The test now running is the one that last started, by the name its framework prints.
    @Test
    func theCurrentTestIsTheOneThatLastStarted() throws {
        let lines = try TestSources.runOutput("swift-test-fail").components(separatedBy: "\n")
        let naming = try #require(lines.firstIndex { $0.hasSuffix("testNaming]' started.") })
        let tally = try Self.fedByTheSecond("swift-test-fail", upTo: naming + 1).tally

        #expect(tally.state.current == "-[WidgetTests.LegacyWidgetTests testNaming]")
        #expect(tally.state.tests == RunLiveState.Tests(passed: 1))
    }

    /// Swift 6.4 colours its diagnostics and names a target between thin spaces: the colour is no obstacle to counting a warning, and a counter that names nothing leaves the step it last named standing.
    @Test
    func aColouredLogIsCountedAndABareCounterKeepsTheLastStep() throws {
        let lines = try TestSources.runOutput("swift-test-colored-warning-and-failure").components(separatedBy: "\n")
        let bare = try #require(lines.firstIndex { $0.hasPrefix("[54") })
        let building = try Self.fedByTheSecond("swift-test-colored-warning-and-failure", upTo: bare + 1).tally

        #expect(building.state.current == "PalletTests-product")
        #expect(building.state.warnings == 1)

        let whole = try Self.fedByTheSecond("swift-test-colored-warning-and-failure").tally

        #expect(whole.state.warnings == 1)
        #expect(whole.state.errors == 0)
        #expect(whole.state.tests == RunLiveState.Tests(failed: 1))
    }

    /// An XCTest assertion is printed in a compiler error's shape and is no compiler error.
    @Test
    func anXCTestAssertionIsNoCompilerError() throws {
        let tally = try Self.fedByTheSecond("swift-test-mixed-xctest-failure").tally

        #expect(tally.state.errors == 0)
        #expect(tally.state.tests == RunLiveState.Tests(passed: 1, failed: 1))
    }

    /// Each build tool's way of saying what it is compiling is given as target then file.
    @Test(arguments: [
        ("[4/6] Compiling MixedTests Legacy.swift", "MixedTests Legacy.swift"),
        ("[5/6] Linking WidgetTests", "Linking WidgetTests"),
        ("[32\u{2009}/\u{2009}55] Pallet", "Pallet"),
        ("SwiftCompile normal arm64 /Users/dev/Gizmo/Sources/Gizmo/Gizmo.swift (in target 'Gizmo' from project 'Gizmo')", "Gizmo Gizmo.swift"),
        ("SwiftCompile normal arm64 Compiling\\ Gizmo.swift /Users/dev/Gizmo/Sources/Gizmo/Gizmo.swift (in target 'Gizmo' from project 'Gizmo')", "Gizmo Gizmo.swift"),
        ("CompileSwift normal arm64 /Users/dev/My\\ Gizmo/Gizmo\\ Parts.swift (in target 'Gizmo' from project 'Gizmo')", "Gizmo Gizmo Parts.swift"),
    ])
    func aBuildStepIsNamedAsTargetThenFile(line: String, step: String) {
        #expect(RunBuildStep.named(in: line) == step)
    }

    /// Lines that name no step leave the current one standing.
    @Test(arguments: ["[54\u{2009}/\u{2009}76]", "[Planning deferred tasks]", "Building for debugging...", "CompileSwiftSources normal arm64 com.apple.xcode.tools.swift.compiler (in target 'Gizmo' from project 'Gizmo')"])
    func aLineNamingNoStepIsNoStep(line: String) {
        #expect(RunBuildStep.named(in: line) == nil)
    }
}
