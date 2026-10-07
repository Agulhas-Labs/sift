//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// With a store, a protocol's merged conformers block keeps a row whose clause names another type of the protocol's name when the row also inherits the protocol through another clause: it conforms to both.
@Suite(.temporaryDirectories, .serialized)
struct WhereQualifiedConformerBothTests {
    /// A built package with a nested protocol `Log.Shelf.Answer`, an unrelated class and protocol of the name, a protocol refining the asked one, and inheritors of an unrelated `Answer` that conform through the refinement too — in a class's clause, a struct's, and an extension's.
    private static func fixture() async throws -> SharedBuiltFixture {
        try await SharedBuiltFixtures.process.fixture(for: Self.self, named: "where-qualified-conformer-both") { root in
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

                open class Answer {}

                public enum Dock {
                    public protocol Answer {}
                }

                public protocol Middle: Log.Shelf.Answer {}

                public final class Lantern: Answer, Middle {}

                public struct Buoy: Dock.Answer, Middle {}

                public struct Raft: Middle {}

                extension Raft: Dock.Answer {}

                public final class Stray: Answer {}
                """,
                to: "Sources/GizmoCore/Answer.swift",
                in: root
            )
            try TestSources.commitAll(in: root, message: "conformers of two types of one name")
            try await TestSources.swiftBuildSuspending(packageAt: root)
        }
    }

    /// The asked protocol's block, which leaves out only the unrelated class's subclass.
    private static func answer(sourceLocation: SourceLocation = #_sourceLocation) async throws -> String {
        try await fixture().withEngine { engine in
            let output = try await engine.lookup(symbol: "Log.Shelf.Answer", freshness: engine.ensureFresh())
            #expect(output.contains("1 left out: the index store records its clause as conforming to another \"Answer\"):"), "\(output)", sourceLocation: sourceLocation)
            #expect(!output.contains("Stray"), "\(output)", sourceLocation: sourceLocation)
            return output
        }
    }

    /// A subclass of the unrelated class that conforms through the refining protocol stays listed.
    @Test
    func aSubclassOfTheOtherClassThatAlsoConformsStays() async throws {
        let output = try await Self.answer()

        #expect(output.contains("  GizmoCore.Lantern — class — Sources/GizmoCore/Answer.swift:15 — direct"), "\(output)")
    }

    /// A conformer of the unrelated protocol that conforms through the refining protocol stays listed.
    @Test
    func aConformerOfTheOtherProtocolThatAlsoConformsStays() async throws {
        let output = try await Self.answer()

        #expect(output.contains("  GizmoCore.Buoy — struct — Sources/GizmoCore/Answer.swift:17 — direct"), "\(output)")
    }

    /// An extension conforming to the unrelated protocol stays listed when the type it extends conforms through the refining protocol.
    @Test
    func anExtensionOfATypeThatAlsoConformsStays() async throws {
        let output = try await Self.answer()

        #expect(output.contains("  GizmoCore.Raft — extension — Sources/GizmoCore/Answer.swift:21 — direct"), "\(output)")
    }
}
