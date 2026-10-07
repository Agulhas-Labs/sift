//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// A requirement a refining protocol declares again is recorded by the store as implementing the base's, and is said to restate it, never to satisfy it: it is no witness.
@Suite(.temporaryDirectories, .serialized)
struct WitnessRestatedRequirementTests {
    /// A built package whose refining protocol restates a property and a function of its base, gives a third a default implementation, and has one conformer.
    private static func fixture() async throws -> SharedBuiltFixture {
        try await SharedBuiltFixtures.process.fixture(for: Self.self, named: "witness-restated-requirement") { root in
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
                public protocol Named {
                    var name: String { get }
                    func greet() -> String
                    func wave() -> String
                }

                public protocol Refined: Named {
                    var name: String { get }
                    func greet() -> String
                }

                extension Refined {
                    public func wave() -> String {
                        "wave"
                    }
                }

                public struct Depot: Refined {
                    public var name: String {
                        "depot"
                    }

                    public func greet() -> String {
                        name
                    }
                }

                public func show(_ item: some Refined) -> String {
                    item.name + item.greet()
                }
                """,
                to: "Sources/GizmoCore/Named.swift",
                in: root
            )
            try TestSources.commitAll(in: root, message: "restated requirement fixture")
            try await TestSources.swiftBuildSuspending(packageAt: root)
        }
    }

    /// A restated property and function each say what they restate, in the clause their direct uses and callers are headed with.
    @Test
    func aRestatedRequirementIsSaidToRestateTheBases() async throws {
        try await Self.fixture().withEngine { engine in
            let property = try await engine.lookup(symbol: "Refined.name", freshness: engine.ensureFresh())
            let function = try await engine.lookup(symbol: "Refined.greet", freshness: engine.ensureFresh())

            #expect(property.contains("direct reads and writes of GizmoCore.Refined.name (1, it restates Named.name, so a use made through Named, including one a library makes, is not recorded against it):"), "\(property)")
            #expect(function.contains("direct callers of GizmoCore.Refined.greet() (1, it restates Named.greet(), so a call made through Named, including one a library makes, is not recorded against it):"), "\(function)")
            #expect(!property.contains("satisfies"), "\(property)")
            #expect(!function.contains("satisfies"), "\(function)")
        }
    }

    /// The conformer's witness still satisfies both requirements, and a default implementation in the refining protocol's extension still satisfies the base's.
    @Test
    func witnessesAndDefaultImplementationsStillSatisfy() async throws {
        try await Self.fixture().withEngine { engine in
            let witness = try await engine.lookup(symbol: "Depot.name", freshness: engine.ensureFresh())
            let fallback = try await engine.lookup(symbol: "Refined.wave", freshness: engine.ensureFresh())

            #expect(witness.contains("it satisfies Refined.name and satisfies Named.name, so a use made through Refined or Named"), "\(witness)")
            #expect(fallback.contains("it satisfies Named.wave(), so a call made through Named"), "\(fallback)")
            #expect(!fallback.contains("restates"), "\(fallback)")
        }
    }

    /// A restatement is listed as no implementation: not of the base's requirement, and its own getter not of the restatement itself — the conformer's witness is the one implementation of each.
    @Test
    func aRestatementIsNoImplementation() async throws {
        try await Self.fixture().withEngine { engine in
            let restated = try await engine.lookup(symbol: "Refined.name", freshness: engine.ensureFresh())
            let base = try await engine.lookup(symbol: "Named.name", freshness: engine.ensureFresh())
            let baseFunction = try await engine.lookup(symbol: "Named.greet", freshness: engine.ensureFresh())

            #expect(restated.contains("implementations of GizmoCore.Refined.name (1):\n  Sources/GizmoCore/Named.swift (1):\n    :19  name  | public var name: String {"), "\(restated)")
            #expect(!restated.contains("getter:name"), "\(restated)")
            #expect(restated.contains("it restates Named.name"), "\(restated)")
            #expect(base.contains("implementations of GizmoCore.Named.name (1):\n  Sources/GizmoCore/Named.swift (1):\n    :19  name  | public var name: String {"), "\(base)")
            #expect(baseFunction.contains("implementations of GizmoCore.Named.greet() (1):\n  Sources/GizmoCore/Named.swift (1):\n    :23  greet()  | public func greet() -> String {"), "\(baseFunction)")
        }
    }
}
