//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// Pins which typealias a class's block by written name marks a type through, with the index store loaded, where the store cannot speak for the type: two modules each declare an alias of one class under the same name, and the types sit in an inactive `#if` branch, which the build never compiled, so the store records no clause of theirs.
@Suite(.temporaryDirectories, .serialized)
struct WhereAliasMarkUnspokenStoreTests {
    /// A built package of two modules: a library declaring a class, an alias `Footing` of it and a subclass written through the alias, and an app declaring an alias `Footing` of it too, with a subclass writing each alias, and, in an inactive `#if` branch, one writing the app's alias bare and one writing the library's behind its module's name.
    private static func fixture() async throws -> SharedBuiltFixture {
        try await SharedBuiltFixtures.process.fixture(for: Self.self, named: "where-alias-mark-unspoken-store") { root in
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
            try TestSources.write("open class Base {}\npublic typealias Footing = Base\nopen class Via: Footing {}\n", to: "Sources/Lib/Base.swift", in: root)
            try TestSources.write(
                """
                import Lib
                public typealias Footing = Lib.Base
                class Local: Footing {}
                class Guest: Lib.Footing {}
                #if INACTIVE
                class Depot: Footing {}
                class Orchard: Lib.Footing {}
                #endif
                """,
                to: "Sources/App/App.swift",
                in: root
            )
            try TestSources.commitAll(in: root, message: "alias mark unspoken fixture")
            try await TestSources.swiftBuildSuspending(packageAt: root)
        }
    }

    /// The rows under the class's block by written name in the store-mode answer for `Lib.Base`, and the answer.
    private static func answer() async throws -> (rows: [String], output: String) {
        try await fixture().withEngine { engine in
            try await engine.awaitSemanticStore()
            let output = try await engine.lookup(symbol: "Lib.Base", freshness: engine.ensureFresh(), options: WhereOptions(includeSemantic: true))
            return (WhereAliasSeedStoreTests.rows(of: "Base", in: output), output)
        }
    }

    /// A type in an inactive branch is marked with the alias its source writes: the app's, written bare there, and the library's, written behind its module's name; the types the store speaks for keep the alias it records.
    @Test
    func aTypeTheStoreCannotSpeakForIsMarkedWithTheAliasItsSourceSettles() async throws {
        let (rows, output) = try await Self.answer()

        #expect(rows.sorted() == [
            "App.Depot — class — Sources/App/App.swift:6 — through typealias App.Footing = Lib.Base",
            "App.Guest — class — Sources/App/App.swift:4 — through typealias Lib.Footing",
            "App.Local — class — Sources/App/App.swift:3 — through typealias App.Footing = Lib.Base",
            "App.Orchard — class — Sources/App/App.swift:7 — through typealias Lib.Footing",
            "Lib.Via — class — Sources/Lib/Base.swift:3 — through typealias Lib.Footing",
        ], "\(output)")
    }
}
