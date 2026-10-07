//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// Pins that the store's rows of a class's subclasses keep one written through the class's own alias beside a clause in the same file that writes the class, instead of dropping it as a macro expansion's copy of that clause.
@Suite(.temporaryDirectories, .serialized)
struct StoreImplicitTwinContainerTests {
    /// A built package of one module whose one file holds a class, an alias of it, a subclass writing the class and a subclass writing the alias.
    private static func fixture() async throws -> SharedBuiltFixture {
        try await SharedBuiltFixtures.process.fixture(for: Self.self, named: "store-implicit-twin-container") { root in
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
            try TestSources.commitAll(in: root, message: "implicit twin container fixture")
            try await TestSources.swiftBuildSuspending(packageAt: root)
        }
    }

    /// The class's USR as the compiler spells it for a type of a module: each name behind its length.
    private static var baseUSR: String {
        "s:" + ["Lib", "Base"].map { "\($0.count)\($0)" }.joined() + "C"
    }

    /// The names the store's subclass rows of the class carry, read from a store of its own over the fixture's build.
    private static func subclasses(sourceLocation: SourceLocation = #_sourceLocation) async throws -> [String] {
        let fixture = try await fixture()
        let cacheRoot = FileManager.default.temporaryDirectory.appendingPathComponent("store-implicit-twin-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: cacheRoot) }
        let discovered = try #require(IndexStoreDiscovery(repoRoot: fixture.root, config: SiftConfig()).discover(), sourceLocation: sourceLocation)
        let cache = try #require(SemanticCache(store: discovered.path, in: cacheRoot), sourceLocation: sourceLocation)
        let store = try SemanticStore(discovered: discovered, newestUnitDate: Date(), cache: cache)
        return store.semanticConformers(ofUSR: Self.baseUSR).map(\.name).sorted()
    }

    /// A subclass written through the class's own alias is recorded on the class as an implicit occurrence in no declaration, and stays beside a clause in the same file writing the class itself.
    @Test
    func aSubclassWrittenThroughTheClassOwnAliasSurvivesADirectClauseInItsFile() async throws {
        let names = try await Self.subclasses()

        #expect(names == ["Direct", "Via"], "\(names)")
    }
}
