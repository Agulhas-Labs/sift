//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// Covers the two boundary lines a `where` answer carries over reference and usage material: what they say, and when they are printed at all.
///
/// Their own suite rather than a corner of `SemanticWhereTests`, because they are one subject — the contract that every caveat in an answer is about something *in* that answer — and they share that suite's built-store fixture, which is why they lived there.
@Suite(.temporaryDirectories)
struct WhereReferenceBoundaryTests {
    /// Every caveat in an answer is about something *in* that answer: a type whose every row was refused resolves no references, so the two boundaries that would bound them are not printed.
    ///
    /// The two lines describe the reference and usage material, and the declaration kinds alone cannot see that a row is about to be refused for staleness — the refusal happens inside the semantic pass, after a header built from the kinds would already have promised them. So they are decided from what the pass actually resolved.
    @Test
    func theReferenceBoundariesAreNotPrintedWhereEveryRowWasRefused() async throws {
        let root = try SemanticWhereTests.makeBuiltRepo()
        let engine = try SiftEngine(directory: root)
        try await engine.awaitSemanticStore()
        let built = try await engine.ensureFresh()

        let answered = try await engine.lookup(symbol: "Base", freshness: built)

        // Base.swift edited after the build: every row `where Base` resolves to is refused, and nothing is left for
        // the boundaries to bound.
        try TestSources.write(
            """
            open class Base {
                public init() {}
                open func greet() {}
                public func added() {}
            }

            public class Child: Base {
                override public func greet() {}
            }
            """,
            to: "Sources/Lib/Base.swift",
            in: root
        )
        let stale = try await engine.ensureFresh()
        let refused = try await engine.lookup(symbol: "Base", freshness: stale)

        #expect(answered.contains("references: code only (not comments or strings) and this repo's own build only"))
        #expect(refused.contains("REFUSED"))
        #expect(!refused.contains("references: code only"))
    }

    /// The second boundary on a sweep, named with the two cases it covers.
    ///
    /// The store holds what *this* build compiled, so a consumer in a sibling repo, or in a target this build did not compile, is not a missed occurrence — it was never a candidate. Unstated, an empty sweep reads as "nothing left to change".
    @Test
    func refsStateThatTheSweepCoversOnlyThisRepositorysBuild() async throws {
        let root = try SemanticWhereTests.makeBuiltRepo()
        let engine = try SiftEngine(directory: root)
        try await engine.awaitSemanticStore()

        let freshness = try await engine.ensureFresh()
        let swept = try await engine.lookup(symbol: "Base", freshness: freshness, options: WhereOptions(includeReferences: true))

        #expect(swept.contains("this repo's own build only"))
        #expect(swept.contains("a sibling repo"))
        #expect(swept.contains("an uncompiled target"))
        #expect(swept.components(separatedBy: "references: code only").count == 2, "the two boundaries are one line, said once")
    }

    @Test
    func refsStateThatCommentsAndStringsAreNotCovered() async throws {
        let root = try SemanticWhereTests.makeBuiltRepo()
        let engine = try SiftEngine(directory: root)
        try await engine.awaitSemanticStore()
        let freshness = try await engine.ensureFresh()

        let swept = try await engine.lookup(symbol: "helper()", freshness: freshness, options: WhereOptions(includeReferences: true))

        // An empty or partial sweep must never read as "nothing left to change".
        #expect(swept.contains("not comments or strings"))
    }

    /// The parse-error banner and the reference boundary line shares an insertion slot, and the banner belongs beneath the boundary it does not qualify, not above them.
    @Test
    func theParseErrorBannerFollowsTheReferenceBoundariesRatherThanLeadingThem() async throws {
        let root = try SemanticWhereTests.makeBuiltRepo()
        let engine = try SiftEngine(directory: root)
        try await engine.awaitSemanticStore()
        _ = try await engine.ensureFresh()

        // A new extension file, never rebuilt: the syntactic reindex still picks up its declaration, but the
        // unclosed brace leaves the file with a parse error, while Base itself — untouched — stays unrefused, so
        // the answer carries both the boundaries and the banner at once.
        try TestSources.write(
            """
            extension Base {
                public func extra() {}
                func truncated(
            }
            """,
            to: "Sources/Lib/Base+Broken.swift",
            in: root
        )
        let freshness = try await engine.ensureFresh()

        let answer = try await engine.lookup(symbol: "Base", freshness: freshness)

        #expect(answer.contains("references: code only"))
        let bannerIndex = try #require(answer.range(of: "⚠ parse errors")).lowerBound
        let boundaryIndex = try #require(answer.range(of: "references: code only")).lowerBound
        #expect(boundaryIndex < bannerIndex)
    }
}
