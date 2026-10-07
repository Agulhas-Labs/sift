//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// A property that satisfies a requirement is read through it, and none of those reads is recorded against it, so its listed reads are headed `direct reads and writes` with the hedge in the count, as a function's callers are.
@Suite(.temporaryDirectories, .serialized)
struct WitnessPropertyHedgeTests {
    /// A built package with a protocol property its witness is read directly once, and a property that implements nothing, also read once.
    private static func fixture() async throws -> SharedBuiltFixture {
        try await SharedBuiltFixtures.process.fixture(for: Self.self, named: "witness-property-hedge") { root in
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
                public protocol Shelf {
                    var title: String { get }
                }

                public struct Rack: Shelf {
                    public var title: String {
                        "rack"
                    }

                    var spare: Int {
                        1
                    }
                }

                public func name(_ rack: Rack) -> String {
                    rack.title + "\\(rack.spare)"
                }
                """,
                to: "Sources/GizmoCore/Shelf.swift",
                in: root
            )
            try TestSources.commitAll(in: root, message: "witness property fixture")
            try await TestSources.swiftBuildSuspending(packageAt: root)
        }
    }

    /// A witness with a direct read lists it under `direct reads and writes`, its count saying what it satisfies; a property that implements nothing keeps the bare heading.
    @Test
    func aPropertyWitnessWithDirectReadsIsHeadedDirectAndHedged() async throws {
        try await Self.fixture().withEngine { engine in
            let witness = try await engine.lookup(symbol: "Rack.title", freshness: engine.ensureFresh())
            let plain = try await engine.lookup(symbol: "Rack.spare", freshness: engine.ensureFresh())

            #expect(witness.contains("direct reads and writes of GizmoCore.Rack.title (1, it satisfies Shelf.title, so a use made through Shelf, including one a library makes, is not recorded against it):"), "\(witness)")
            #expect(!witness.contains("\nreads and writes of GizmoCore.Rack.title"), "\(witness)")
            #expect(plain.contains("reads and writes of GizmoCore.Rack.spare (1):"), "\(plain)")
            #expect(!plain.contains("direct reads and writes"), "\(plain)")
        }
    }
}
