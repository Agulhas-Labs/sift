//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// The standing caveats (``StandingCaveats``) are said on an answer only where an empty list makes them matter: a `where` with an empty verdict, a `search` whose query has a `calls:` or `uses:` term (Docs/Design.md §2, *Superseded: the caveat is said where it applies*).
@Suite(.temporaryDirectories)
struct CaveatWhereItAppliesTests {
    private static func makeRepo() throws -> URL {
        let root = try TestSources.makeTempRepo()
        try TestSources.write(
            """
            // swift-tools-version: 6.0
            import PackageDescription

            let package = Package(name: "Lib", targets: [.target(name: "Lib")])
            """,
            to: "Package.swift",
            in: root
        )
        try TestSources.write(
            """
            public func used() {}

            public func lonely() {}

            public func caller() {
                used()
            }
            """,
            to: "Sources/Lib/Lib.swift",
            in: root
        )
        try TestSources.swiftBuild(packageAt: root)
        return root
    }

    @Test
    func anEmptyCallersAnswerCarriesTheSentences() async throws {
        let engine = try SiftEngine(directory: Self.makeRepo())
        try await engine.awaitSemanticStore()
        let freshness = try await engine.ensureFresh()

        let answer = try await engine.lookup(symbol: "lonely", freshness: freshness)

        #expect(answer.contains("no callers"), "\(answer)")
        #expect(answer.contains(StandingCaveats.sentences), "\(answer)")
    }

    @Test
    func aNonEmptyCallersAnswerDoesNot() async throws {
        let engine = try SiftEngine(directory: Self.makeRepo())
        try await engine.awaitSemanticStore()
        let freshness = try await engine.ensureFresh()

        let answer = try await engine.lookup(symbol: "used", freshness: freshness)

        #expect(answer.contains("caller"), "\(answer)")
        #expect(!answer.contains(StandingCaveats.sentences), "\(answer)")
    }

    /// The `--refs` sweep of a function nothing calls: its callers list is empty too, so this pins the empty verdict under `--refs`, not an empty refs list alone (a function's `references to` always holds its call sites, so no fixture isolates the refs list).
    @Test
    func anEmptyRefsSweepOfAnUncalledFunctionCarriesTheSentences() async throws {
        let engine = try SiftEngine(directory: Self.makeRepo())
        try await engine.awaitSemanticStore()
        let freshness = try await engine.ensureFresh()

        let answer = try await engine.lookup(symbol: "lonely", freshness: freshness, options: WhereOptions(includeReferences: true))

        #expect(answer.contains("no callers"), "\(answer)")
        #expect(answer.contains(StandingCaveats.sentences), "\(answer)")
    }

    @Test
    func aRefsSweepOfACalledFunctionDoesNot() async throws {
        let engine = try SiftEngine(directory: Self.makeRepo())
        try await engine.awaitSemanticStore()
        let freshness = try await engine.ensureFresh()

        let answer = try await engine.lookup(symbol: "used", freshness: freshness, options: WhereOptions(includeReferences: true))

        #expect(answer.contains("callers of"), "\(answer)")
        #expect(!answer.contains(StandingCaveats.sentences), "\(answer)")
    }

    @Test
    func aSearchWithACallsTermCarriesTheClauseWhetherOrNotItMatches() throws {
        let match = StructuralMatch(path: "a.swift", line: 1, endLine: 2, kind: "func", qualifiedName: "S.f()", signature: "func f()")
        let query = try StructuralQuery("calls:save")
        let matched = SearchRenderer.render(result: StructuralSearch.Result(matches: [match], filesScanned: 1), query: query)
        let empty = SearchRenderer.render(result: StructuralSearch.Result(matches: [], filesScanned: 4), query: query)

        #expect(matched.contains(StandingCaveats.searchClause), "\(matched)")
        #expect(empty.contains(StandingCaveats.searchClause), "\(empty)")
    }

    @Test
    func aSearchWithAUsesTermCarriesTheClauseUnderCountToo() throws {
        let match = StructuralMatch(path: "a.swift", line: 1, endLine: 2, kind: "func", qualifiedName: "S.f()", signature: "func f()")
        let query = try StructuralQuery("uses:save")
        let counted = SearchRenderer.renderCount(result: StructuralSearch.Result(matches: [match], filesScanned: 1), query: query, moduleFor: { _ in "App" })

        #expect(counted.contains(StandingCaveats.searchClause), "\(counted)")
    }

    @Test
    func aSearchWithNeitherTermCarriesNoClauseEvenWhenItMatchesNothing() throws {
        let match = StructuralMatch(path: "a.swift", line: 1, endLine: 2, kind: "func", qualifiedName: "S.f()", signature: "func f()")
        let missing = try StructuralQuery("kind:func name:missing")
        let empty = SearchRenderer.render(result: StructuralSearch.Result(matches: [], filesScanned: 4), query: missing)
        let matched = SearchRenderer.render(result: StructuralSearch.Result(matches: [match], filesScanned: 1), query: missing)

        #expect(!empty.contains(StandingCaveats.searchClause), "\(empty)")
        #expect(!matched.contains(StandingCaveats.searchClause), "\(matched)")
    }
}
