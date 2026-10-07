//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// Pins which typealias a class's block by written name marks a type through, with no index store, where two modules each declare a class and an alias of the same names: the alias the type's clause writes behind its module's name, or, written bare, the one declared in the type's own module.
@Suite(.temporaryDirectories)
struct WhereAliasMarkSourceTests {
    /// The rows under the block by written name for the class `Base` in the answer for `symbol`, from a package of two modules each declaring a class and an alias of it under the same names with a subclass written through its own alias, and an app writing each module's alias behind its module's name.
    private static func rows(_ symbol: String) async throws -> (rows: [String], output: String) {
        let root = try TestSources.makeTempRepo()
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
        try TestSources.write("open class Base {}\npublic typealias Footing = Base\nopen class Rung: Footing {}\n", to: "Sources/Other/Base.swift", in: root)
        try TestSources.write("open class Base {}\npublic typealias Footing = Base\nopen class Via: Footing {}\n", to: "Sources/Lib/Base.swift", in: root)
        try TestSources.write("import Lib\nimport Other\nclass Guest: Lib.Footing {}\nclass Visitor: Other.Footing {}\n", to: "Sources/App/App.swift", in: root)
        try TestSources.commitAll(in: root, message: "alias mark fixture")
        let engine = try SiftEngine(directory: root)
        let output = try await engine.lookup(symbol: symbol, freshness: engine.ensureFresh())
        return (WhereAliasSeedStoreTests.rows(of: "Base", in: output), output)
    }

    /// Each type is marked with the alias its own source settles, whichever module's class is asked: the alias written behind a module's name, or the bare name's own module's alias.
    @Test(arguments: ["Lib.Base", "Other.Base"])
    func eachTypeIsMarkedWithTheAliasItsSourceWrites(symbol: String) async throws {
        let (rows, output) = try await Self.rows(symbol)

        #expect(rows.sorted() == [
            "App.Guest — class — Sources/App/App.swift:3 — through typealias Lib.Footing",
            "App.Visitor — class — Sources/App/App.swift:4 — through typealias Other.Footing",
            "Lib.Via — class — Sources/Lib/Base.swift:3 — through typealias Lib.Footing",
            "Other.Rung — class — Sources/Other/Base.swift:3 — through typealias Other.Footing",
        ], "\(output)")
    }
}
