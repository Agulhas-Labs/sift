//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// The `totals:` line states the skip count whenever the run's per-test results were read, `0 skipped` included, and each skipped test is named under it.
struct RunSkipNamesTests {
    private static func answer(of lines: [String], invokedAs arguments: [String] = ["swift", "test"]) -> [String] {
        var filter = RunOutputFilter(invokedAs: arguments)
        for line in lines {
            filter.consume(line: line)
        }
        let report = filter.finish(exitCode: 0)
        return RunReportRenderer(kind: .swiftTest, workingDirectory: URL(fileURLWithPath: "/Users/dev/Gizmo"), selector: RunTestSelector.named(in: arguments))
            .render(report, exitCode: 0, logURL: nil)
            .split(separator: "\n").map(String.init)
    }

    private static func totals(_ answer: [String]) -> String? {
        answer.first { $0.hasPrefix("totals:") }
    }

    private static func skipLines(_ answer: [String]) -> [String] {
        answer.filter { $0.hasPrefix("skipped:") }
    }

    private static func xctestLines(skipping reasons: [(String, String?)], passing: Int) -> [String] {
        var lines = ["Test Suite 'Selected tests' started at 2000-01-01 12:00:00.000."]
        for (test, reason) in reasons {
            lines.append("Test Case '-[GizmoTests.PalletTests \(test)]' started.")
            if let reason {
                lines.append("/Users/dev/Gizmo/Tests/GizmoTests/PalletTests.swift:4: -[GizmoTests.PalletTests \(test)] : Test skipped - \(reason)")
            } else {
                lines.append("/Users/dev/Gizmo/Tests/GizmoTests/PalletTests.swift:4: -[GizmoTests.PalletTests \(test)] : Test skipped")
            }
            lines.append("Test Case '-[GizmoTests.PalletTests \(test)]' skipped (0.001 seconds).")
        }
        for index in 0 ..< passing {
            lines.append("Test Case '-[GizmoTests.PalletTests test\(index)]' started.")
            lines.append("Test Case '-[GizmoTests.PalletTests test\(index)]' passed (0.001 seconds).")
        }
        let total = reasons.count + passing
        let skipped = reasons.isEmpty ? "" : " with \(reasons.count) \(reasons.count == 1 ? "test" : "tests") skipped and"
        lines.append("Test Suite 'Selected tests' passed at 2000-01-01 12:00:00.002.")
        lines.append("\t Executed \(total) tests,\(skipped.isEmpty ? " with" : skipped) 0 failures (0 unexpected) in 0.002 (0.002) seconds")
        return lines
    }

    @Test
    func aPassingSwiftTestingRunStatesZeroSkipped() {
        let answer = Self.answer(of: [
            "◇ Test run started.",
            "◇ Test anOrdinaryPass() started.",
            "✔ Test anOrdinaryPass() passed after 0.001 seconds.",
            "✔ Test run with 1 test in 0 suites passed after 0.001 seconds.",
        ])

        #expect(Self.totals(answer) == "totals: ✔ passed · Swift Testing 1 test in 0 suites, 0 skipped", "\(answer)")
        #expect(Self.skipLines(answer).isEmpty)
    }

    @Test
    func aPassingXCTestRunStatesZeroSkipped() {
        let answer = Self.answer(of: Self.xctestLines(skipping: [], passing: 2))

        #expect(Self.totals(answer)?.hasSuffix("XCTest 2 tests, 0 skipped") == true, "\(answer)")
        #expect(Self.skipLines(answer).isEmpty)
    }

    @Test
    func aRunWithNoParsedTestResultsStatesNoSkipCount() {
        let answer = Self.answer(of: ["Build complete! (0.16s)"])

        #expect(!answer.contains { $0.contains("skipped") }, "\(answer)")
    }

    @Test
    func anXCTestRunNamesEachSkipWithItsReason() {
        let answer = Self.answer(of: Self.xctestLines(skipping: [("testA", "no second level"), ("testB", nil)], passing: 1))

        #expect(Self.totals(answer)?.hasSuffix("XCTest 3 tests, 2 skipped") == true, "\(answer)")
        #expect(Self.skipLines(answer) == ["skipped: PalletTests.testA — no second level", "skipped: PalletTests.testB"], "\(answer)")
        let totalsIndex = answer.firstIndex { $0.hasPrefix("totals:") }
        let skippedIndex = answer.firstIndex { $0.hasPrefix("skipped:") }
        #expect(totalsIndex.map { $0 + 1 } == skippedIndex)
    }

    @Test
    func aSwiftTestingRunNamesItsSkip() {
        let answer = Self.answer(of: [
            "◇ Test run started.",
            "↩ Test switchedOff() skipped: \"not yet\"",
            "✔ Test run with 1 test in 0 suites passed after 0.001 seconds.",
        ])

        #expect(Self.skipLines(answer) == ["skipped: switchedOff() — not yet"], "\(answer)")
    }

    @Test
    func moreThanTenSkipsListTenAndCountTheRest() {
        let reasons = (1 ... 12).map { ("test\($0)", Optional("reason \($0)")) }
        let answer = Self.answer(of: Self.xctestLines(skipping: reasons, passing: 0))
        let skipped = Self.skipLines(answer)

        #expect(skipped.count == 11, "\(answer)")
        #expect(skipped.first == "skipped: PalletTests.test1 — reason 1")
        #expect(skipped.last == "skipped: +2 more")
    }

    @Test
    func aParallelRunWhoseXCTestSkipsWentUnreportedDoesNotStateZeroSkipped() {
        let answer = Self.answer(of: [
            "[1/1] Testing GizmoTests.PalletTests/test0",
            "◇ Test run started.",
            "◇ Test anOrdinaryPass() started.",
            "✔ Test anOrdinaryPass() passed after 0.001 seconds.",
            "✔ Test run with 1 test in 0 suites passed after 0.001 seconds.",
        ], invokedAs: ["swift", "test", "--parallel"])
        let totals = Self.totals(answer) ?? ""

        #expect(totals.hasSuffix("Swift Testing 1 test in 0 suites, skips not reported"), "\(answer)")
        #expect(!totals.contains("0 skipped"), "\(answer)")
    }

    @Test
    func aParallelRunStillStatesAndNamesASwiftTestingSkipItSaw() {
        let answer = Self.answer(of: [
            "◇ Test run started.",
            "↳ Test switchedOff() skipped: \"not yet\"",
            "◇ Test switchedOff() started.",
            "➜ Test switchedOff() skipped: \"not yet\"",
            "✔ Test run with 1 test in 0 suites passed after 0.001 seconds.",
        ], invokedAs: ["swift", "test", "--parallel"])

        #expect(Self.totals(answer)?.hasSuffix("1 skipped") == true, "\(answer)")
    }

    @Test
    func talliesNotSummedStateTheirSkipCountToo() {
        let closing = "✔ Test run with 1 test in 0 suites passed after 0.001 seconds."
        let lines = ["◇ Test run started.", "◇ Test anOrdinaryPass() started.", "✔ Test anOrdinaryPass() passed after 0.001 seconds."]
        let answer = Self.answer(of: lines + [closing, "Test run with oops tests"] + lines + [closing])

        #expect(Self.totals(answer)?.contains("tallies, not summed") == true, "\(answer)")
        #expect(Self.totals(answer)?.contains("; 0 skipped") == true, "\(answer)")
    }

    @Test
    func aStreamedSkipKeepsItsReason() {
        func line(_ kind: String, _ name: String, extra: String = "") -> String {
            #"{"kind":"event","payload":{\#(extra)"instant":{"absolute":1,"since1970":0},"iteration":1,"kind":"\#(kind)","messages":[],"testID":"LibTests.\#(name)()\/T.swift:3:6"},"version":"6.4.0"}"#
        }
        func declared(_ name: String) -> String {
            #"{"kind":"test","payload":{"id":"LibTests.\#(name)()\/T.swift:3:6","isParameterized":false,"kind":"function","name":"\#(name)()"},"version":"6.4.0"}"#
        }
        let stream = ShardEventStream.read([
            declared("switchedOff"), declared("anOrdinaryPass"),
            line("testSkipped", "switchedOff", extra: #""_comments":["not yet"],"#),
            line("testStarted", "anOrdinaryPass"), line("testEnded", "anOrdinaryPass"),
        ].joined(separator: "\n"))
        var filter = RunOutputFilter(invokedAs: ["swift", "test"])
        filter.consume(Data("◇ Test run started.\n✔ Test run with 2 tests in 0 suites passed after 0.001 seconds.\n".utf8))
        filter.read(eventStream: stream)
        let report = filter.finish(exitCode: 0)
        let text = RunReportRenderer(kind: .swiftTest, workingDirectory: URL(fileURLWithPath: "/Users/dev/Lib"))
            .render(report, exitCode: 0, logURL: nil)

        #expect(text.contains("skipped: switchedOff() — not yet"), "\(text)")
    }
}
