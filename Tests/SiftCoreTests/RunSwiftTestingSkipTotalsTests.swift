//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// The `totals:` line says how many Swift Testing tests the run's own lines reported skipped, as it says an XCTest counter's `XCTSkip`s, in every mode and with no index involved: Swift Testing's tally counts a disabled test among its tests.
struct RunSwiftTestingSkipTotalsTests {
    private static func totals(of lines: [String], invokedAs arguments: [String], kind: RunCommandKind = .swiftTest) -> String? {
        var filter = RunOutputFilter(invokedAs: arguments)
        for line in lines {
            filter.consume(line: line)
        }
        let report = filter.finish(exitCode: 0)
        let answer = RunReportRenderer(kind: kind, workingDirectory: URL(fileURLWithPath: "/Users/dev/Gizmo"), selector: RunTestSelector.named(in: arguments))
            .render(report, exitCode: 0, logURL: nil)
        return answer.split(separator: "\n").map(String.init).first { $0.hasPrefix("totals:") }
    }

    /// One passing test beside a disabled one: the tally counts both, and the line says one of them was skipped.
    @Test(arguments: [
        ["swift", "test"],
        ["swift", "test", "--parallel"],
        ["swift", "test", "--package-path", "Tools/Nested"],
    ])
    func aDisabledTestBesideAPassingOneIsNamedSkipped(arguments: [String]) {
        let lines = [
            "◇ Test run started.",
            "◇ Suite PalletTests started.",
            "◇ Test anOrdinaryPass() started.",
            "↩ Test switchedOff() skipped.",
            "✔ Test anOrdinaryPass() passed after 0.001 seconds.",
            "✔ Suite PalletTests passed after 0.002 seconds.",
            "✔ Test run with 2 tests in 1 suite passed after 0.002 seconds.",
        ]
        let line = Self.totals(of: lines, invokedAs: arguments)

        #expect(line?.hasSuffix("Swift Testing 2 tests in 1 suite, 1 skipped") == true, "\(line ?? "no totals line")")
    }

    /// A filter that selected only the disabled test: the line still reads the run's pass, and says the one test it counts was skipped rather than run.
    @Test
    func aFilteredRunOfOnlyADisabledTestSaysItWasSkipped() {
        let lines = [
            "◇ Test run started.",
            "↩ Test switchedOff() skipped: \"not yet\"",
            "✔ Test run with 1 test in 0 suites passed after 0.001 seconds.",
        ]
        let line = Self.totals(of: lines, invokedAs: ["swift", "test", "--filter", "switchedOff"])

        #expect(line == "totals: ✔ passed · Swift Testing 1 test in 0 suites, 1 skipped")
    }

    /// An `xcodebuild` run prints Swift Testing's lines too, and its skip is said the same way.
    @Test
    func anXcodebuildRunNamesItsSwiftTestingSkip() throws {
        let arguments = ["xcodebuild", "test", "-scheme", "TestDemo"]
        let report = try TestSources.runReport("xcodebuild-retry-iterations", invokedAs: arguments, exitCode: 1)
        let answer = RunReportRenderer(kind: .xcodebuild, workingDirectory: URL(fileURLWithPath: "/Users/dev/Project"))
            .render(report, exitCode: 1, logURL: nil)
        let line = answer.split(separator: "\n").map(String.init).first { $0.hasPrefix("totals:") }

        #expect(line?.hasSuffix("Swift Testing 7 tests in 2 suites, 1 skipped") == true, "\(line ?? "no totals line")")
    }

    /// A run that skipped nothing says nothing about skips.
    @Test
    func aRunThatSkippedNothingSaysNothingOfSkips() {
        let lines = [
            "◇ Test run started.",
            "✔ Test anOrdinaryPass() passed after 0.001 seconds.",
            "✔ Test run with 1 test in 0 suites passed after 0.001 seconds.",
        ]

        #expect(Self.totals(of: lines, invokedAs: ["swift", "test"]) == "totals: ✔ passed · Swift Testing 1 test in 0 suites")
    }
}
