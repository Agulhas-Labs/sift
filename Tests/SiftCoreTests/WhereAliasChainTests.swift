//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// Pins that a type written through another module's alias of the asked class's name stays in the class's block by written name where the store records it inheriting from the class all the same, because what that alias names is itself a subclass.
@Suite(.temporaryDirectories, .serialized)
struct WhereAliasChainTests {
    /// Writes a package where the second module's class of the same name subclasses the first's, and each module declares an alias of its own class under one name.
    static func writePackage(in root: URL) throws {
        try TestSources.write(
            """
            // swift-tools-version: 6.0
            import PackageDescription

            let package = Package(
                name: "Lib",
                targets: [.target(name: "Lib"), .target(name: "Other", dependencies: ["Lib"]), .target(name: "App", dependencies: ["Lib", "Other"])]
            )
            """,
            to: "Package.swift",
            in: root
        )
        try TestSources.write("open class Base {}\npublic typealias Footing = Base\nopen class Via: Footing {}\n", to: "Sources/Lib/Base.swift", in: root)
        try TestSources.write("import Lib\nopen class Base: Lib.Base {}\npublic typealias Footing = Base\n", to: "Sources/Other/Base.swift", in: root)
        try TestSources.write("open class Rung: Footing {}\nopen class Leaf: Rung {}\n", to: "Sources/Other/Rung.swift", in: root)
        try TestSources.write("import Lib\nimport Other\nclass Visitor: Other.Footing {}\n", to: "Sources/App/App.swift", in: root)
    }

    /// The package above, built once for this suite.
    static func fixture() async throws -> SharedBuiltFixture {
        try await SharedBuiltFixtures.process.fixture(for: Self.self, named: "where-alias-chain") { root in
            try writePackage(in: root)
            try TestSources.commitAll(in: root, message: "alias chain fixture")
            try await TestSources.swiftBuildSuspending(packageAt: root)
        }
    }

    /// With the store, the types written through the other module's alias, and the one walked from them, are listed under the first module's class, since they inherit from it through the other class.
    @Test
    func theStoreKeepsTypesInheritingThroughTheOtherModuleClass() async throws {
        try await Self.fixture().withEngine { engine in
            try await engine.awaitSemanticStore()
            let output = try await engine.lookup(symbol: "Lib.Base", freshness: engine.ensureFresh(), options: WhereOptions(includeSemantic: true))
            let rows = WhereAliasSeedStoreTests.rows(of: "Base", in: output)

            for row in [
                "Lib.Via — class — Sources/Lib/Base.swift:3 — through typealias Lib.Footing",
                "Other.Rung — class — Sources/Other/Rung.swift:1 — inherited through Footing",
                "App.Visitor — class — Sources/App/App.swift:3 — inherited through Footing",
                "Other.Leaf — class — Sources/Other/Rung.swift:2 — inherited through Rung",
            ] {
                #expect(rows.contains(row), "\(row) in \(output)")
            }
        }
    }
}
