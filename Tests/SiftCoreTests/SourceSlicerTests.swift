//
// Copyright © Agulhas Labs
//

@testable import SiftCore
import Testing

/// Covers the doc-summary cap: a clause boundary is preferred over an arbitrary byte offset, but only once it has kept enough of the budget to be worth preferring, and a word is never split.
struct SourceSlicerTests {
    private func docSummary(of source: String, sourceLocation: SourceLocation = #_sourceLocation) throws -> String? {
        let file = try TestSources.parsed(source, path: "Sources/Alpha/Doc.swift")
        return try #require(file.symbols.first { $0.name == "run()" }, sourceLocation: sourceLocation).docSummary
    }

    @Test
    func aClauseBoundaryThatKeepsHalfTheBudgetIsPreferred() throws {
        let kept = String(repeating: "a", count: 50)
        let tail = String(repeating: "b", count: 60)
        let summary = try docSummary(of: """
        /// \(kept), \(tail)
        func run() {}
        """)

        #expect(summary == kept + "…")
    }

    @Test
    func aClauseBoundaryTooEarlyFallsBackToTheLastWordBoundary() throws {
        let middle = String(repeating: "b", count: 30)
        let filler = String(repeating: "c", count: 60)
        let summary = try docSummary(of: """
        /// aa, \(middle) \(filler)
        func run() {}
        """)

        #expect(summary == "aa, " + middle + "…")
    }

    @Test
    func aRunWithNoSafeCutPointIsServedWholeWithinTheCeiling() throws {
        let run = String(repeating: "x", count: 100)
        let summary = try docSummary(of: """
        /// \(run)
        func run() {}
        """)

        #expect(summary == run)
    }

    /// A run with no word boundary anywhere is still bounded: the old ceiling holds, and the one cut that breaks a word says so.
    @Test
    func aRunPastTheCeilingIsCutThereAndMarked() throws {
        let run = String(repeating: "x", count: 300)
        let summary = try #require(try docSummary(of: """
        /// \(run)
        func run() {}
        """))

        #expect(summary.utf8.count <= 160)
        #expect(summary.hasSuffix("…"))
        #expect(run.hasPrefix(String(summary.dropLast())))
    }

    /// A first word longer than the budget is kept whole and cut at the boundary after it, rather than served uncut or broken inside.
    @Test
    func aFirstWordLongerThanTheBudgetIsCutAtTheBoundaryAfterIt() throws {
        let word = String(repeating: "x", count: 100)
        let summary = try docSummary(of: """
        /// \(word) and then a tail of ordinary words that runs on well past the ceiling of the summary itself
        func run() {}
        """)

        #expect(summary == word + "…")
    }

    /// A dot, colon or comma inside an identifier is not a clause boundary: only a mark followed by whitespace ends a clause.
    ///
    /// The identifier's own dot sits later in the window than the real boundary, so counting it served half a name.
    @Test
    func aMarkInsideAnIdentifierIsNotAClauseBoundary() throws {
        let summary = try docSummary(of: """
        /// Several targets answered in one call, joined, for a loop like `digest Type.a Type.b Type.c Type.d` here
        func run() {}
        """)

        #expect(summary == "Several targets answered in one call, joined…")
    }

    /// The same identifiers, bare — no backticks to fall back on, so this one stands or falls on the "whitespace follows the mark" half of the rule alone.
    ///
    /// The dot in a bare `Type.a` sits later in the window than the real boundary and is followed by a letter, not whitespace: counting it anyway is exactly the regression a code-span check alone cannot catch, since there is no span here to catch it.
    @Test
    func aMarkInAnIdentifierOutsideAnyCodeSpanIsStillNotAClauseBoundary() throws {
        let summary = try docSummary(of: """
        /// Several targets answered in one call, joined, for a loop like digest Type.a Type.b Type.c Type.d here
        func run() {}
        """)

        #expect(summary == "Several targets answered in one call, joined…")
    }

    /// A mark followed by whitespace still ends no clause inside an open code span, so a cut never leaves one open where a boundary outside it keeps half the budget.
    @Test
    func aMarkInsideACodeSpanIsNotAClauseBoundary() throws {
        let summary = try docSummary(of: """
        /// Answers the question the caller asked here, and nothing else `if a, b, c, d, e, f, g` beyond it now
        func run() {}
        """)

        #expect(summary == "Answers the question the caller asked here…")
    }

    /// "e.g." reads to the cut rule exactly like a sentence's own full stop — whitespace follows it, and it sits outside any code span — so without knowing the abbreviation it wins as the latest boundary in the window, cutting mid-abbreviation as "e.g…".
    @Test
    func anAbbreviationsPeriodIsNotAClauseBoundary() throws {
        let summary = try docSummary(of: """
        /// Serves the cached copy first, only refreshing lazily, e.g. once the caller asks for something newer than it
        func run() {}
        """)

        #expect(summary == "Serves the cached copy first, only refreshing lazily…")
    }

    /// A comma written straight after the abbreviation is followed by the whitespace its period is not, so it read as the latest boundary in the window and cut the summary as "e.g.…".
    @Test
    func aMarkRightAfterAnAbbreviationIsNotAClauseBoundary() throws {
        let summary = try docSummary(of: """
        /// Serves the cached copy first, only refreshing lazily, e.g., once the caller asks for something newer than it
        func run() {}
        """)

        #expect(summary == "Serves the cached copy first, only refreshing lazily…")
    }

    /// The budget is bytes, not characters: a summary of two-byte characters is cut at half the characters an ASCII one would be, and never inside a character.
    @Test
    func theBudgetIsCountedInBytesAndNeverSplitsACharacter() throws {
        let words = Array(repeating: "ééééé", count: 20).joined(separator: " ")
        let summary = try #require(try docSummary(of: """
        /// \(words)
        func run() {}
        """))

        #expect(summary.hasSuffix("…"))
        let kept = String(summary.dropLast())
        #expect(kept.utf8.count <= 80)
        #expect(words.hasPrefix(kept))
        #expect(kept.hasSuffix("ééééé"))
    }
}
