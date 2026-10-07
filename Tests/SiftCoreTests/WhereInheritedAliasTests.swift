//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// Pins the inherited-conformer walk through a typealias of a listed or walked class, in both modes, and the store's word on the rows a class's block by written name walks to.
@Suite(.temporaryDirectories, .serialized)
struct WhereInheritedAliasTests {
    /// A built package: a conforming class written through a typealias by its subclass, a nested conforming class written through a qualified typealias beside one naming another owner's class, and a class whose subclasses sit beside a nested class of the subclass's name.
    private static func fixture() async throws -> SharedBuiltFixture {
        try await SharedBuiltFixtures.process.fixture(for: Self.self, named: "where-inherited-alias") { root in
            try TestSources.write(
                """
                // swift-tools-version: 6.0
                import PackageDescription

                let package = Package(
                    name: "Lib",
                    targets: [.target(name: "Lib")]
                )
                """,
                to: "Package.swift",
                in: root
            )
            try TestSources.write(
                """
                public protocol Plain {}
                open class Base: Plain {}
                public typealias Footing = Base
                open class Via: Footing {}
                public final class Under: Via {}
                public enum Holder {
                    open class Inner: Plain {}
                }
                public enum Other {
                    open class Inner {}
                }
                public typealias Seat = Holder.Inner
                public typealias Elsewhere = Other.Inner
                public final class Sitter: Seat {}
                public final class Stranger: Elsewhere {}
                """,
                to: "Sources/Lib/Plain.swift",
                in: root
            )
            try TestSources.write(
                """
                open class Root {}
                open class Stem: Root {}
                open class Twig: Stem {}
                public enum Nest {
                    open class Stem {}
                    open class Wrong: Stem {}
                }
                public final class Wronger: Nest.Wrong {}
                """,
                to: "Sources/Lib/Root.swift",
                in: root
            )
            try TestSources.commitAll(in: root, message: "inherited alias fixture")
            try await TestSources.swiftBuildSuspending(packageAt: root)
        }
    }

    /// The answer for `symbol`, with the store loaded or set aside.
    private static func answer(_ symbol: String, store: Bool) async throws -> String {
        try await fixture().withEngine { engine in
            if store {
                try await engine.awaitSemanticStore()
            }
            return try await engine.lookup(symbol: symbol, freshness: engine.ensureFresh(), options: WhereOptions(includeSemantic: store))
        }
    }

    /// With the store, a subclass written through a typealias of a listed class is listed through the alias, its own subclass after it, and so is one written through an alias qualified by the class's owner, while the store refutes the subclass written through an alias of another owner's class of the name.
    @Test
    func theStoreWalksATypealiasOfAListedClass() async throws {
        let output = try await Self.answer("Plain", store: true)

        #expect(WhereConformersOnceTests.rowsUnder("conformers of Plain (5: 2 direct, 0 indirect, 3 inherited — ", in: output) == [
            "Lib.Base — class — Sources/Lib/Plain.swift:2 — direct",
            "Lib.Holder.Inner — class — Sources/Lib/Plain.swift:7 — direct",
            "Lib.Via — class — Sources/Lib/Plain.swift:4 — inherited through Footing",
            "Lib.Sitter — class — Sources/Lib/Plain.swift:14 — inherited through Seat",
            "Lib.Under — class — Sources/Lib/Plain.swift:5 — inherited through Via",
        ], "\(output)")
    }

    /// Without the store, the same rows are listed through the same aliases, and so is the subclass written through an alias of another owner's class of the name, since only the store can tell the two apart.
    @Test
    func withoutTheStoreATypealiasOfAListedClassIsWalked() async throws {
        let output = try await Self.answer("Plain", store: false)

        #expect(WhereConformersOnceTests.rowsUnder("conformers of Plain (6, by written name, 4 inherited — ", in: output) == [
            "Lib.Base — class — Sources/Lib/Plain.swift:2",
            "Lib.Holder.Inner — class — Sources/Lib/Plain.swift:7",
            "Lib.Via — class — Sources/Lib/Plain.swift:4 — inherited through Footing",
            "Lib.Sitter — class — Sources/Lib/Plain.swift:14 — inherited through Seat",
            "Lib.Stranger — class — Sources/Lib/Plain.swift:15 — inherited through Elsewhere",
            "Lib.Under — class — Sources/Lib/Plain.swift:5 — inherited through Via",
        ], "\(output)")
    }

    /// Without a store, an alias of an alias is walked too, and a cycle of aliases ends.
    @Test
    func aCycleOfAliasesEnds() async throws {
        let source = """
        protocol Plain {}
        class Base: Plain {}
        typealias Footing = Base & Ground
        typealias Ground = Footing
        class Via: Ground {}
        """
        let output = try await WhereQualifiedProtocolNoteTests.answer("Plain", source: source)

        #expect(WhereConformersOnceTests.rowsUnder("conformers of Plain (2, by written name, 1 inherited — ", in: output) == [
            "Sources.Base — class — Sources/Lib/Lib.swift:2",
            "Sources.Via — class — Sources/Lib/Lib.swift:5 — inherited through Ground",
        ], "\(output)")
    }

    /// With the store, a class's store block is captioned as its direct subclasses, and its block by written name leaves out the subclass of a nested class of the walked name, with that row's own subclass, while the true subclass two levels down stays.
    @Test
    func theStoreChecksTheWalkedRowsOfAClassBlock() async throws {
        let output = try await Self.answer("Root", store: true)

        #expect(WhereConformersOnceTests.rowsUnder("conformers of Root (1, direct subclasses from the store):", in: output) == [
            "Sources/Lib/Root.swift (1):",
            "  :2  Stem  | open class Stem: Root {}",
        ], "\(output)")
        #expect(WhereConformersOnceTests.rowsUnder("conformers of Root (2, by written name, 1 inherited — ", in: output) == [
            "Lib.Stem — class — Sources/Lib/Root.swift:2",
            "Lib.Twig — class — Sources/Lib/Root.swift:3 — inherited through Stem",
        ], "\(output)")
        #expect(!output.contains("Wrong"), "\(output)")
    }
}
