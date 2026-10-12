//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// Covers the reference boundary a `where` answer once carried over reference and usage material: it holds of every such answer, so it is said once per session (``StandingCaveats``) and on no answer (Docs/Design.md §2, *standing caveats*).
///
/// Their own suite rather than a corner of `SemanticWhereTests`, because they are one subject — the contract that every caveat in an answer is about something *in* that answer — and they share that suite's built-store fixture, which is why they lived there.
@Suite(.temporaryDirectories)
struct WhereReferenceBoundaryTests {
    /// Every caveat in an answer is about something *in* that answer: neither a type the store answered nor one whose every row was refused carries the boundary.
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

        #expect(answered.contains("used by Lib.Base"))
        #expect(!answered.contains("references: code occurrences"))
        #expect(refused.contains("REFUSED"))
        #expect(!refused.contains("references: code occurrences"))
    }

    /// A sweep lists the store's references with no boundary line: what this build compiled is the session's to know, from the primer.
    @Test
    func aSweepCarriesNoBoundaryLine() async throws {
        let root = try SemanticWhereTests.makeBuiltRepo()
        let engine = try SiftEngine(directory: root)
        try await engine.awaitSemanticStore()

        let freshness = try await engine.ensureFresh()
        let swept = try await engine.lookup(symbol: "Base", freshness: freshness, options: WhereOptions(includeReferences: true))

        #expect(swept.contains("references to Lib.Base"))
        #expect(!swept.contains("own build only"))
        #expect(!swept.contains("a sibling repo"))
    }

    @Test
    func refsListThePlacesOutsideCode() async throws {
        let root = try SemanticWhereTests.makeBuiltRepo()
        let engine = try SiftEngine(directory: root)
        try await engine.awaitSemanticStore()
        let freshness = try await engine.ensureFresh()

        let swept = try await engine.lookup(symbol: "helper()", freshness: freshness, options: WhereOptions(includeReferences: true))

        // An empty or partial sweep must never read as "nothing left to change": the places outside code are listed, or said to be none in what was read.
        #expect(swept.contains("not code, by written name"))
    }

    /// The parse-error banner, which once shared an insertion slot with the boundary, is still placed above the answer it qualifies, with no boundary beside it.
    @Test
    func theParseErrorBannerLeadsTheAnswerWithNoBoundary() async throws {
        let root = try SemanticWhereTests.makeBuiltRepo()
        let engine = try SiftEngine(directory: root)
        try await engine.awaitSemanticStore()
        _ = try await engine.ensureFresh()

        // A new extension file, never rebuilt: the syntactic reindex still picks up its declaration, but the
        // unclosed brace leaves the file with a parse error, while Base itself — untouched — stays unrefused, so
        // the answer carries the banner over a store answer.
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

        #expect(!answer.contains("references: code occurrences"))
        let bannerIndex = try #require(answer.range(of: "⚠ parse errors")).lowerBound
        let declarationsIndex = try #require(answer.range(of: "declarations (")).lowerBound
        #expect(bannerIndex < declarationsIndex)
    }
}
