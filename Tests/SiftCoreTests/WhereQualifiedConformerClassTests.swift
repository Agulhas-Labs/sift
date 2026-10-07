//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// With a store, a protocol's merged conformers block leaves out a subclass of a class sharing the protocol's name, and keeps a conformer of a type of that name which itself inherits from the protocol.
@Suite(.temporaryDirectories, .serialized)
struct WhereQualifiedConformerClassTests {
    /// A built package with a nested protocol `Log.Shelf.Answer`, an unrelated class `Answer` with a subclass, and four types named `Answer` that inherit from the protocol — a class, a refining protocol, a class conforming in an extension, a protocol refining it through another — each with an inheritor.
    private static func fixture() async throws -> SharedBuiltFixture {
        try await SharedBuiltFixtures.process.fixture(for: Self.self, named: "where-qualified-conformer-class") { root in
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

                public struct Orchard: Log.Shelf.Answer {}

                public final class Lantern: Answer {}

                public enum Kiln {
                    open class Answer: Log.Shelf.Answer {}

                    public final class Ember: Answer {}

                    public protocol Reply: Log.Shelf.Answer {}
                }

                public enum Forge {
                    public protocol Answer: Log.Shelf.Answer {}

                    public struct Spark: Answer {}
                }

                public enum Bay {
                    open class Answer {}

                    public final class Chime: Answer {}
                }

                extension Bay.Answer: Log.Shelf.Answer {}

                public protocol Middle: Log.Shelf.Answer {}

                public enum Quay {
                    public protocol Answer: Middle {}

                    public struct Bollard: Answer {}
                }
                """,
                to: "Sources/GizmoCore/Answer.swift",
                in: root
            )
            try TestSources.commitAll(in: root, message: "a class named as a protocol")
            try await TestSources.swiftBuildSuspending(packageAt: root)
        }
    }

    /// The unrelated class's subclass is left out and counted; every inheritor of a type of the name that inherits from the protocol stays.
    @Test
    func aSubclassOfAnotherTypeOfTheNameIsLeftOut() async throws {
        try await Self.fixture().withEngine { engine in
            let output = try await engine.lookup(symbol: "Log.Shelf.Answer", freshness: engine.ensureFresh())

            #expect(output.contains("conformers of Answer (11: 10 direct, 0 indirect, 1 inherited"), "\(output)")
            #expect(output.contains("1 left out: the index store records its clause as conforming to another \"Answer\"):"), "\(output)")
            #expect(!output.contains("Lantern"), "\(output)")
            for row in ["GizmoCore.Kiln.Ember — class", "GizmoCore.Forge.Spark — struct", "GizmoCore.Bay.Chime — class", "GizmoCore.Quay.Bollard — struct", "GizmoCore.Quay.Answer — protocol — Sources/GizmoCore/Answer.swift:38 — inherited through Middle"] {
                #expect(output.contains(row), "\(row)\n\(output)")
            }
        }
    }

    /// A row whose clause names a type of the name that inherits from the protocol is said to be had through another type, never not had at all: the store records its chain, only no direct conformance.
    @Test
    func aRowInheritingThroughAnotherTypeIsHadByTheStore() async throws {
        try await Self.fixture().withEngine { engine in
            let output = try await engine.lookup(symbol: "Log.Shelf.Answer", freshness: engine.ensureFresh())

            #expect(output.contains("conformers of Answer (11: 10 direct, 0 indirect, 1 inherited"), "\(output)")
            #expect(!output.contains("does not have it"), "\(output)")
            for row in [
                "GizmoCore.Kiln.Ember — class — Sources/GizmoCore/Answer.swift:16 — direct; the index store has it through another type",
                "GizmoCore.Forge.Spark — struct — Sources/GizmoCore/Answer.swift:24 — direct; the index store has it through another type",
                "GizmoCore.Bay.Chime — class — Sources/GizmoCore/Answer.swift:30 — direct; the index store has it through another type",
                "GizmoCore.Quay.Bollard — struct — Sources/GizmoCore/Answer.swift:40 — direct; the index store has it through another type",
            ] {
                #expect(output.components(separatedBy: "\n").contains("  " + row), "\(row)\n\(output)")
            }
        }
    }
}
