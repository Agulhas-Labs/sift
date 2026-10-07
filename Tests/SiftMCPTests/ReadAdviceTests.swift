//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftMCP
import Testing

/// Covers the other half of the miss: a whole-file read of Swift source or of a Markdown document, and the three cases where reading it is the right move.
struct ReadAdviceTests {
    /// Every file is above the floor, so the exclusion under test is never the one firing.
    private static func big(_: String) -> Bool {
        false
    }

    /// Every file is below it — `digest` would have served the source anyway.
    private static func small(_: String) -> Bool {
        true
    }

    @Test
    func aWholeFileReadOfSwiftSourceIsOfferedADigest() throws {
        let suggestion = try #require(
            ReadAdvice.suggestion(path: "/x/ProductKit/Sources/SummaryState.swift", ranged: false, belowFloor: Self.big)
        )

        #expect(suggestion.call == "digest SummaryState")
    }

    /// A ranged read is the second half of digest-to-locate-then-read — the loop the advice asks for.
    @Test
    func aRangedReadIsNotInterrupted() {
        #expect(ReadAdvice.suggestion(path: "/x/SummaryState.swift", ranged: true, belowFloor: Self.big) == nil)
    }

    /// Below the compression floor `digest` hands back the source itself, so the read got identical bytes and there was nothing to save.
    @Test
    func aFileBelowTheCompressionFloorIsNotWorthInterrupting() {
        #expect(ReadAdvice.suggestion(path: "/x/Tiny.swift", ranged: false, belowFloor: Self.small) == nil)
    }

    @Test
    func aFileThatIsNeitherSwiftNorMarkdownIsNoneOfItsBusiness() {
        #expect(ReadAdvice.suggestion(path: "/x/Package.resolved", ranged: false, belowFloor: Self.big) == nil)
        #expect(ReadAdvice.suggestion(path: "/x/Notes.txt", ranged: false, belowFloor: Self.big) == nil)
    }

    /// A whole read of a document `digest` already answers: the heading outline is the locating step a ranged read follows, exactly as a digest's member ranges are.
    ///
    /// Asked for by the path it was read at, never by a stem or a bare file name: `digest Design.md` answers about a document at the repository root, not the one under `Docs/`.
    @Test
    func aWholeReadOfALargeMarkdownDocumentIsOfferedItsHeadingOutline() throws {
        let suggestion = try #require(
            ReadAdvice.suggestion(path: "/repo/Docs/Design.md", ranged: false, belowFloor: Self.big)
        )

        #expect(suggestion.call == "digest /repo/Docs/Design.md")
        #expect(suggestion.yields.contains("heading"))
        // Or the hook withholds the advice it just built, and nothing reaches the caller.
        #expect(suggestion.namesATarget)
    }

    /// A document's ranged read is the loop working, as a Swift file's is — pinned against the whole read of the same path, since "no advice" is also what a document drew before it was admitted at all.
    @Test
    func aRangedReadOfAMarkdownDocumentIsNotInterrupted() throws {
        let path = "/repo/Docs/Design.md"
        let whole = try #require(ReadAdvice.suggestion(path: path, ranged: false, belowFloor: Self.big))

        #expect(whole.call == "digest \(path)")
        #expect(ReadAdvice.suggestion(path: path, ranged: true, belowFloor: Self.big) == nil)
    }

    /// Below the floor `digest` serves the document's own text instead of an outline of it, so the read got identical bytes — the same exclusion the source side has, in the document's units.
    @Test
    func aDocumentBelowTheFloorIsNotWorthInterrupting() {
        #expect(ReadAdvice.suggestion(path: "/repo/Notes.md", ranged: false, belowFloor: Self.small) == nil)
    }
}
