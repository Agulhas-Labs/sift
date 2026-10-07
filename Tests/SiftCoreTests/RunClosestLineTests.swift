//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// A failed `contains`, `hasPrefix` or `hasSuffix` over a multi-line haystack names the haystack line worth reading, read from a real capture of what Swift Testing prints for one.
///
/// The capture is `Fixtures/RunOutput/swift-test-contains.txt`: the haystack is not in the failure's message but on the `↳   reason → "…` line beneath it, running on across indented lines with real newlines, so a note capped at three lines shows the start of it and rarely the line that answers the question.
struct RunClosestLineTests {
    @Test
    func aContainsFailureNamesTheHaystackLineClosestToItsNeedle() throws {
        #expect(try Self.closestLine(of: "probe()") == "closest line: truncated: 11 more member lines — pass offset: 60")
    }

    /// The ninth line is past the three the note keeps, so the search has to read the value the log printed rather than the note the answer renders.
    @Test
    func theWholeHaystackIsSearchedNotOnlyTheLinesTheNoteKeeps() throws {
        #expect(try Self.closestLine(of: "long()") == "closest line: the matching needle row here")
    }

    @Test
    func aNeedlePassedAsAVariableIsReadFromTheValuePrintedForIt() throws {
        #expect(try Self.closestLine(of: "variable()") == "closest line: delta line four")
    }

    @Test
    func aHaystackSharingNoTextWithTheNeedleSaysSo() throws {
        #expect(try Self.closestLine(of: "nothing()") == "no line shares text with it")
    }

    @Test
    func hasPrefixNamesTheFirstLineAndHasSuffixTheLast() throws {
        #expect(try Self.closestLine(of: "prefix()") == "closest line: alpha line one")
        #expect(try Self.closestLine(of: "suffix()") == "closest line: gamma line three")
    }

    /// The answer `sift run` prints carries the line beneath the failure's message, where the reader looks first.
    @Test
    func theRenderedAnswerCarriesTheClosestLineBeneathTheMessage() throws {
        let report = try TestSources.runReport(Self.capture, invokedAs: ["swift", "test"])
        let answer = RunReportRenderer(kind: .swiftTest, workingDirectory: URL(fileURLWithPath: "/Users/dev/P"))
            .render(report, exitCode: 1, logURL: nil)
            .components(separatedBy: "\n")
        let message = try #require(answer.firstIndex { $0.contains("Expectation failed: reason.contains(\"truncated: 10 more") })

        #expect(answer[message + 1] == "    closest line: truncated: 11 more member lines — pass offset: 60")
    }

    /// Any other failure carries no such line, whatever its note prints.
    @Test
    func aFailureThatIsNoContainmentCallNamesNoLine() {
        var filter = RunOutputFilter(expecting: .runTally)
        filter.consume(line: "✘ Test probe() recorded an issue at T.swift:5:5: Expectation failed: reason == \"one\"")
        filter.consume(line: "↳ reason == \"one\" → false")
        filter.consume(line: "↳   reason → \"alpha line one")
        filter.consume(line: "    beta line two\"")
        let report = filter.finish()

        #expect(report.testFailures.first?.closestLine == nil)
    }

    /// An empty haystack line prints as an indented line with nothing on it, and the value goes on beneath it; read as the end of the note, the search never saw the line that nearly matched.
    @Test
    func aBlankLineInsideTheHaystackDoesNotEndIt() throws {
        #expect(try Self.closestLine(of: "blank()", in: Self.blankCapture) == "closest line: truncated: 11 more member lines — pass offset: 60")
    }

    /// With one line before the blank, the note was cut to that line and no closest line was printed at all.
    @Test
    func aBlankLineAfterTheFirstHaystackLineDoesNotCutTheNote() throws {
        let failure = try Self.failure(named: "single()", in: Self.blankCapture)

        #expect(failure.closestLine == "closest line: truncated: 11 more member lines — pass offset: 60")
        #expect(failure.note?.contains("truncated: 11 more member lines") == true)
    }

    /// A haystack line that ends in a quote of its own is not the end of the value while the next line still continues it.
    @Test
    func aHaystackLineEndingInAQuoteDoesNotCloseTheValue() throws {
        #expect(try Self.closestLine(of: "quoted()", in: Self.blankCapture) == "closest line: truncated: 11 more member lines — pass offset: 60")
    }

    /// A comment whose indented detail has a blank line inside keeps the detail beneath the blank.
    @Test
    func aBlankLineInsideAnIndentedDetailBlockDoesNotEndTheNote() throws {
        let failure = try Self.failure(named: "detail()", in: Self.blankCapture)

        #expect(failure.note?.contains("detail two") == true)
    }

    /// The empty line a test printed after the last failure's value, and the indented output beneath it, are nothing to do with that failure.
    @Test
    func anEmptyLineAfterAClosedValueGluesNothingOntoItsNote() throws {
        let failure = try Self.failure(named: "blank()", in: Self.blankCapture)

        #expect(failure.note?.contains("indented output") == false)
    }

    /// A blank held after one failure's note is let go by the next failure's own line, which is recorded as a failure of its own.
    @Test
    func aBlankLineBetweenTwoFailuresKeepsThemApart() {
        var filter = RunOutputFilter(expecting: .runTally)
        filter.consume(line: "✘ Test first() recorded an issue at T.swift:5:5: Expectation failed: reason.contains(\"delta line\")")
        filter.consume(line: "↳   reason → \"alpha line one")
        filter.consume(line: "    delta line two\"")
        filter.consume(line: "    ")
        filter.consume(line: "✘ Test second() recorded an issue at T.swift:9:5: Expectation failed: 1 == 2")
        filter.consume(line: "↳ 1 == 2 → false")
        let report = filter.finish()

        #expect(report.testFailures.map(\.name) == ["first()", "second()"])
        #expect(report.testFailures.first?.closestLine == "closest line: delta line two")
        #expect(report.testFailures.first?.note?.contains("1 == 2") == false)
    }

    /// A haystack past the note limit is searched as far as the limit: a line found there is named as the closest in the lines read, and none found says nothing rather than that no line matches.
    @Test
    func aHaystackPastTheNoteLimitIsSearchedAsFarAsTheLimitAndSaysSo() {
        let rows = 3000
        let early = Self.longHaystackFailure(rows: rows, match: 5)
        let late = Self.longHaystackFailure(rows: rows, match: rows - 1)

        #expect(early?.hasPrefix("closest line in the first ") == true)
        #expect(early?.hasSuffix(" lines: row 5 needle text here") == true)
        #expect(late == nil)
    }

    /// Two lines can share the same longest contiguous run with the needle while differing only in the digits before it; the one whose digits are closer to the needle's own — the longer common subsequence, in order — wins over the earlier line.
    @Test
    func aTiedRunGoesToTheLineWithTheLongerSubsequenceNotTheEarlierOne() {
        #expect(Self.tiedRunFailure() == "closest line: alpha 13, alpha 14  in station()")
    }
}

private extension RunClosestLineTests {
    static var capture: String {
        "swift-test-contains"
    }

    /// Blank lines, quotes and indented detail inside a note: `blank()`, `single()` and `quoted()` over haystacks whose near match sits past a blank or a quoted line, `detail()` a comment with a blank line in its detail, and `gap()` a failure followed by printed output.
    static var blankCapture: String {
        "swift-test-contains-blank"
    }

    static func closestLine(of name: String, in capture: String = capture, sourceLocation: SourceLocation = #_sourceLocation) throws -> String? {
        try failure(named: name, in: capture, sourceLocation: sourceLocation).closestLine
    }

    static func failure(named name: String, in capture: String, sourceLocation: SourceLocation = #_sourceLocation) throws -> RunTestFailure {
        let report = try TestSources.runReport(capture, invokedAs: ["swift", "test"])
        return try #require(report.testFailures.first { $0.name == name }, sourceLocation: sourceLocation)
    }

    /// The closest line of a `contains` failure over a haystack of `rows` lines in the shape Swift Testing prints, only `match` sharing text with the needle.
    static func longHaystackFailure(rows: Int, match: Int) -> String? {
        var filter = RunOutputFilter(expecting: .runTally)
        filter.consume(line: "✘ Test long() recorded an issue at T.swift:5:5: Expectation failed: reason.contains(\"needle text there\")")
        filter.consume(line: "↳ reason.contains(\"needle text there\") → false")
        filter.consume(line: "↳   reason → \"row 0 filler")
        for row in 1 ..< rows {
            let text = row == match ? "row \(row) needle text here" : "row \(row) filler"
            filter.consume(line: "    \(text)\(row == rows - 1 ? "\"" : "")")
        }
        return filter.finish().testFailures.first?.closestLine
    }

    /// A `contains` failure whose haystack has two lines sharing the same longest contiguous run with the needle, differing only in the digits before it — the second line's digits are the closer match.
    static func tiedRunFailure() -> String? {
        var filter = RunOutputFilter(expecting: .runTally)
        filter.consume(line: "✘ Test tied() recorded an issue at T.swift:5:5: Expectation failed: reason.contains(\"alpha 16, alpha 17  in station()\")")
        filter.consume(line: "↳ reason.contains(\"alpha 16, alpha 17  in station()\") → false")
        filter.consume(line: "↳   reason → \"before line filler")
        filter.consume(line: "    alpha 11  in station().extra.more()")
        filter.consume(line: "    alpha 13, alpha 14  in station()\"")
        return filter.finish().testFailures.first?.closestLine
    }
}
