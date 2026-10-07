//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// Pins which typealiases a class's block by written name lists types through: with the store, only an alias it accepts as standing for the asked class, or one it cannot speak for; with none, every alias of the name, marked with what it writes where that is behind a qualifier.
@Suite(.temporaryDirectories, .serialized)
struct WhereAliasSeedStoreTests {
    /// Writes a package of three modules: a nested class and another module's class sharing the asked class's name, each with a typealias and subclasses written through it, the other module's alias in a file of its own with an alias of it beside its subclasses.
    static func writePackage(in root: URL) throws {
        try TestSources.write(
            """
            // swift-tools-version: 6.0
            import PackageDescription

            let package = Package(
                name: "Lib",
                targets: [.target(name: "Other"), .target(name: "Lib", dependencies: ["Other"]), .target(name: "App", dependencies: ["Lib"])]
            )
            """,
            to: "Package.swift",
            in: root
        )
        try TestSources.write("open class Base {}\nopen class Plain {}\n", to: "Sources/Other/Other.swift", in: root)
        try TestSources.write(
            """
            import Other
            open class Base {}
            public enum NS {
                open class Base {}
            }
            public typealias Nest = NS.Base
            public typealias Ground = Base
            public typealias Footing = Ground
            open class Via: Ground {}
            open class Sitter: Footing {}
            open class Nester: Nest {}
            open class Mid: Base {}
            open class W: NS.Base {}
            public enum E {
                open class Mid: Nest {}
                open class Leaf: Mid {}
            }
            open class Plain {}
            public typealias Outsider = Other.Plain
            open class Tenant: Outsider {}
            """,
            to: "Sources/Lib/Base.swift",
            in: root
        )
        try TestSources.write("import Other\npublic typealias Foreign = Other.Base\n", to: "Sources/Lib/Foreign.swift", in: root)
        try TestSources.write(
            "public typealias Deeper = Foreign\nopen class Visitor: Foreign {}\nopen class Heir: Visitor {}\nopen class Diver: Deeper {}\n",
            to: "Sources/Lib/Subs.swift",
            in: root
        )
        try TestSources.write("import Lib\nclass Guest: Ground {}\n", to: "Sources/App/App.swift", in: root)
    }

    /// The package above, built once for each suite that asks, so no two suites share an engine.
    static func fixture(for suite: Any.Type) async throws -> SharedBuiltFixture {
        try await SharedBuiltFixtures.process.fixture(for: suite, named: "where-alias-seed-store") { root in
            try writePackage(in: root)
            try TestSources.commitAll(in: root, message: "alias seed fixture")
            try await TestSources.swiftBuildSuspending(packageAt: root)
        }
    }

    /// The answer for `symbol` from the package `suite` built, with the store loaded or set aside.
    static func answer(_ symbol: String, store: Bool, suite: Any.Type = Self.self) async throws -> String {
        try await fixture(for: suite).withEngine { engine in
            if store {
                try await engine.awaitSemanticStore()
            }
            return try await engine.lookup(symbol: symbol, freshness: engine.ensureFresh(), options: WhereOptions(includeSemantic: store))
        }
    }

    /// The rows under the block by written name for `name` in `output`.
    static func rows(of name: String, in output: String) -> [String] {
        let lines = output.components(separatedBy: "\n")
        guard let heading = lines.first(where: { $0.hasPrefix("conformers of \(name) (") && $0.contains(", by written name") }) else { return [] }
        return WhereConformersOnceTests.rowsUnder(heading, in: output)
    }

    /// How the rows of the types the store refutes under the top-level class start: each written through another class's alias or an alias of one, or walked from such a type.
    private static var refutedUnderTheTopLevelClass: [String] {
        ["Lib.Nester ", "Lib.E.Mid ", "Lib.E.Leaf ", "Lib.Visitor ", "Lib.Heir ", "Lib.Diver "]
    }

    /// With the store, files unchanged since the build, the top-level class lists the types written through its own aliases, an alias of an alias and another module's included, and none written through an alias of the nested class or the other module's class, or walked from one.
    @Test
    func theStoreLeavesOutTypesWrittenThroughAnotherClassAlias() async throws {
        let output = try await Self.answer("Lib.Base", store: true)
        let rows = Self.rows(of: "Base", in: output)

        for row in [
            "App.Guest — class — Sources/App/App.swift:2 — through typealias Lib.Ground",
            "Lib.Via — class — Sources/Lib/Base.swift:9 — through typealias Lib.Ground",
            "Lib.Sitter — class — Sources/Lib/Base.swift:10 — through typealias Lib.Footing",
        ] {
            #expect(rows.contains(row), "\(row) in \(output)")
        }
        for refuted in Self.refutedUnderTheTopLevelClass {
            #expect(!rows.contains { $0.hasPrefix(refuted) }, "\(refuted) in \(output)")
        }
    }

    /// With the store, the nested class's block by written name lists through a typealias exactly the types its store block does.
    @Test
    func theNestedClassListsOnlyItsOwnAliasRows() async throws {
        let output = try await Self.answer("NS.Base", store: true)

        #expect(Self.rows(of: "Base", in: output).filter { $0.contains("through typealias") } == [
            "Lib.Nester — class — Sources/Lib/Base.swift:11 — through typealias Lib.Nest = NS.Base",
            "Lib.E.Mid — class — Sources/Lib/Base.swift:15 — through typealias Lib.Nest = NS.Base",
        ], "\(output)")
        let storeRows = WhereConformersOnceTests.rowsUnder("conformers of Base (3, direct subclasses from the store):", in: output)
        #expect(storeRows.filter { $0.contains("through typealias") } == [
            "  :11  Nester — through typealias Lib.Nest  | open class Nester: Nest {}",
            "  :15  Mid — through typealias Lib.Nest  | open class Mid: Nest {}",
        ], "\(output)")
    }

    /// Without the store, every type written through an alias of the name is listed, each alias reaching it behind a qualifier marked with what it writes.
    @Test
    func withoutTheStoreEveryAliasIsKeptAndShowsWhatItWrites() async throws {
        let output = try await Self.answer("Lib.Base", store: false)
        let rows = Self.rows(of: "Base", in: output)

        for row in [
            "App.Guest — class — Sources/App/App.swift:2 — through typealias Lib.Ground",
            "Lib.Nester — class — Sources/Lib/Base.swift:11 — through typealias Lib.Nest = NS.Base",
            "Lib.E.Mid — class — Sources/Lib/Base.swift:15 — through typealias Lib.Nest = NS.Base",
            "Lib.Visitor — class — Sources/Lib/Subs.swift:2 — through typealias Lib.Foreign = Other.Base",
            "Lib.Diver — class — Sources/Lib/Subs.swift:4 — through typealias Lib.Deeper",
            "Lib.E.Leaf — class — Sources/Lib/Base.swift:16 — inherited through Mid",
            "Lib.Heir — class — Sources/Lib/Subs.swift:3 — inherited through Visitor",
        ] {
            #expect(rows.contains(row), "\(row) in \(output)")
        }

        let plain = try await Self.answer("Lib.Plain", store: false)

        #expect(Self.rows(of: "Plain", in: plain) == [
            "Lib.Tenant — class — Sources/Lib/Base.swift:20 — through typealias Lib.Outsider = Other.Plain",
        ], "\(plain)")
    }

    /// With the store, once the other module's alias's file changes after the build, the store cannot speak for it, so the types written through it, through an alias of it, and walked from them are listed again.
    @Test
    func theTypesWrittenThroughAnAliasInAChangedFileAreKept() async throws {
        let root = try TestSources.makeTempRepo()
        try Self.writePackage(in: root)
        try TestSources.commitAll(in: root, message: "changed alias fixture")
        try TestSources.swiftBuild(packageAt: root)
        let engine = try SiftEngine(directory: root)
        try await engine.awaitSemanticStore()
        _ = try await engine.ensureFresh()
        try TestSources.write("import Other\npublic typealias Foreign = Other.Base\n\n", to: "Sources/Lib/Foreign.swift", in: root)
        let output = try await engine.lookup(symbol: "Lib.Base", freshness: engine.ensureFresh())
        let rows = Self.rows(of: "Base", in: output)

        for row in [
            "Lib.Visitor — class — Sources/Lib/Subs.swift:2 — through typealias Lib.Foreign = Other.Base",
            "Lib.Diver — class — Sources/Lib/Subs.swift:4 — through typealias Lib.Deeper",
            "Lib.Heir — class — Sources/Lib/Subs.swift:3 — inherited through Visitor",
        ] {
            #expect(rows.contains(row), "\(row) in \(output)")
        }

        #expect(!rows.contains { $0.hasPrefix("Lib.Nester ") }, "\(output)")
    }
}
