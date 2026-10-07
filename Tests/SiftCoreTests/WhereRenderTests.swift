//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// Covers symbol resolution: exact, qualified, labeled/overloaded, conformers, and the fuzzy fallback.
@Suite(.temporaryDirectories)
struct WhereRenderTests {
    private static func seededStore() throws -> IndexStore {
        let store = try TestSources.makeStore()
        let sampler = try TestSources.parsed(
            """
            protocol Sampler {
                func sample() -> Int
            }
            struct RateSampler: Sampler, Sendable {
                func sample() -> Int { 1 }
            }
            struct CountSampler: Sampler {
                func sample() -> Int { 2 }
            }
            struct Cache {
                func store(_ value: Int, for key: String) {}
                func store(_ value: Double, for key: String) {}
                func test_run() {}
                func testARun(y: Int) {}
            }
            """,
            path: "Sources/Alpha/Samplers.swift"
        )
        try store.replaceFiles([sampler]) { _ in ("Alpha", false) }
        return store
    }

    private static func render(_ query: String) async throws -> String {
        let store = try seededStore()
        let renderer = WhereRenderer(store: store)
        return try await renderer.render(query: query, semantic: .inactive(note: "test run")).body
    }

    @Test
    func typeLookupListsDeclarationConformersAndMode() async throws {
        let output = try await Self.render("Sampler")

        #expect(output.contains("mode: syntactic"))
        #expect(output.contains("declarations (1):"))
        #expect(output.contains("Alpha.Sampler — protocol"))
        #expect(output.contains("conformers of Sampler (2, by written name):"))
        #expect(output.contains("Alpha.RateSampler"))
        #expect(output.contains("Alpha.CountSampler"))
    }

    @Test
    func labeledFormResolvesOverloads() async throws {
        let output = try await Self.render("store(_:for:)")

        #expect(output.contains("declarations (2):"))
        #expect(output.contains("func store(_ value: Int, for key: String)"))
        #expect(output.contains("func store(_ value: Double, for key: String)"))
    }

    @Test
    func qualifiedMemberLookupFiltersByContainer() async throws {
        let output = try await Self.render("RateSampler.sample()")

        #expect(output.contains("declarations (1):"))
        #expect(output.contains("Alpha.RateSampler.sample()"))
        #expect(!output.contains("CountSampler.sample()"))
    }

    @Test
    func underscoresInNamesMatchLiterally() async throws {
        let output = try await Self.render("test_run")

        #expect(output.contains("declarations (1):"))
        #expect(output.contains("test_run()"))
        #expect(!output.contains("testARun"))
    }

    @Test
    func extensionContextNeverFabricatesConformances() {
        func row(signature: String) -> SymbolRow {
            SymbolRow(
                id: 1, fileID: 1, path: "A.swift", module: "M", parentID: nil, kind: .extensionKind,
                name: "S", line: 1, column: 1, endLine: 2, accessLevel: .internalLevel,
                isStatic: false, isStored: false, signature: signature, docSummary: nil, ifConfigCondition: nil,
                viewOutline: nil
            )
        }

        #expect(extensionContext(row(signature: "extension S where T: Sendable")) == " where T: Sendable")
        #expect(extensionContext(row(signature: "private extension S")) == " (private)")
        #expect(extensionContext(row(signature: "@available(macOS 13, *) private extension S")) == " (private)")
        #expect(extensionContext(row(signature: "extension S: Equatable")) == " (: Equatable)")
        #expect(extensionContext(row(signature: "extension S: Equatable where T: Sendable")) == " (: Equatable) where T: Sendable")
    }

    @Test
    func unknownSymbolOffersNearestCandidates() async throws {
        let output = try await Self.render("Samp")

        #expect(output.contains("no exact match; nearest symbols:"))
        #expect(output.contains("Sampler"))
    }

    @Test
    func byteIdenticalHitsCollapseWhileDriftedOnesStayListed() {
        let hits = [
            SemanticStore.Hit(name: "caller()", path: "/repo/A.swift", line: 14, unit: "App 1"),
            SemanticStore.Hit(name: "caller()", path: "/repo/A.swift", line: 14, unit: "Tool 1"),
            SemanticStore.Hit(name: "caller()", path: "/repo/A.swift", line: 13, unit: "Tool 1"),
            SemanticStore.Hit(name: "other()", path: "/repo/B.swift", line: 14, unit: "App 1"),
        ]

        let collapsed = WhereRenderer.collapsedIdentical(hits)

        // One (name, path, line) recorded by two units — one file compiled into two targets — carries no
        // distinct information and folds with a unit count; a drifted line is genuinely ambiguous
        // multi-target evidence and must stay separate.
        #expect(collapsed.count == 3)
        #expect(collapsed[0].hit.line == 14)
        #expect(collapsed[0].units == 2)
        #expect(collapsed[1].hit.line == 13)
        #expect(collapsed[1].units == 1)
        #expect(collapsed[2].hit.name == "other()")
        #expect(collapsed[2].units == 1)
    }

    @Test
    func twoCallsOnOneLineFromOneBuildAreOneCallSiteNeverTwoUnits() {
        func call(unit: String) -> SemanticStore.Hit {
            SemanticStore.Hit(name: "caller()", path: "/repo/A.swift", line: 14, unit: unit)
        }

        // a.f() + a.f() — two call sites one build recorded on one line: one row, no unit marker.
        let oneBuild = WhereRenderer.collapsedIdentical([call(unit: "App 1"), call(unit: "App 1")])
        #expect(oneBuild.count == 1)
        #expect(oneBuild[0].units == 1)

        // The same call site recorded by two builds — one file compiled into two targets: genuinely ×2.
        let twoBuilds = WhereRenderer.collapsedIdentical([call(unit: "App 1"), call(unit: "Tool 1")])
        #expect(twoBuilds.count == 1)
        #expect(twoBuilds[0].units == 2)

        // A macro's expansion recording three occurrences at one column of one build: one unit, never ×3.
        let expanded = WhereRenderer.collapsedIdentical([call(unit: "App 1"), call(unit: "App 1"), call(unit: "App 1")])
        #expect(expanded.map(\.units) == [1])
    }

    /// Sixteen aliases printed as `16 written as Lib.L1 and Lib.L10 and … and Lib.L9` — 300 characters, twice over, in an answer whose whole point is to be a line.
    @Test
    func aliasSpellingsAreNamedToTheCapAndCountedPastIt() {
        #expect(WhereRenderer.namedSpellings([]).isEmpty)
        #expect(WhereRenderer.namedSpellings(["Lib.Crate"]) == "Lib.Crate")
        #expect(WhereRenderer.namedSpellings(["Lib.Box", "Lib.Crate"]) == "Lib.Box and Lib.Crate")
        #expect(WhereRenderer.namedSpellings(["Lib.Box", "Lib.Crate", "Lib.Depot"]) == "Lib.Box, Lib.Crate and Lib.Depot")

        let many = (1 ... 16).map { "Lib.Alias\($0)" }.sorted()
        let named = WhereRenderer.namedSpellings(many)

        #expect(named == "Lib.Alias1, Lib.Alias10, Lib.Alias11 and 13 more")
        #expect(named.count < 60)
    }
}
