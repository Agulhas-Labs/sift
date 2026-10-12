//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// A sweep of a type counts the macro-generated mentions of every typealias folded into it, as it counts those of the type.
@Suite(.temporaryDirectories, .serialized)
struct WhereGeneratedMentionAliasTests {
    /// A protocol, an alias for it, and an `@Observable` class whose property is typed through the alias, so the only generated mention is recorded on the alias.
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
            public typealias Link = Feed

            @Observable
            public final class Station {
                public var feed: (any Link)?
                public init() {}
            }
            """,
            to: "Sources/GizmoCore/Station.swift",
            in: root
        )
    }

    /// The generated storage mention is recorded against the alias, yet the type's sweep says one line a macro generated was left out.
    @Test
    func theHeadingCountsAGeneratedMentionRecordedOnAFoldedAlias() async throws {
        let fixture = try await SharedBuiltFixtures.process.fixture(for: Self.self, named: "semantic-macro-alias-storage") { root in
            try Self.writePackage(in: root)
            try TestSources.commitAll(in: root, message: "buildable fixture")
            try await TestSources.swiftBuildSuspending(packageAt: root)
        }
        try await fixture.withEngine { engine in
            let sweep = try await engine.lookup(symbol: "Feed", freshness: engine.ensureFresh(), options: WhereOptions(includeReferences: true))
            #expect(sweep.contains("1 more line a macro generated, not listed"), "\(sweep)")
        }
    }
}
