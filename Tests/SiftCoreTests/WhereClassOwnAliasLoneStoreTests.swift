//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// Pins the store's block of a class's direct subclasses marking a subclass written through the class's own typealias even where its file holds no clause writing the class itself.
@Suite(.temporaryDirectories, .serialized)
struct WhereClassOwnAliasLoneStoreTests {
    /// A built package of two modules: a class and its alias, one subclass writing the class and each subclass writing an alias of it alone in a file of its own, in the declaring module and in the importing one.
    private static func fixture() async throws -> SharedBuiltFixture {
        try await SharedBuiltFixtures.process.fixture(for: Self.self, named: "where-class-own-alias-lone") { root in
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
                """,
                to: "Sources/Lib/Base.swift",
                in: root
            )
            try TestSources.write("open class Direct: Base {}", to: "Sources/Lib/Direct.swift", in: root)
            try TestSources.write("open class Via: Footing {}", to: "Sources/Lib/Via.swift", in: root)
            try TestSources.write(
                """
                import Lib
                public typealias Seat = Lib.Base
                open class Stranger: Seat {}
                """,
                to: "Sources/App/Seat.swift",
                in: root
            )
            try TestSources.commitAll(in: root, message: "class own alias lone fixture")
            try await TestSources.swiftBuildSuspending(packageAt: root)
        }
    }

    /// The answer for `symbol`, with the store loaded.
    private static func answer(_ symbol: String) async throws -> String {
        try await fixture().withEngine { engine in
            try await engine.awaitSemanticStore()
            return try await engine.lookup(symbol: symbol, freshness: engine.ensureFresh(), options: WhereOptions(includeSemantic: true))
        }
    }

    /// The answer for `Lib.Plain` in the protocol package, with the store loaded.
    private static func protocolAnswer() async throws -> String {
        let fixture = try await SharedBuiltFixtures.process.fixture(for: Self.self, named: "where-protocol-own-alias-lone") { root in
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
                public protocol Plain {}
                public typealias Footing = Plain
                """,
                to: "Sources/Lib/Plain.swift",
                in: root
            )
            try TestSources.write("public struct Direct: Plain {}", to: "Sources/Lib/Direct.swift", in: root)
            try TestSources.write("public struct Under: Footing {}", to: "Sources/Lib/Under.swift", in: root)
            try TestSources.commitAll(in: root, message: "protocol own alias lone fixture")
            try await TestSources.swiftBuildSuspending(packageAt: root)
        }
        return try await fixture.withEngine { engine in
            try await engine.awaitSemanticStore()
            return try await engine.lookup(symbol: "Lib.Plain", freshness: engine.ensureFresh(), options: WhereOptions(includeSemantic: true))
        }
    }

    /// With the store, the class's block of direct subclasses marks a subclass alone in its file, written through the class's own alias in its own module or the importing one, with the alias, and leaves the one writing the class unmarked; the same three rows, in the same order, as the block by written name lists.
    @Test
    func aLoneSubclassWrittenThroughTheClassOwnAliasIsMarkedInTheStoreBlock() async throws {
        let output = try await Self.answer("Lib.Base")

        #expect(WhereConformersOnceTests.rowsUnder("conformers of Base (3, direct subclasses from the store):", in: output) == [
            "Sources/App/Seat.swift (1):",
            "  :3  Stranger — through typealias App.Seat  | open class Stranger: Seat {}",
            "Sources/Lib/Direct.swift (1):",
            "  :1  Direct  | open class Direct: Base {}",
            "Sources/Lib/Via.swift (1):",
            "  :1  Via — through typealias Lib.Footing  | open class Via: Footing {}",
        ], "\(output)")
    }

    /// With the store, a protocol's one block marks a type alone in its file, written through the protocol's own alias, and leaves the one writing the protocol marked direct.
    @Test
    func aLoneConformerWrittenThroughTheProtocolOwnAliasIsMarked() async throws {
        let output = try await Self.protocolAnswer()

        #expect(WhereConformersOnceTests.rowsUnder("conformers of Plain (2: 1 direct, 0 indirect, 1 through a typealias — ", in: output) == [
            "Lib.Direct — struct — Sources/Lib/Direct.swift:1 — direct",
            "Lib.Under — struct — Sources/Lib/Under.swift:1 — through typealias Lib.Footing",
        ], "\(output)")
    }
}
