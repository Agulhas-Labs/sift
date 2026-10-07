//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// A type the tree only extends, asked of `where` with a built index store: its extension is listed and the lines writing the extended name stand in for its uses, as they do with no store.
@Suite(.temporaryDirectories, .serialized)
struct WhereExtensionOnlyStoreTests {
    private static func fixture() async throws -> SharedBuiltFixture {
        try await SharedBuiltFixtures.process.fixture(for: Self.self, named: "where-extension-only-store") { root in
            try TestSources.write(
                """
                // swift-tools-version: 6.0
                import PackageDescription

                let package = Package(
                    name: "Lib",
                    targets: [.target(name: "Lib")]
                )
                """,
                to: "Package.swift",
                in: root
            )
            try TestSources.write(
                """
                import Foundation

                extension JSONDecoder {
                    func tuned() {}
                }

                typealias Dec = JSONDecoder

                func use() {
                    _ = Dec()
                    JSONDecoder().tuned()
                }
                """,
                to: "Sources/Lib/Ext.swift",
                in: root
            )
            try TestSources.commitAll(in: root, message: "extension-only store fixture")
            try await TestSources.swiftBuildSuspending(packageAt: root)
        }
    }

    /// The uses of a type the tree only extends are listed beside its extension, though the store refused no row.
    @Test
    func anExtensionOnlyTypeListsItsUsesWithAStore() async throws {
        try await Self.fixture().withEngine { engine in
            let output = try await engine.lookup(symbol: "JSONDecoder", freshness: engine.ensureFresh(), options: WhereOptions(includeReferences: true))

            #expect(output.contains("declarations (1):"), "\(output)")
            #expect(output.contains("JSONDecoder().tuned()"), "\(output)")
            #expect(output.contains("_ = Dec()"), "\(output)")
        }
    }
}
