//
// Copyright © Agulhas Labs
//

import Foundation

/// Swift Testing's closing count of a run, and the one number in a filtered answer this tool works out for itself.
///
/// The subtraction is the whole reason it exists. `withKnownIssue` records a deliberate, written-down expectation that something is broken, so a known issue is an issue the run *planned* for; folding it into the failure count turns a run red for doing exactly what it was written to do, and letting its presence alone decide the colour is the same mistake from the other side.
///
/// Swift Testing never states the difference. The failing form prints `with 667 issues (including 1 known issue)` and the passing form `with 1 known issue`, and in both the reader is left to do the arithmetic — which is precisely where a reader in a hurry gets it wrong.
public struct RunTestTally: Sendable, Equatable {
    public let tests: Int
    public let suites: Int
    /// Whether the run declared itself passed, taken from its own word rather than inferred from the counts beside it.
    public let passed: Bool
    /// Every issue the run recorded, the known ones included.
    public let issues: Int
    /// The issues that were expected, and are therefore not failures.
    public let knownIssues: Int

    public init(tests: Int, suites: Int, passed: Bool, issues: Int, knownIssues: Int) {
        self.tests = tests
        self.suites = suites
        self.passed = passed
        self.issues = issues
        self.knownIssues = knownIssues
    }
}

public extension RunTestTally {
    /// The issues nobody expected, which is what a reader means by "failures".
    var failures: Int {
        max(0, issues - knownIssues)
    }

    /// The tally `line` states, or `nil` when the line is not one.
    ///
    /// Two tail shapes, both real and both in the captures: a failing run prints `with 667 issues (including 1 known issue).` and a passing one `with 1 known issue.` — the second naming a count of known issues where the first names a count of all of them. A passing run with a known issue is not a rare shape to be defensive about; it is what the green half of the acceptance corpus ends on.
    ///
    /// The pattern starts at the sentence and not at the beginning of the line, because the glyph in front of it is not dependable: 306 lines of the captured logs carry a zero-width space before theirs, which `CharacterSet.whitespaces` does not contain, so anything anchored on the line start reads the wrong thing.
    static func parse(_ line: String) -> RunTestTally? {
        let sentence = /Test run with (\d+) tests? in (\d+) suites? (passed|failed) after [\d.]+ seconds(?: with (\d+) (known )?issues?(?: \(including (\d+) known issues?\))?)?\./
        guard let match = line.wholeMatch(of: sentence) else {
            return nil
        }
        guard let tests = Int(match.1), let suites = Int(match.2) else {
            return nil
        }
        let counted = match.4.flatMap { Int($0) } ?? 0
        let known = match.6.flatMap { Int($0) } ?? 0
        // `with 1 known issue.` carries no total, because in that shape the known issues are all of them.
        let onlyKnownWereCounted = match.5 != nil
        return RunTestTally(
            tests: tests,
            suites: suites,
            passed: match.3 == "passed",
            issues: counted,
            knownIssues: onlyKnownWereCounted ? counted : known
        )
    }
}
