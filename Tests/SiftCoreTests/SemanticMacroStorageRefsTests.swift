//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// The storage `@Observable` generates for each property names the property's type at the attribute, and a reference sweep lists none of it — while every mention written in source, the attribute's own line included, stays listed and counted.
@Suite(.temporaryDirectories, .serialized)
struct SemanticMacroStorageRefsTests {
    /// A protocol held by an `@Observable` class's property, and held by another `@Observable` class's property written on the attribute's own line (a conformance there would be folded into the conformers block, so the line names the protocol as a plain use).
    static func writePackage(in root: URL) throws {
        try TestSources.write(
            """
            // swift-tools-version: 6.0
            import PackageDescription

            let package = Package(
                name: "Gizmo",
                platforms: [.macOS(.v14)],
                targets: [.target(name: "GizmoCore")]
            )
            """,
            to: "Package.swift",
            in: root
        )
        try TestSources.write(
            """
            import Observation

            public protocol Feed: AnyObject {}

            @Observable
            public final class Station {
                public var feed: (any Feed)?
                public init() {}
            }

            @Observable public final class Relay { public var upstream: (any Feed)?
                public var backup: (any Feed)?
                public init() {}
            }
            """,
            to: "Sources/GizmoCore/Station.swift",
            in: root
        )
    }

    /// `Station`'s `@Observable` line names nothing written, so it is never listed or counted; the property's line is, and so is `Relay`'s attribute line, where the property's type is written.
    @Test
    func aMacroStorageMentionIsNotAReferenceAndAWrittenOneOnItsLineIs() async throws {
        let fixture = try await SharedBuiltFixtures.process.fixture(for: Self.self, named: "semantic-macro-storage") { root in
            try Self.writePackage(in: root)
            try TestSources.commitAll(in: root, message: "buildable fixture")
            try await TestSources.swiftBuildSuspending(packageAt: root)
        }
        try await fixture.withEngine { engine in
            let freshness = try await engine.ensureFresh()
            let sweep = try await engine.lookup(symbol: "Feed", freshness: freshness, options: WhereOptions(includeReferences: true))

            #expect(!sweep.contains(":5  | @Observable"), "\(sweep)")
            #expect(sweep.contains(":7  | public var feed: (any Feed)?"), "\(sweep)")
            #expect(sweep.contains(":11  | @Observable public final class Relay { public var upstream: (any Feed)?"), "\(sweep)")
            #expect(sweep.contains(":12  | public var backup: (any Feed)?"), "\(sweep)")
            #expect(sweep.contains("references to GizmoCore.Feed (3 in 1 file, 1 more line a macro generated, not listed):"), "\(sweep)")
            #expect(sweep.contains("used by GizmoCore.Feed: 3 references in 1 file — 3 production · 0 tests"), "\(sweep)")
        }
    }
}
