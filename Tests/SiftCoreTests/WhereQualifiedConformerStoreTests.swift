//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// With a store, a protocol's merged conformers block leaves out a row the store records as conforming to another protocol of the same name, and counts it in the heading.
@Suite(.temporaryDirectories, .serialized)
struct WhereQualifiedConformerStoreTests {
    /// Writes a package declaring a nested `Log.Shelf.Answer` and a top-level `Answer`, with conformers of each and one of both, into `root`.
    private static func writePackage(in root: URL) throws {
        try TestSources.write(
            """
            // swift-tools-version: 6.0
            import PackageDescription

            let package = Package(
                name: "Gizmo",
                targets: [.target(name: "GizmoCore")]
            )
            """,
            to: "Package.swift",
            in: root
        )
        try TestSources.write(
            """
            public enum Log {
                public enum Shelf {
                    public protocol Answer {}
                }
            }

            public protocol Answer {}

            public struct Orchard: Log.Shelf.Answer {}

            extension Log.Shelf {
                public struct Lamp: Answer {}
            }

            public struct Crate {}

            extension Crate: Log.Shelf.Answer {}

            public struct Both: Log.Shelf.Answer, Answer {}
            """,
            to: "Sources/GizmoCore/Answer.swift",
            in: root
        )
        try TestSources.write("public struct Catalogue: Answer {}\n", to: "Sources/GizmoCore/Catalogue.swift", in: root)
    }

    /// The package above, built once for the suite.
    private static func fixture() async throws -> SharedBuiltFixture {
        try await SharedBuiltFixtures.process.fixture(for: Self.self, named: "where-qualified-conformer-store") { root in
            try writePackage(in: root)
            try TestSources.commitAll(in: root, message: "two protocols of one name")
            try await TestSources.swiftBuildSuspending(packageAt: root)
        }
    }

    /// The nested protocol lists its own conformers and the one of both, and leaves out the top-level protocol's.
    @Test
    func theNestedProtocolLeavesOutTheOtherProtocolsConformer() async throws {
        try await Self.fixture().withEngine { engine in
            let output = try await engine.lookup(symbol: "Log.Shelf.Answer", freshness: engine.ensureFresh())

            #expect(output.contains("conformers of Answer (4: 4 direct, 0 indirect — direct is every inheritance clause in this tree's source that writes the name, so a grep for the name finds the same lines; a typealias to it is not followed; indirect is from the index store, 1 left out: the index store records its clause as conforming to another \"Answer\"):"), "\(output)")
            #expect(output.contains("  GizmoCore.Orchard — struct — Sources/GizmoCore/Answer.swift:9 — direct\n"), "\(output)")
            #expect(output.contains("  GizmoCore.Log.Shelf.Lamp — struct — Sources/GizmoCore/Answer.swift:12 — direct\n"), "\(output)")
            #expect(output.contains("  GizmoCore.Crate — extension — Sources/GizmoCore/Answer.swift:17 — direct\n"), "\(output)")
            #expect(output.contains("  GizmoCore.Both — struct — Sources/GizmoCore/Answer.swift:19 — direct"), "\(output)")
            #expect(output.contains("4 references in 1 file, 4 of them the conformances listed below"), "\(output)")
            #expect(!output.contains("Catalogue"), "\(output)")
            #expect(!output.contains("does not have it"), "\(output)")
        }
    }

    /// The top-level protocol lists its own conformer and the one of both, and leaves out the nested protocol's three.
    @Test
    func theTopLevelProtocolLeavesOutTheNestedProtocolsConformers() async throws {
        try await Self.fixture().withEngine { engine in
            let output = try await engine.lookup(symbol: "GizmoCore.Answer", freshness: engine.ensureFresh())

            #expect(output.contains("conformers of Answer (2: 2 direct, 0 indirect — direct is every inheritance clause in this tree's source that writes the name, so a grep for the name finds the same lines; a typealias to it is not followed; indirect is from the index store, 3 left out: the index store records their clauses as conforming to another \"Answer\"):"), "\(output)")
            #expect(output.contains("  GizmoCore.Catalogue — struct — Sources/GizmoCore/Catalogue.swift:1 — direct"), "\(output)")
            #expect(output.contains("  GizmoCore.Both — struct — Sources/GizmoCore/Answer.swift:19 — direct"), "\(output)")
            #expect(output.contains("2 references in 2 files, 2 of them the conformances listed below"), "\(output)")
            #expect(!output.contains("Orchard"), "\(output)")
            #expect(!output.contains("Lamp"), "\(output)")
            #expect(!output.contains("GizmoCore.Crate"), "\(output)")
            #expect(!output.contains("does not have it"), "\(output)")
        }
    }

    /// A row in a file edited since the build stays listed, since the store's record no longer speaks for its clause.
    @Test
    func aRowInAFileEditedSinceTheBuildStays() async throws {
        let root = try TestSources.makeTempRepo()
        try Self.writePackage(in: root)
        try TestSources.commitAll(in: root, message: "two protocols of one name, edited after the build")
        try await TestSources.swiftBuildSuspending(packageAt: root)
        let engine = try SiftEngine(directory: root)
        try await engine.awaitSemanticStore()
        _ = try await engine.ensureFresh()
        try TestSources.write("public struct Catalogue: Answer {}\n\npublic struct Spare {}\n", to: "Sources/GizmoCore/Catalogue.swift", in: root)

        let output = try await engine.lookup(symbol: "Log.Shelf.Answer", freshness: engine.ensureFresh())

        #expect(output.contains("  GizmoCore.Catalogue — struct — Sources/GizmoCore/Catalogue.swift:1 — direct; the index store does not have it"), "\(output)")
        #expect(!output.contains("left out"), "\(output)")
    }

    /// A conformer the store records against a same-named protocol whose declaring file was deleted since the build now conforms to the other one, so it stays.
    @Test
    func aConformerOfAProtocolWhoseFileWasDeletedStays() async throws {
        let root = try TestSources.makeTempRepo()
        try TestSources.write(
            """
            // swift-tools-version: 6.0
            import PackageDescription

            let package = Package(
                name: "Gizmo",
                targets: [.target(name: "Log"), .target(name: "GizmoCore", dependencies: ["Log"])]
            )
            """,
            to: "Package.swift",
            in: root
        )
        try TestSources.write("public protocol Answer {}\n", to: "Sources/Log/Answer.swift", in: root)
        try TestSources.write("protocol Answer {}\n", to: "Sources/GizmoCore/Answer.swift", in: root)
        try TestSources.write("import Log\n\nstruct Spare: Answer {}\n", to: "Sources/GizmoCore/Spare.swift", in: root)
        try TestSources.commitAll(in: root, message: "two protocols of one name in two modules")
        try await TestSources.swiftBuildSuspending(packageAt: root)
        let engine = try SiftEngine(directory: root)
        try await engine.awaitSemanticStore()
        _ = try await engine.ensureFresh()
        try FileManager.default.removeItem(at: root.appendingPathComponent("Sources/GizmoCore/Answer.swift"))

        let output = try await engine.lookup(symbol: "Log.Answer", freshness: engine.ensureFresh())

        #expect(output.contains("GizmoCore.Spare"), "\(output)")
        #expect(!output.contains("left out"), "\(output)")
    }
}
