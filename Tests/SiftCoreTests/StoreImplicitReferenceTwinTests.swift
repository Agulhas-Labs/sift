//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// Pins that the store's references to a class keep an implicit one it relates to no declaration beside an unrelated reference written in no declaration in the same file, instead of dropping it as a macro expansion's copy of that one.
@Suite(.temporaryDirectories, .serialized)
struct StoreImplicitReferenceTwinTests {
    /// A built package of one module whose one file holds a class, an alias of it, a subclass writing the class and a subclass writing the alias.
    private static func fixture() async throws -> SharedBuiltFixture {
        try await SharedBuiltFixtures.process.fixture(for: Self.self, named: "store-implicit-reference-twin") { root in
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
                class Direct: Base {}
                class Via: Footing {}
                """,
                to: "Sources/Lib/Base.swift",
                in: root
            )
            try TestSources.commitAll(in: root, message: "implicit reference twin fixture")
            try await TestSources.swiftBuildSuspending(packageAt: root)
        }
    }

    /// The class's USR as the compiler spells it for a type of a module: each name behind its length.
    private static var baseUSR: String {
        "s:" + ["Lib", "Base"].map { "\($0.count)\($0)" }.joined() + "C"
    }

    /// The lines of the store's references to the class, read from a store of its own over the fixture's build.
    private static func referenceLines(sourceLocation: SourceLocation = #_sourceLocation) async throws -> [Int] {
        let fixture = try await fixture()
        let cacheRoot = FileManager.default.temporaryDirectory.appendingPathComponent("store-implicit-reference-twin-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: cacheRoot) }
        let discovered = try #require(IndexStoreDiscovery(repoRoot: fixture.root, config: SiftConfig()).discover(), sourceLocation: sourceLocation)
        let cache = try #require(SemanticCache(store: discovered.path, in: cacheRoot), sourceLocation: sourceLocation)
        let store = try SemanticStore(discovered: discovered, repoRoot: fixture.root, newestUnitDate: Date(), cache: cache)
        return store.references(ofUSR: Self.baseUSR).map(\.line).sorted()
    }

    /// The implicit reference to the class at the clause writing its alias is in no declaration, and stays beside the clause writing the class itself, which is in none either.
    @Test
    func anImplicitReferenceInNoDeclarationSurvivesAnUnrelatedOneInItsFile() async throws {
        let lines = try await Self.referenceLines()

        #expect(lines == [2, 3, 4], "\(lines)")
    }
}
