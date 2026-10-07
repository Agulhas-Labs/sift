//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// Trap-shaped text outside the crashed test's own stretch of the log is dropped; inside the stretch every trap is kept, unranked, since neither the log nor the event stream says which one the runtime wrote.
struct RunTestCrashTrapSpanTests {
    private static var lookalike: String {
        "Shelf/Rack.swift:9: Fatal error: printed by a passing test"
    }

    private static var signalLine: String {
        "error: Process '/usr/libexec/swift/pm/swiftpm-testing-helper --test-bundle-path /Users/dev/Pallet/.build/out/Products/Debug/PalletTests.xctest --testing-library swift-testing' exited with unexpected signal code 5"
    }

    /// The captured run: XCTest's `testStacks` prints a look-alike outside the span (dropped), then inside the crashed Swift Testing process `stacks()` prints one after `topples()` started and `topples()` traps: both are kept, in no pinned order.
    @Test
    func everyTrapInsideTheCrashedSpanIsKeptAndTheOnesOutsideAreDropped() throws {
        let report = try TestSources.runReport("swift-test-crash-st-lookalike", invokedAs: ["swift", "test"], exitCode: 1)
        let trap = "Pallet/Pallet.swift:7: Fatal error: Unexpectedly found nil while unwrapping an Optional value"

        #expect(report.testCrash?.traps.count == 2)
        #expect(Set(report.testCrash?.traps ?? []) == [trap, Self.lookalike])
        let lines = Self.answer(report).split(separator: "\n").map(String.init)
        #expect(lines.contains("  \(trap)"))
        #expect(lines.contains("  \(Self.lookalike)"))
    }

    /// The XCTest process traps in `testBuckles`, then the Swift Testing process that ran after it prints a look-alike: the later line is not the crash's.
    @Test
    func aLookalikeAnotherProcessPrintedAfterTheTrapIsNotQuoted() throws {
        let log = try TestSources.runOutput("swift-test-crash-xc")
            .replacingOccurrences(of: "◇ Test loads() started.\n", with: "◇ Test loads() started.\n\(Self.lookalike)\n")
        var filter = RunOutputFilter(invokedAs: ["swift", "test"])
        filter.consume(Data(log.utf8))
        let report = filter.finish(exitCode: 1)

        #expect(report.testCrash?.traps == ["Swift/ContiguousArrayBuffer.swift:695: Fatal error: Index out of range"])
    }

    /// `xcodebuild` has no signal-line contract: a log ending in a started-and-never-finished test at exit 65 reads as it did, unusable, so the raw log with its `Fatal error:` and `Failing tests:` lines is what is served.
    @Test
    func xcodebuildExit65IsNoUnsignalledCrash() throws {
        let report = try TestSources.runReport("xcodebuild-crash-restart", invokedAs: ["xcodebuild", "test"], exitCode: 65)

        #expect(report.testCrash == nil)
        let answer = RunReportRenderer(kind: .xcodebuild, workingDirectory: URL(fileURLWithPath: "/Users/dev/Pallet")).render(report, exitCode: 65, logURL: nil)
        #expect(!answer.contains("ended without a result"))
        #expect(!answer.contains("test process crashed"))
        #expect(!report.isUsable(exitCode: 65))
    }

    /// A look-alike printed before the crashed test started, in the same process, is not the crash's trap, so the answer says the process printed none.
    @Test
    func aLookalikeBeforeTheCrashedTestStartedIsNotQuoted() {
        var filter = RunOutputFilter(invokedAs: ["swift", "test"])
        for line in [
            Self.signalLine,
            "◇ Test run started.",
            "◇ Test stacks() started.",
            Self.lookalike,
            "✔ Test stacks() passed after 0.001 seconds.",
            "◇ Test topples() started.",
        ] {
            filter.consume(line: line)
        }
        let report = filter.finish(exitCode: 1)

        #expect(report.testCrash?.traps == [])
        let lines = Self.answer(report).split(separator: "\n").map(String.init)
        #expect(lines.dropFirst().first == "  no trap message in the log: the process took the signal without printing one")
    }

    /// The capture in the order no reading of position survives: `topples()` traps at line 12, `stacks()` ends at 13, and the look-alike `stacks()` printed arrives at 14, after its own test's ending, so both are kept.
    ///
    /// A test's printed standard output reaches the log out of step with the standard error its console and the trap share, and the event stream records no printed text, so neither says which line is the crash's.
    @Test
    func aLookalikeRelayedAfterItsOwnTestEndedIsKeptBesideTheRealTrap() throws {
        var filter = RunOutputFilter(invokedAs: ["swift", "test"])
        try filter.consume(Data(TestSources.runOutput("swift-test-crash-st-lookalike-relayed").utf8))
        let stream = try TestSources.runOutputData("swift-test-crash-st-lookalike-relayed", extension: "jsonl")
        try filter.read(eventStream: ShardEventStream.read(#require(String(bytes: stream, encoding: .utf8))))
        let report = filter.finish(exitCode: 1)
        let trap = "Pallet/Pallet.swift:4: Fatal error: Unexpectedly found nil while unwrapping an Optional value"

        #expect(report.testCrash?.unfinished == ["topples()"])
        #expect(report.testCrash?.traps.count == 2)
        #expect(Set(report.testCrash?.traps ?? []) == [trap, Self.lookalike])
        let lines = Self.answer(report).split(separator: "\n").map(String.init)
        #expect(lines.contains("  \(trap)"))
        #expect(lines.contains("  \(Self.lookalike)"))
    }

    private static func answer(_ report: RunReport) -> String {
        RunReportRenderer(kind: .swiftTest, workingDirectory: URL(fileURLWithPath: "/Users/dev/Pallet")).render(report, exitCode: 1, logURL: nil)
    }
}
