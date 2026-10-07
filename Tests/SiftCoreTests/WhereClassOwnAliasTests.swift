//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// Pins the subclasses a class's answer lists through the class's own typealiases, in the store's block and the block by written name, in both modes.
@Suite(.temporaryDirectories, .serialized)
struct WhereClassOwnAliasTests {
    /// A built package of two modules: a class with one subclass writing its name, one writing its typealias, with a subclass of its own, one writing an alias of that alias, and one in the importing module writing a qualified alias of it.
    private static func fixture() async throws -> SharedBuiltFixture {
        try await SharedBuiltFixtures.process.fixture(for: Self.self, named: "where-class-own-alias") { root in
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
                open class Base {}
                public typealias Footing = Base
                open class Direct: Base {}
                open class Via: Footing {}
                open class Under: Via {}
                public typealias Ground = Footing
                open class Sitter: Ground {}
                """,
                to: "Sources/Lib/Base.swift",
                in: root
            )
            try TestSources.write(
                """
                import Lib
                public typealias Seat = Lib.Base
                open class Stranger: Seat {}
                """,
                to: "Sources/App/Seat.swift",
                in: root
            )
            try TestSources.commitAll(in: root, message: "class own alias fixture")
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

    /// The rows of the block by written name, the same in both modes: the subclass writing the name, then each subclass written through one of the class's own aliases, marked with it, then the subclass walked from one of those.
    private static var writtenNameRows: [String] {
        [
            "Lib.Direct — class — Sources/Lib/Base.swift:3",
            "App.Stranger — class — Sources/App/Seat.swift:3 — through typealias App.Seat = Lib.Base",
            "Lib.Via — class — Sources/Lib/Base.swift:4 — through typealias Lib.Footing",
            "Lib.Sitter — class — Sources/Lib/Base.swift:7 — through typealias Lib.Ground",
            "Lib.Under — class — Sources/Lib/Base.swift:5 — inherited through Via",
        ]
    }

    /// With the store, the class's block of direct subclasses also lists the ones written through its own aliases, an alias of an alias included, each marked with the alias, and its block by written name lists them too, with the subclass walked from one of them.
    @Test
    func theStoreListsTheSubclassesWrittenThroughTheClassOwnAlias() async throws {
        let output = try await Self.answer("Lib.Base", store: true)

        #expect(WhereConformersOnceTests.rowsUnder("conformers of Base (4, direct subclasses from the store):", in: output) == [
            "Sources/App/Seat.swift (1):",
            "  :3  Stranger — through typealias App.Seat  | open class Stranger: Seat {}",
            "Sources/Lib/Base.swift (3):",
            "  :3  Direct  | open class Direct: Base {}",
            "  :4  Via — through typealias Lib.Footing  | open class Via: Footing {}",
            "  :7  Sitter — through typealias Lib.Ground  | open class Sitter: Ground {}",
        ], "\(output)")
        #expect(WhereConformersOnceTests.rowsUnder("conformers of Base (5, by written name, 3 through a typealias, 1 inherited — ", in: output) == Self.writtenNameRows, "\(output)")
    }

    /// Without the store, the block by written name lists the same rows, the subclass in the importing module included.
    @Test
    func withoutTheStoreTheClassOwnAliasIsWalked() async throws {
        let output = try await Self.answer("Lib.Base", store: false)

        #expect(WhereConformersOnceTests.rowsUnder("conformers of Base (5, by written name, 3 through a typealias, 1 inherited — ", in: output) == Self.writtenNameRows, "\(output)")
    }

    /// A class whose only subclass writes an alias in a cycle of aliases gets a block of its own, and the walk of the cycle ends.
    @Test
    func aClassWithOnlyAliasSubclassesInACycleIsListed() async throws {
        let source = """
        class Base {}
        typealias Footing = Base & Ground
        typealias Ground = Footing
        class Via: Ground {}
        """
        let output = try await WhereQualifiedProtocolNoteTests.answer("Base", source: source)

        #expect(WhereConformersOnceTests.rowsUnder("conformers of Base (1, by written name, 1 through a typealias — ", in: output) == [
            "Sources.Via — class — Sources/Lib/Lib.swift:4 — through typealias Sources.Ground",
        ], "\(output)")
    }
}
