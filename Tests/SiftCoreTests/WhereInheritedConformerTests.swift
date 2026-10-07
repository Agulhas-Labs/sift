//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// Pins the conformers reached through a listed protocol or class: a refining protocol's conformers and a conforming class's subclasses, to any depth, listed with and without a store and marked with the conformer they were reached through.
@Suite(.temporaryDirectories, .serialized)
struct WhereInheritedConformerTests {
    /// A built package of two modules: a protocol refined in the other module, a class conforming to it with two levels of subclasses, and a refined protocol conformed to in its own module.
    private static func fixture() async throws -> SharedBuiltFixture {
        try await SharedBuiltFixtures.process.fixture(for: Self.self, named: "where-inherited-conformers") { root in
            try TestSources.write(
                """
                // swift-tools-version: 6.0
                import PackageDescription

                let package = Package(
                    name: "Lib",
                    targets: [.target(name: "Lib"), .target(name: "App", dependencies: ["Lib"])]
                )
                """,
                to: "Package.swift",
                in: root
            )
            try TestSources.write(
                """
                public protocol Reading {}
                public protocol Ledger {}
                public protocol Tally: Ledger {}
                public struct Same: Tally {}
                open class Base: Reading { public init() {} }
                open class Sub: Base {}
                public final class Leaf: Sub {}
                public struct Direct: Reading {}
                """,
                to: "Sources/Lib/Lib.swift",
                in: root
            )
            try TestSources.write(
                """
                import Lib
                protocol Refined: Lib.Reading {}
                struct Zed: Refined {}
                struct Yan: Lib.Reading {}
                """,
                to: "Sources/App/App.swift",
                in: root
            )
            try TestSources.commitAll(in: root, message: "inherited conformers fixture")
            try await TestSources.swiftBuildSuspending(packageAt: root)
        }
    }

    /// With the store, the one block lists the refining protocol's conformer and both subclasses after the direct rows, each marked with the row it was reached through, and the caption counts them.
    @Test
    func theStoreBlockListsEveryInheritedConformer() async throws {
        try await Self.fixture().withEngine { engine in
            try await engine.awaitSemanticStore()
            let reading = try await engine.lookup(symbol: "Reading", freshness: engine.ensureFresh())
            let ledger = try await engine.lookup(symbol: "Ledger", freshness: engine.ensureFresh())

            #expect(reading.contains("conformers of Reading (7: 4 direct, 0 indirect, 3 inherited — "), "\(reading)")
            #expect(reading.contains("; indirect is from the index store; inherited is reached through a listed protocol or class, so a grep for the name does not find it):"), "\(reading)")
            #expect(WhereConformersOnceTests.rowsUnder("conformers of Reading (", in: reading) == [
                "App.Refined — protocol — Sources/App/App.swift:2 — direct",
                "App.Yan — struct — Sources/App/App.swift:4 — direct",
                "Lib.Base — class — Sources/Lib/Lib.swift:5 — direct",
                "Lib.Direct — struct — Sources/Lib/Lib.swift:8 — direct",
                "App.Zed — struct — Sources/App/App.swift:3 — inherited through Refined",
                "Lib.Sub — class — Sources/Lib/Lib.swift:6 — inherited through Base",
                "Lib.Leaf — class — Sources/Lib/Lib.swift:7 — inherited through Sub",
            ], "\(reading)")
            #expect(reading.contains("4 of them the conformances listed below"), "\(reading)")
            #expect(WhereConformersOnceTests.rowsUnder("conformers of Ledger (", in: ledger) == [
                "Lib.Tally — protocol — Sources/Lib/Lib.swift:3 — direct",
                "Lib.Same — struct — Sources/Lib/Lib.swift:4 — inherited through Tally",
            ], "\(ledger)")
        }
    }

    /// A class's written-name block lists a subclass of its subclass, marked, beside the store's own block.
    @Test
    func aClassListsItsSubclassesSubclass() async throws {
        try await Self.fixture().withEngine { engine in
            try await engine.awaitSemanticStore()
            let output = try await engine.lookup(symbol: "Base", freshness: engine.ensureFresh())

            #expect(WhereConformersOnceTests.rowsUnder("conformers of Base (2, by written name, 1 inherited — inherited is reached through a listed protocol or class, so a grep for the name does not find it):", in: output) == [
                "Lib.Sub — class — Sources/Lib/Lib.swift:6",
                "Lib.Leaf — class — Sources/Lib/Lib.swift:7 — inherited through Sub",
            ], "\(output)")
        }
    }

    /// Without the store, the written-name block lists the same rows, the walked ones last and marked.
    @Test
    func withoutTheStoreTheWrittenNameBlockListsThemToo() async throws {
        try await Self.fixture().withEngine { engine in
            let output = try await engine.lookup(symbol: "Reading", freshness: engine.ensureFresh(), options: WhereOptions(includeSemantic: false))

            #expect(WhereConformersOnceTests.rowsUnder("conformers of Reading (7, by written name, 3 inherited — inherited is reached through a listed protocol or class, so a grep for the name does not find it):", in: output) == [
                "App.Refined — protocol — Sources/App/App.swift:2",
                "App.Yan — struct — Sources/App/App.swift:4",
                "Lib.Base — class — Sources/Lib/Lib.swift:5",
                "Lib.Direct — struct — Sources/Lib/Lib.swift:8",
                "App.Zed — struct — Sources/App/App.swift:3 — inherited through Refined",
                "Lib.Sub — class — Sources/Lib/Lib.swift:6 — inherited through Base",
                "Lib.Leaf — class — Sources/Lib/Lib.swift:7 — inherited through Sub",
            ], "\(output)")
        }
    }

    /// A row the walk reached locates its line for the exact-answer reader, as every other marked conformer row does.
    @Test
    func anInheritedRowIsLocated() {
        let located = ExactAnswer.locations(inWhereAnswer: "  App.Zed — struct — Sources/App/App.swift:3 — inherited through Refined").map { "\($0.path):\($0.line)" }

        #expect(located == ["Sources/App/App.swift:3"])
    }

    /// With no store at all, a cycle of clauses ends, the asked protocol is never listed as its own conformer, and a subclass of a class an extension makes conform is reached through that class.
    @Test
    func aCycleEndsAndAnExtendedClassIsWalked() async throws {
        let source = """
        protocol Alpha: Beta {}
        protocol Beta: Alpha {}
        struct Gamma: Beta {}
        class Plain {}
        extension Plain: Alpha {}
        class Sub: Plain {}
        """
        let output = try await WhereQualifiedProtocolNoteTests.answer("Alpha", source: source)

        #expect(WhereConformersOnceTests.rowsUnder("conformers of Alpha (4, by written name, 2 inherited — ", in: output) == [
            "Sources.Beta — protocol — Sources/Lib/Lib.swift:2",
            "Sources.Plain — extension — Sources/Lib/Lib.swift:5",
            "Sources.Gamma — struct — Sources/Lib/Lib.swift:3 — inherited through Beta",
            "Sources.Sub — class — Sources/Lib/Lib.swift:6 — inherited through Plain",
        ], "\(output)")
    }

    /// Past the cap, the inherited rows are counted in the caption and in the truncation line, never dropped from either.
    @Test
    func inheritedRowsPastTheCapAreCounted() async throws {
        let extra = 5
        let leaves = (0 ..< WhereRenderer.listCap + extra).map { "final class Leaf\($0): Sub {}" }
        let source = (["class Base {}", "class Sub: Base {}"] + leaves).joined(separator: "\n")
        let output = try await WhereQualifiedProtocolNoteTests.answer("Base", source: source)
        let total = WhereRenderer.listCap + extra + 1

        #expect(output.contains("conformers of Base (\(total), by written name, \(total - 1) inherited — "), "\(output)")
        #expect(output.contains("  truncated: \(total - WhereRenderer.listCap) more conformers"), "\(output)")
        #expect(output.contains("Sources.Leaf0 — class — Sources/Lib/Lib.swift:3 — inherited through Sub"), "\(output)")
    }

    /// With no store, an extension that writes generic arguments still walks to the extended class's subclasses.
    @Test
    func aGenericExtensionWalksToTheSubclass() async throws {
        let source = """
        protocol Alpha {}
        class Box<T> {}
        extension Box<Int>: Alpha {}
        class Depot: Box<Int> {}
        """
        let output = try await WhereQualifiedProtocolNoteTests.answer("Alpha", source: source)

        #expect(output.contains("Sources.Depot — class — Sources/Lib/Lib.swift:4 — inherited through Box"), "\(output)")
    }
}
