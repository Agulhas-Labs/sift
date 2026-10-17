//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// Covers the edges of the join that carries a multi-line `#expect` across the lines Swift Testing prints it over: a `↳` comment, a blank line inside the expression, and each condition that ends the join.
struct RunExpressionJoinEdgeTests {
    private static var issue: String {
        "✘ Test open() recorded an issue at WidgetTests.swift:9:9: "
    }

    /// A comment holding an unmatched bracket is not an expression: it stays a note, and the lines of the comment stay lines of their own.
    @Test
    func aCommentWithAnUnmatchedBracketJoinsNothing() throws {
        var filter = RunOutputFilter(expecting: .runTally)
        filter.consume(line: Self.issue + "Expectation failed: (x → 2) == 1")
        filter.consume(line: "↳ missing (")
        filter.consume(line: "  second line")
        filter.consume(line: "  third")
        filter.consume(line: "✘ Test open() failed after 0.001 seconds with 1 issue.")
        let failure = try #require(filter.finish().testFailures.first)

        #expect(failure.message == "Expectation failed: (x → 2) == 1")
        #expect(failure.note == "missing (\nsecond line\nthird")
    }

    /// A blank line inside the expression is taken by the join, and the rest of the expression is joined after it.
    @Test
    func aBlankLineInsideTheExpressionDoesNotCutIt() throws {
        var filter = RunOutputFilter(expecting: .runTally)
        filter.consume(line: Self.issue + "Expectation failed: max(")
        filter.consume(line: "")
        filter.consume(line: "  a, b) == 3")
        filter.consume(line: "✘ Test open() failed after 0.001 seconds with 1 issue.")
        let failure = try #require(filter.finish().testFailures.first)

        #expect(failure.message == "Expectation failed: max(a, b) == 3")
        #expect(failure.note == nil)
    }

    /// The cap is twelve lines: the first twelve are joined and the thirteenth onward is the note, as any indented line beneath a message is.
    @Test
    func theCapKeepsTheFirstTwelveLinesJoined() throws {
        var filter = RunOutputFilter(expecting: .runTally)
        filter.consume(line: Self.issue + "Expectation failed: f(")
        for number in 1 ... 14 {
            filter.consume(line: "  a\(number),")
        }
        filter.consume(line: "✘ Test open() failed after 0.001 seconds with 1 issue.")
        let failure = try #require(filter.finish().testFailures.first)

        let joined = (1 ... 12).map { "a\($0)," }.joined(separator: " ")

        #expect(failure.message == "Expectation failed: f(" + joined)
        #expect(failure.note == "a13,\na14,")
    }

    /// XCTest's counter inside an open join ends it and still reaches the summary.
    @Test
    func anXCTestCounterEndsTheJoinAndIsStillRead() {
        var filter = RunOutputFilter(expecting: .runTally)
        filter.consume(line: Self.issue + "Expectation failed: f(")
        filter.consume(line: "\t Executed 3 tests, with 1 failure (0 unexpected) in 0.100 (0.100) seconds")
        let report = filter.finish()

        #expect(report.testFailures.first?.message == "Expectation failed: f(")
        #expect(report.summaryLines.contains { $0.contains("Executed 3 tests, with 1 failure") })
    }

    /// An event line inside an open join ends it and is read as its own event: a second failure is listed.
    @Test
    func anEventLineEndsTheJoinAndIsReadOnItsOwn() {
        var filter = RunOutputFilter(expecting: .runTally)
        filter.consume(line: Self.issue + "Expectation failed: f(")
        filter.consume(line: "✘ Test other() recorded an issue at WidgetTests.swift:20:9: Expectation failed: g == 1")
        let failures = filter.finish().testFailures

        #expect(failures.map(\.name) == ["open()", "other()"])
        #expect(failures.first?.message == "Expectation failed: f(")
        #expect(failures.last?.message == "Expectation failed: g == 1")
    }

    /// A start line inside an open join also ends it, so the next line is the new test's and not the expression's.
    @Test
    func aStartedLineEndsTheJoin() throws {
        var filter = RunOutputFilter(expecting: .runTally)
        filter.consume(line: Self.issue + "Expectation failed: f(")
        filter.consume(line: "◇ Test other() started.")
        filter.consume(line: "  a)")
        let failure = try #require(filter.finish().testFailures.first)

        #expect(failure.message == "Expectation failed: f(")
    }
}
