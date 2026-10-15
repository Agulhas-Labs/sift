//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// Pins a protocol's conformance lines being left out of its usage rows and counted: one written on a header's continuation line, and only those the conformers block lists.
@Suite(.temporaryDirectories, .serialized)
struct WhereConformanceLowsTests {
    private static var manifest: String {
        """
        // swift-tools-version: 6.0
        import PackageDescription

        let package = Package(
            name: "Lib",
            targets: [.target(name: "Lib")]
        )
        """
    }

    /// A built package whose protocol is conformed to on a header's continuation line, on a one-line header, and through a subclass whose header is itself continued.
    private static func headerFixture() async throws -> SharedBuiltFixture {
        try await SharedBuiltFixtures.process.fixture(for: Self.self, named: "where-conformance-header") { root in
            try TestSources.write(manifest, to: "Package.swift", in: root)
            try TestSources.write("public protocol Gizmo {}\n", to: "Sources/Lib/Gizmo.swift", in: root)
            try TestSources.write(
                """
                public struct Widget:
                    Gizmo {}

                public struct Crate: Gizmo {}

                public class Depot: Gizmo {}

                public class Orchard:
                    Depot {}
                """,
                to: "Sources/Lib/Parts.swift",
                in: root
            )
            try TestSources.write("public func use(_ gizmo: Gizmo) {}\n", to: "Sources/Lib/Use.swift", in: root)
            try TestSources.commitAll(in: root, message: "header fixture")
            try await TestSources.swiftBuildSuspending(packageAt: root)
        }
    }

    /// A built package whose protocol has more conformers than the conformers block lists.
    private static func manyFixture() async throws -> SharedBuiltFixture {
        try await SharedBuiltFixtures.process.fixture(for: Self.self, named: "where-conformance-many") { root in
            try TestSources.write(manifest, to: "Package.swift", in: root)
            try TestSources.write("public protocol Gizmo {}\n", to: "Sources/Lib/Gizmo.swift", in: root)
            let parts = (0 ..< WhereRenderer.listCap + 5).map { "public struct Part\($0): Gizmo {}" }.joined(separator: "\n")
            try TestSources.write(parts + "\n", to: "Sources/Lib/Parts.swift", in: root)
            try TestSources.write("public func use(_ gizmo: Gizmo) {}\n", to: "Sources/Lib/Use.swift", in: root)
            try TestSources.commitAll(in: root, message: "many fixture")
            try await TestSources.swiftBuildSuspending(packageAt: root)
        }
    }

    /// A clause continued onto the next line is a conformance, not a use, whichever way the answer is found: the store's and the written-name scan's rows leave it out and count it.
    @Test
    func aContinuedClauseIsCountedAsAConformanceNotListed() async throws {
        try await Self.headerFixture().withEngine { engine in
            let freshness = try await engine.ensureFresh()
            let withStore = try await engine.lookup(symbol: "Gizmo", freshness: freshness)
            let withoutStore = try await engine.lookup(symbol: "Gizmo", freshness: freshness, options: WhereOptions(includeSemantic: false))

            #expect(withStore.contains("4 references in 2 files, 3 of them the conformances listed below"), "\(withStore)")
            #expect(withStore.contains("  Sources/Lib/Use.swift (1):\n    :1  | public func use(_ gizmo: Gizmo) {}\n\nconformers of Gizmo ("), "\(withStore)")
            #expect(withoutStore.contains("(4 uses by written name in 2 files, 3 of them the conformances listed below)"), "\(withoutStore)")
            #expect(!withoutStore.contains("Parts.swift (1)"), "\(withoutStore)")
            #expect(withoutStore.contains("  Sources/Lib/Use.swift (1):\n    :1  | public func use(_ gizmo: Gizmo) {}\n\nconformers of Gizmo ("), "\(withoutStore)")
        }
    }

    /// The count says only the conformances the conformers block lists: with more conformers than its cap, the rest stay in the rows.
    @Test
    func theConformanceCountCoversOnlyTheConformersListed() async throws {
        let cap = WhereRenderer.listCap
        try await Self.manyFixture().withEngine { engine in
            let freshness = try await engine.ensureFresh()
            let withStore = try await engine.lookup(symbol: "Gizmo", freshness: freshness)
            let withoutStore = try await engine.lookup(symbol: "Gizmo", freshness: freshness, options: WhereOptions(includeSemantic: false))

            #expect(withStore.contains("\(cap + 6) references in 2 files, \(cap) of them the conformances listed below"), "\(withStore)")
            #expect(withoutStore.contains("(\(cap + 6) uses by written name in 2 files, \(cap) of them the conformances listed below)"), "\(withoutStore)")
            #expect(withoutStore.contains("    :\(cap + 1)  | public struct Part\(cap): Gizmo {}"), "\(withoutStore)")
            #expect(withoutStore.contains("truncated: 5 more conformers"), "\(withoutStore)")
        }
    }
}
