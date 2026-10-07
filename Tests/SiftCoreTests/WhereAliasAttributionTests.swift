//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// Pins which typealias a class's block by written name lists a type through where two modules each declare a class and an alias of the same names: with the store, only the alias the store records the type's own clause writing, or any of the name where it cannot speak for the type; with none, every type written through either.
@Suite(.temporaryDirectories, .serialized)
struct WhereAliasAttributionTests {
    /// Writes a package of three modules: two declaring a class and an alias of it under the same names, one of them with a subclass written through its alias and a subclass of that in a file of their own, and an app writing each module's alias behind its module's name.
    static func writePackage(in root: URL) throws {
        try TestSources.write(
            """
            // swift-tools-version: 6.0
            import PackageDescription

            let package = Package(
                name: "Lib",
                targets: [.target(name: "Other"), .target(name: "Lib"), .target(name: "App", dependencies: ["Lib", "Other"])]
            )
            """,
            to: "Package.swift",
            in: root
        )
        try TestSources.write("open class Base {}\npublic typealias Footing = Base\n", to: "Sources/Other/Base.swift", in: root)
        try TestSources.write("open class Rung: Footing {}\nopen class Leaf: Rung {}\n", to: "Sources/Other/Rung.swift", in: root)
        try TestSources.write("open class Base {}\npublic typealias Footing = Base\nopen class Via: Footing {}\n", to: "Sources/Lib/Base.swift", in: root)
        try TestSources.write("import Lib\nimport Other\nclass Guest: Lib.Footing {}\nclass Visitor: Other.Footing {}\n", to: "Sources/App/App.swift", in: root)
    }

    /// The package above, built once for this suite.
    static func fixture() async throws -> SharedBuiltFixture {
        try await SharedBuiltFixtures.process.fixture(for: Self.self, named: "where-alias-attribution") { root in
            try writePackage(in: root)
            try TestSources.commitAll(in: root, message: "alias attribution fixture")
            try await TestSources.swiftBuildSuspending(packageAt: root)
        }
    }

    /// The rows under the block by written name for the class `Base` in the answer for `symbol`, with the store loaded or set aside.
    static func rows(_ symbol: String, store: Bool) async throws -> (rows: [String], output: String) {
        try await fixture().withEngine { engine in
            if store {
                try await engine.awaitSemanticStore()
            }
            let output = try await engine.lookup(symbol: symbol, freshness: engine.ensureFresh(), options: WhereOptions(includeSemantic: store))
            return (WhereAliasSeedStoreTests.rows(of: "Base", in: output), output)
        }
    }

    /// With the store, files unchanged since the build, the class lists the types whose clause writes its own alias, marked with it, and none written through the other module's alias of the same name, or walked from one.
    @Test
    func theStoreListsOnlyTypesWritingTheClassOwnAlias() async throws {
        let (rows, output) = try await Self.rows("Lib.Base", store: true)

        for row in [
            "Lib.Via — class — Sources/Lib/Base.swift:3 — through typealias Lib.Footing",
            "App.Guest — class — Sources/App/App.swift:3 — through typealias Lib.Footing",
        ] {
            #expect(rows.contains(row), "\(row) in \(output)")
        }
        for refuted in ["Other.Rung ", "Other.Leaf ", "App.Visitor "] {
            #expect(!rows.contains { $0.hasPrefix(refuted) }, "\(refuted) in \(output)")
        }
    }

    /// With the store, the other module's class lists the mirror: its own alias's types and the one walked from them, and none written through the first module's alias.
    @Test
    func theOtherClassListsOnlyItsOwnAliasRows() async throws {
        let (rows, output) = try await Self.rows("Other.Base", store: true)

        for row in [
            "Other.Rung — class — Sources/Other/Rung.swift:1 — through typealias Other.Footing",
            "App.Visitor — class — Sources/App/App.swift:4 — through typealias Other.Footing",
            "Other.Leaf — class — Sources/Other/Rung.swift:2 — inherited through Rung",
        ] {
            #expect(rows.contains(row), "\(row) in \(output)")
        }
        for refuted in ["Lib.Via ", "App.Guest "] {
            #expect(!rows.contains { $0.hasPrefix(refuted) }, "\(refuted) in \(output)")
        }
    }

    /// Without the store, every type written through an alias of the name is listed, and so is the one walked from them.
    @Test
    func withoutTheStoreEveryTypeWritingTheAliasNameIsKept() async throws {
        let (rows, output) = try await Self.rows("Lib.Base", store: false)

        for kept in ["Lib.Via ", "App.Guest ", "Other.Rung ", "App.Visitor ", "Other.Leaf "] {
            #expect(rows.contains { $0.hasPrefix(kept) }, "\(kept) in \(output)")
        }
    }

    /// With the store, once the file of the subclass written through the other module's alias changes after the build, the store cannot speak for it, so it is listed again, with the type walked from it.
    @Test
    func aTypeInAChangedFileIsKept() async throws {
        let (rows, output) = try await Self.rowsWithTheSubclassFileChanged()

        for kept in ["Other.Rung ", "Other.Leaf ", "Lib.Via ", "App.Guest "] {
            #expect(rows.contains { $0.hasPrefix(kept) }, "\(kept) in \(output)")
        }
    }

    /// With the store, a changed file speaks only for its own types: one written through the other module's alias in a file unchanged since the build stays out.
    @Test
    func aChangedFileKeepsOnlyItsOwnTypes() async throws {
        let (rows, output) = try await Self.rowsWithTheSubclassFileChanged()

        #expect(!rows.contains { $0.hasPrefix("App.Visitor ") }, "\(output)")
    }

    /// The rows under the block by written name for the class `Base` in the store-mode answer for `Lib.Base` from a fresh build of the package, its other module's subclass file changed after the build.
    static func rowsWithTheSubclassFileChanged() async throws -> (rows: [String], output: String) {
        let root = try TestSources.makeTempRepo()
        try writePackage(in: root)
        try TestSources.commitAll(in: root, message: "changed attribution fixture")
        try TestSources.swiftBuild(packageAt: root)
        let engine = try SiftEngine(directory: root)
        try await engine.awaitSemanticStore()
        _ = try await engine.ensureFresh()
        try TestSources.write("open class Rung: Footing {}\nopen class Leaf: Rung {}\n\n", to: "Sources/Other/Rung.swift", in: root)
        let output = try await engine.lookup(symbol: "Lib.Base", freshness: engine.ensureFresh())
        return (WhereAliasSeedStoreTests.rows(of: "Base", in: output), output)
    }
}
