//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// Covers an `#expect` written over several lines, which Swift Testing prints over several lines in the issue line and again in each `↳` expansion beneath it.
///
/// `Fixtures/RunOutput/swift-test-nil-reads.txt` is the real run: its `multiLine` tests fail on a five-line `#expect`, and read one line at a time the message stopped at `Gizmo.soleElement(` while the expression's own continuation lines became the failure's note.
@Suite(.temporaryDirectories)
struct RunMultilineExpectationTests {
    /// The message is the whole expression, joined so it reads as the one-line spelling.
    @Test
    func theMessageIsTheWholeExpression() throws {
        let failure = try Self.multiLine0()

        #expect(failure.message == #"Expectation failed: Gizmo.soleElement(of: note, width: 320)?.label == "note 0""#)
    }

    /// The note opens on the first real `↳` line, itself joined, rather than on the expression's second line.
    @Test
    func theNoteOpensOnTheExpansion() throws {
        let note = try #require(Self.multiLine0().note)

        #expect(note.hasPrefix(#"Gizmo.soleElement(of: note, width: 320)?.label == "note 0" → false"#))
        #expect(!note.hasPrefix("of: note,"))
    }

    /// The census leads with the whole expression, not the first line of it.
    @Test
    func theTopLineCarriesTheWholeExpression() throws {
        let block = try Self.block()
        let top = try #require(block.first { $0.hasPrefix("  ↳ top: ") })

        // The multiLine and readsLabel tests are eight each; cut at its first line, the multiLine shape was the top.
        #expect(top == #"  ↳ top: Expectation failed: Gizmo.soleElement(of: Self.band(), width: Self.bodyWidth)?.label == "…"  ×8"#)
        #expect(!block.contains { $0.hasSuffix("Gizmo.soleElement(") || $0.contains("Gizmo.soleElement(  ×") })
    }

    /// The `→ false` evaluation is merged into the message by its content, so no multiLine failure's entry carries the adjacency marker, in the census or in the answer's listing.
    @Test
    func noMultiLineFailureIsAttributedByAdjacency() throws {
        let lines = try Self.block() + Self.answer()
        var inMultiLine = false
        var multiLineBlocks = 0
        var adjacent: [String] = []
        for line in lines {
            if line.hasPrefix("  "), !line.hasPrefix("   "), !line.hasPrefix("  ↳") {
                inMultiLine = line.hasPrefix("  multiLine")
                multiLineBlocks += inMultiLine ? 1 : 0
            } else if !line.hasPrefix("  ") {
                inMultiLine = false
            }
            if inMultiLine, line.contains("(by adjacency)") {
                adjacent.append(line)
            }
        }

        #expect(multiLineBlocks > 0)
        #expect(adjacent.isEmpty)
        #expect(lines.contains(#"    Expectation failed: Gizmo.soleElement(of: note, width: 320)?.label == "note 0" → false Gizmo.soleElement(of: note, width: 320)?.label → nil some → "note 0""#))
    }

    /// A line that is not indented ends the join before it starts, and the message keeps its first line alone.
    @Test
    func anUnindentedLineJoinsNothing() throws {
        var filter = RunOutputFilter(expecting: .runTally)
        filter.consume(line: "✘ Test open() recorded an issue at WidgetTests.swift:9:9: Expectation failed: Gizmo.read(")
        filter.consume(line: "of: widget)")
        filter.consume(line: "✘ Test open() failed after 0.001 seconds with 1 issue.")
        let failure = try #require(filter.finish().testFailures.first)

        #expect(failure.message == "Expectation failed: Gizmo.read(")
        #expect(failure.note == nil)
    }

    /// A bracket inside a string literal opens nothing, an escaped quote included, so the indented line beneath stays the note.
    @Test
    func aBracketInsideAStringLiteralOpensNoJoin() throws {
        var filter = RunOutputFilter(expecting: .runTally)
        filter.consume(line: #"✘ Test quoted() recorded an issue at WidgetTests.swift:9:9: Expectation failed: label == "say \"(\" twice (""#)
        filter.consume(line: "  the label is wrong")
        filter.consume(line: "✘ Test quoted() failed after 0.001 seconds with 1 issue.")
        let failure = try #require(filter.finish().testFailures.first)

        #expect(failure.message == #"Expectation failed: label == "say \"(\" twice (""#)
        #expect(failure.note == "the label is wrong")
    }

    /// A `↳` line directly beneath an unbalanced message is the note, not the expression's next line.
    @Test
    func aMarkedLineDirectlyBeneathJoinsNothing() throws {
        var filter = RunOutputFilter(expecting: .runTally)
        filter.consume(line: "✘ Test open() recorded an issue at WidgetTests.swift:9:9: Expectation failed: Gizmo.read(")
        filter.consume(line: "↳ the widget reads nothing")
        filter.consume(line: "✘ Test open() failed after 0.001 seconds with 1 issue.")
        let failure = try #require(filter.finish().testFailures.first)

        #expect(failure.message == "Expectation failed: Gizmo.read(")
        #expect(failure.note == "the widget reads nothing")
    }

    static func multiLine0(sourceLocation: SourceLocation = #_sourceLocation) throws -> RunTestFailure {
        try #require(report().testFailures.first { $0.name == "multiLine0()" }, sourceLocation: sourceLocation)
    }

    static func report() throws -> RunReport {
        try TestSources.runReport("swift-test-nil-reads", invokedAs: ["swift", "test"], exitCode: 1)
    }

    /// The block with no log left to list into, the census a live answer measures this run with.
    static func block() throws -> [String] {
        let failures = try report().testFailures.map { failure in
            RunFailureShape.Failure(name: failure.name, location: failure.location, message: failure.message, arguments: failure.arguments, note: failure.note)
        }
        var budget = RunFailureCensus.listingBudget
        return RunFailureShape.of(failures, changedFiles: .of([])).rendered(within: 0, spending: &budget)
    }

    static func answer() throws -> [String] {
        let answer = try RunReportRenderer(kind: .swiftTest, workingDirectory: URL(fileURLWithPath: "/Users/dev/Widget"))
            .render(report(), exitCode: 1, logURL: nil)
        return answer.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    }
}
