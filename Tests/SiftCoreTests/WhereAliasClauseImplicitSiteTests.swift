//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// Pins that a clause written through a typealias counts as written through it, however many records the store keeps of its one site: the alias's own, and the implicit one of each name the alias stands for.
@Suite(.temporaryDirectories, .serialized)
struct WhereAliasClauseImplicitSiteTests {
    /// A built package of one module: a class with an alias and an alias of that alias, a subclass alone in its file through each, and a use of the class by its own name.
    private static func fixture() async throws -> SharedBuiltFixture {
        try await SharedBuiltFixtures.process.fixture(for: Self.self, named: "where-alias-clause-implicit-site") { root in
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
                open class Base {}
                public typealias Footing = Base
                public typealias Box = Footing
                """,
                to: "Sources/Lib/Base.swift",
                in: root
            )
            try TestSources.write("open class Via: Footing {}", to: "Sources/Lib/Via.swift", in: root)
            try TestSources.write("open class Deep: Box {}", to: "Sources/Lib/Deep.swift", in: root)
            try TestSources.write("public func make() -> Base { Base() }", to: "Sources/Lib/Use.swift", in: root)
            try TestSources.commitAll(in: root, message: "alias clause implicit site fixture")
            try await TestSources.swiftBuildSuspending(packageAt: root)
        }
    }

    /// The answer for the class, with the store loaded, as a sweep when `sweep` is set.
    private static func answer(sweep: Bool = false) async throws -> String {
        try await fixture().withEngine { engine in
            try await engine.awaitSemanticStore()
            return try await engine.lookup(symbol: "Lib.Base", freshness: engine.ensureFresh(), options: WhereOptions(includeSemantic: true, includeReferences: sweep, standsInForSearch: !sweep))
        }
    }

    /// A subclass alone in its file, written through the class's alias, is a line written as the alias in the class's usage, and no line of the class's own name in its sweep.
    @Test
    func aLoneClauseThroughAnAliasIsWrittenAsTheAlias() async throws {
        let output = try await Self.answer()
        let swept = try await Self.answer(sweep: true)

        #expect(output.contains("  Sources/Lib/Via.swift (1): — written as Lib.Footing\n    :1  | open class Via: Footing {}\n"), "\(output)")
        #expect(WhereConformersOnceTests.fileLines(under: "references to Lib.Base (", in: swept) == [
            "Sources/Lib/Base.swift": [2],
            "Sources/Lib/Use.swift": [1],
        ], "\(swept)")
    }

    /// A subclass written through an alias of an alias is written as the alias its clause spells, not also as the alias that one names.
    @Test
    func aClauseThroughAnAliasOfAnAliasIsWrittenAsTheOuterAlias() async throws {
        let output = try await Self.answer()

        #expect(output.contains("  Sources/Lib/Deep.swift (1): — written as Lib.Box\n    :1  | open class Deep: Box {}\n"), "\(output)")
    }
}
