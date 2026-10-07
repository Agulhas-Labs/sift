//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// Pins composition conformers under an index store: each listed once and direct, marked as the store not having it where no target builds the file or a memberless extension carries the composition.
@Suite(.temporaryDirectories, .serialized)
struct WhereCompositionConformerStoreTests {
    /// A built package whose protocols are conformed to only inside compositions, plus one composition conformer outside every target.
    private static func fixture() async throws -> SharedBuiltFixture {
        try await SharedBuiltFixtures.process.fixture(for: Self.self, named: "where-composition-conformers") { root in
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
                public protocol Reading {}
                public protocol Ledger {}
                public struct Three: Reading & Ledger & Sendable {}
                public struct Flip: Ledger & Reading {}
                public struct Plain {}
                extension Plain: Reading & Ledger {}
                """,
                to: "Sources/Lib/Lib.swift",
                in: root
            )
            try TestSources.write("struct Late: Ledger & Reading {}\n", to: "Extras/Late.swift", in: root)
            try TestSources.commitAll(in: root, message: "composition conformers fixture")
            try await TestSources.swiftBuildSuspending(packageAt: root)
        }
    }

    /// Asked for either component, the one block lists each conformer once, those the store relates direct and the unbuilt one and the memberless extension as the store not having it.
    @Test(arguments: ["Reading", "Ledger"])
    func eachConformerIsListedOnceAndMarked(name: String) async throws {
        try await Self.fixture().withEngine { engine in
            let output = try await engine.lookup(symbol: name, freshness: engine.ensureFresh())

            #expect(output.components(separatedBy: "conformers of \(name) (").count == 2, "\(output)")
            #expect(output.contains("conformers of \(name) (4: 4 direct, 0 indirect — "), "\(output)")
            #expect(!output.contains("by written name)"), "\(output)")
            // The compiler names a memberless extension after its one protocol, so one written with a composition gets no
            // extension record and no relation to either protocol: the store holds no conformance for it.
            #expect(WhereConformersOnceTests.rowsUnder("conformers of \(name) (", in: output) == [
                "Extras.Late — struct — Extras/Late.swift:1 — direct; the index store does not have it",
                "Lib.Three — struct — Sources/Lib/Lib.swift:3 — direct",
                "Lib.Flip — struct — Sources/Lib/Lib.swift:4 — direct",
                "Lib.Plain — extension — Sources/Lib/Lib.swift:6 — direct; the index store does not have it",
            ], "\(output)")
        }
    }

    /// Without the store, the written-name block lists the same four.
    @Test
    func withoutTheStoreTheWrittenNameBlockListsThemAll() async throws {
        try await Self.fixture().withEngine { engine in
            let output = try await engine.lookup(symbol: "Reading", freshness: engine.ensureFresh(), options: WhereOptions(includeSemantic: false))

            #expect(WhereConformersOnceTests.rowsUnder("conformers of Reading (4, by written name):", in: output) == [
                "Extras.Late — struct — Extras/Late.swift:1",
                "Lib.Three — struct — Sources/Lib/Lib.swift:3",
                "Lib.Flip — struct — Sources/Lib/Lib.swift:4",
                "Lib.Plain — extension — Sources/Lib/Lib.swift:6",
            ], "\(output)")
        }
    }
}
