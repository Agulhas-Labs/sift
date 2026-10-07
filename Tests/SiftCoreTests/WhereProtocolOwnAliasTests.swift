//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// Pins the types a protocol's answer lists through the protocol's own typealias, in both modes.
@Suite(.temporaryDirectories, .serialized)
struct WhereProtocolOwnAliasTests {
    /// A built package: a protocol with a conformer writing its name, one writing its typealias, and a refining protocol with a conformer of its own.
    private static func fixture() async throws -> SharedBuiltFixture {
        try await SharedBuiltFixtures.process.fixture(for: Self.self, named: "where-protocol-own-alias") { root in
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
                public protocol Plain {}
                public typealias Footing = Plain
                public struct Under: Footing {}
                public struct Direct: Plain {}
                public protocol Refined: Plain {}
                public struct Leaf: Refined {}
                """,
                to: "Sources/Lib/Plain.swift",
                in: root
            )
            try TestSources.commitAll(in: root, message: "protocol own alias fixture")
            try await TestSources.swiftBuildSuspending(packageAt: root)
        }
    }

    /// The answer for `symbol`, with the store loaded or set aside.
    private static func answer(_ symbol: String, store: Bool) async throws -> String {
        try await fixture().withEngine { engine in
            if store {
                try await engine.awaitSemanticStore()
            }
            return try await engine.lookup(symbol: symbol, freshness: engine.ensureFresh(), options: WhereOptions(includeSemantic: store))
        }
    }

    /// Without the store, the block by written name lists the type written through the protocol's own alias, marked with it, beside the ones writing the name.
    @Test
    func withoutTheStoreTheProtocolOwnAliasIsListed() async throws {
        let output = try await Self.answer("Lib.Plain", store: false)

        let rows = output.split(separator: "\n").map(String.init).filter { $0.contains("Under — struct") }

        #expect(rows == ["  Lib.Under — struct — Sources/Lib/Plain.swift:3 — through typealias Lib.Footing"], "\(output)")
        #expect(output.contains("through a typealias is a clause writing a typealias of it"), "\(output)")
    }

    /// With the store, the type written through the alias appears once in the answer.
    @Test
    func theStoreListsTheProtocolOwnAliasConformerOnce() async throws {
        let output = try await Self.answer("Lib.Plain", store: true)

        let rows = output.split(separator: "\n").map(String.init).filter { $0.contains("Under — struct") }

        #expect(rows.count == 1, "\(output)")
    }
}
