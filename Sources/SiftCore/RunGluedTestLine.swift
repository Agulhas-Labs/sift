//
// Copyright © Agulhas Labs
//

import Foundation

/// A test framework's line that arrived glued behind output a test printed without a newline, as `xcodebuild` writes it on every run where a test prints that way: XCTest's `Test Case '…' passed (0.001 seconds).` straight after a printed `legacy`, `partial crate output✔ Test partial() passed after 0.003 seconds.`.
///
/// Every reader anchors on a line's head, so read whole the framework's line is no line at all: its test is missing from the live count and the report, and a glued `recorded an issue` line loses its message and location. The line is two lines that lost the newline between them, and ``RunOutputFilter`` and ``RunLiveTally`` both read it as those two.
///
/// **What it takes is narrow, because a line can quote a result as well as lose a newline in front of one.** An assertion's message quoting `Test Case '-[A b]' passed (0.001 seconds).` and a child process's log line `[child] ✘ Test y() failed after 0.1 seconds with 1 issue.` carry the same words mid-line. So a start or an ending is taken only where it is the whole rest of the line, closing on its own full stop or its comment's closing quote, and an ending or an issue only for a test whose start this run already printed at the head of a line (``startedTest(in:)``): a glued line is the next line of a test the run is in, and a quoted one is, as often as not, some other test's or none. A Swift Testing skip is the one ending held to no start, since a skipped test prints none. A start found mid-line opens no test, or a child process forwarding its own run behind a prefix would let its own endings through. The run's own line is never taken: it names no test, so nothing can tie it to this run, and a child's run summary read as this run's turns a green run red. Nor is a line whose head is already an XCTest assertion, whose message runs to the end of the line and may quote anything.
struct RunGluedTestLine {
    /// The output in front of a test framework's line and that line, or `nil` where `line` already reads from its head, opens on a continuation marker, or carries no framework line behind other text.
    ///
    /// The framework's line is found where it opens: XCTest's `Test Case '` or a Swift Testing status glyph followed by ` Test `, and it is taken only where what follows reads as one of the lines the type's own documentation lists, an ending or an issue only for a test `started` says the run has started, and never behind an XCTest assertion's head. The earliest such place wins, so the second part reads from its head and is never split again.
    static func split(_ line: String, started: (String) -> Bool) -> (output: String, rest: String)? {
        let undecorated = RunOutputFilter.undecorated(line)
        if line.hasPrefix("Test Case '") || undecorated.hasPrefix("Test ") {
            return nil
        }
        let decoration = line[line.startIndex ..< undecorated.startIndex]
        if decoration.unicodeScalars.contains(where: RunTestOutcomes.continuationMarkers.contains) {
            return nil
        }
        var from = line.startIndex
        while let found = line.range(of: "Test ", range: from ..< line.endIndex) {
            from = found.upperBound
            if let opening = opening(at: found.lowerBound, in: line, started: started) {
                // Asked only once a framework line is found behind other text, as nearly every line has none.
                if RunDiagnostic.parse(line)?.isXCTestAssertion == true {
                    return nil
                }
                return (output: String(line[..<opening]), rest: String(line[opening...]))
            }
        }
        return nil
    }

    /// The test `line`, read from its head, starts: the only kind of start that lets a glued ending or issue for that test be split off.
    static func startedTest(in line: String) -> String? {
        guard line.contains(" started") else {
            return nil
        }
        guard case let (name, .started)? = RunTestOutcomes.xctestEvent(in: line) ?? RunTestOutcomes.swiftTestingEvent(in: line) else {
            return nil
        }
        return name
    }

    /// Where the framework's line holding `test`, the index of a `Test ` inside `line`, opens, or `nil` where no framework line reading as one opens there.
    private static func opening(at test: String.Index, in line: String, started: (String) -> Bool) -> String.Index? {
        guard test > line.startIndex else {
            return nil
        }
        if line[test...].hasPrefix("Test Case '") {
            return readsAsXCTestLine(String(line[test...]), started: started) ? test : nil
        }
        let space = line.index(before: test)
        guard line[space] == " ", space > line.startIndex else {
            return nil
        }
        let glyph = line.index(before: space)
        let mark = line[glyph]
        guard !mark.isLetter, !mark.isNumber, !mark.isWhitespace else {
            return nil
        }
        return readsAsSwiftTestingLine(String(line[glyph...]), started: started) ? glyph : nil
    }

    /// Whether `rest` is the whole of an XCTest start or ending line, an ending only for a test `started` names.
    private static func readsAsXCTestLine(_ rest: String, started: (String) -> Bool) -> Bool {
        guard let (name, event) = RunTestOutcomes.xctestEvent(in: rest), rest.wholeMatch(of: xctestLine) != nil else {
            return false
        }
        if case .started = event {
            return true
        }
        return started(name)
    }

    /// Whether `rest`, opening on a status glyph, is the whole of a Swift Testing start or ending, or an issue line, an ending or an issue only for a test `started` names, a skip for any test.
    ///
    /// An issue line is the one shape not held to the end of the line: its message runs to the end, so nothing there can say where it stops. Its test's start is the only check it gets. The run's own line is never one.
    private static func readsAsSwiftTestingLine(_ rest: String, started: (String) -> Bool) -> Bool {
        let undecorated = RunOutputFilter.undecorated(rest)
        if undecorated.hasPrefix("Test run ") {
            return false
        }
        if let (name, event) = RunTestOutcomes.swiftTestingEvent(in: rest) {
            guard let line = undecorated.wholeMatch(of: swiftTestingLine) else {
                return false
            }
            if case .started = event {
                return true
            }
            // Keyed on the words, not the event: a cancelled test is read as skipped too, but it printed a start.
            return line.output.1 != nil || started(name)
        }
        guard let name = RunTestOutcomes.unreadSwiftTestingName(in: rest), undecorated.contains(" recorded an issue ") else {
            return false
        }
        return started(name)
    }

    /// The whole of an XCTest start or ending: `Test Case '-[S t]' started.`, `… started (Iteration 2 of 3).`, `… passed (0.001 seconds).`, `… failed (…).`, `… skipped (…).`.
    private static var xctestLine: Regex<Substring> {
        #/Test Case '[^']+' (?:started(?: \(Iteration \d+ of \d+\))?|(?:passed|failed|skipped) \([\d.]+ seconds\))\./#
    }

    /// The whole of a Swift Testing start or ending, the glyph in front of it dropped: `Test t() started.`, `… started (repetition 2).`, `… passed after 0.001 seconds.`, `… with 1 known issue.`, `… failed after 0.001 seconds with 2 issues (including 1 known issue).`, `… was cancelled after 0.001 seconds: "why"`, `… skipped.`, `… skipped: "why"`, a parameterized test's `with 4 test cases` read past.
    ///
    /// The capture is the skip's words, which only a skip prints.
    private static var swiftTestingLine: Regex<(Substring, Substring?)> {
        #/Test (?:"[^"]*"|\S+)(?: with \d+ test cases?)? (?:(?:started|started \(repetition \d+\)|passed after [\d.]+ seconds?(?: with \d+ known issues?)?|failed after [\d.]+ seconds? with \d+ issues?(?: \(including \d+ known issues?\))?)\.|was cancelled after [\d.]+ seconds?: ".*"|(skipped(?:\.|: ".*")))/#
    }
}
