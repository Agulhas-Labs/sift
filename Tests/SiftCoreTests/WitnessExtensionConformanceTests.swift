//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// A witness whose conformance is declared in an extension is hedged as one declared on the type is: the store records what it implements on an implicit occurrence at the extension, not on its definition.
@Suite(.temporaryDirectories, .serialized)
struct WitnessExtensionConformanceTests {
    /// A package whose `<`, `id` and `description` satisfy requirements an empty extension declares, nothing calling or reading them directly; a second such `description`, and a type whose `description` and `count` implement nothing.
    private static func fixture() async throws -> SharedBuiltFixture {
        try await SharedBuiltFixtures.process.fixture(for: Self.self, named: "witness-extension-conformance") { root in
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
                public struct Grade {
                    let score: Int

                    public var id: Int {
                        score
                    }

                    public var description: String {
                        "grade \\(score)"
                    }

                    public static func < (lhs: Grade, rhs: Grade) -> Bool {
                        lhs.score < rhs.score
                    }
                }

                extension Grade: Comparable, CustomStringConvertible, Identifiable {}

                public struct Rank {
                    let level: Int

                    public var description: String {
                        "rank \\(level)"
                    }
                }

                extension Rank: CustomStringConvertible {}

                public struct Rack {
                    var description: String {
                        "rack"
                    }

                    var count: Int {
                        1
                    }
                }

                public func best(_ grades: [Grade]) -> Grade? {
                    grades.max()
                }

                public func show(_ grade: Grade, _ rank: Rank) -> String {
                    "\\(grade) \\(rank)"
                }
                """,
                to: "Sources/GizmoCore/Grade.swift",
                in: root
            )
            try TestSources.commitAll(in: root, message: "witness extension conformance fixture")
            try await TestSources.swiftBuildSuspending(packageAt: root)
        }
    }

    /// A `<` whose `Comparable` conformance an extension declares, which only `max()` calls, is hedged rather than said to have no callers.
    @Test
    func aFunctionWitnessConformingInAnExtensionIsHedged() async throws {
        try await Self.fixture().withEngine { engine in
            let output = try await engine.lookup(symbol: "Grade.<", freshness: engine.ensureFresh())

            #expect(output.contains("semantic: fresh"), "\(output)")
            #expect(output.contains("no direct callers of GizmoCore.Grade.<(lhs:rhs:) recorded in the store — it satisfies Comparable.<(_:_:), so a call made through Comparable, including one a library makes, is not recorded against it"), "\(output)")
            #expect(!output.contains("no callers"), "\(output)")
        }
    }

    /// An `id` and a `description` whose conformances an extension declares are hedged rather than said to have no reads or writes; a property that implements nothing keeps the bare wording.
    @Test
    func aPropertyWitnessConformingInAnExtensionIsHedged() async throws {
        try await Self.fixture().withEngine { engine in
            let description = try await engine.lookup(symbol: "Grade.description", freshness: engine.ensureFresh())
            let identity = try await engine.lookup(symbol: "Grade.id", freshness: engine.ensureFresh())
            let plain = try await engine.lookup(symbol: "Rack.count", freshness: engine.ensureFresh())

            #expect(description.contains("no direct reads or writes of GizmoCore.Grade.description recorded in the store — it satisfies CustomStringConvertible.description, so a use made through CustomStringConvertible, including one a library makes, is not recorded against it"), "\(description)")
            #expect(identity.contains("no direct reads or writes of GizmoCore.Grade.id recorded in the store — it satisfies Identifiable.id, so a use made through Identifiable"), "\(identity)")
            for answer in [description, identity] {
                #expect(!answer.contains("no reads or writes"), "\(answer)")
            }
            #expect(plain.contains("no reads or writes of GizmoCore.Rack.count"), "\(plain)")
            #expect(!plain.contains("satisfies"), "\(plain)")
        }
    }

    /// A bare `description` three types declare hedges each extension-conforming owner's count of direct uses, once each, and leaves the owner that implements nothing at a plain `0 uses`.
    @Test
    func eachExtensionConformingOwnersCountIsOfDirectUsesAndHedged() async throws {
        try await Self.fixture().withEngine { engine in
            let output = try await engine.lookup(symbol: "description", freshness: engine.ensureFresh())

            #expect(output.contains("under 3 owners"), "\(output)")
            #expect(output.components(separatedBy: "0 direct uses: 0 production").count == 3, "\(output)")
            #expect(output.components(separatedBy: ", and it satisfies CustomStringConvertible.description, so a use made through CustomStringConvertible").count == 3, "\(output)")
            #expect(output.components(separatedBy: "0 uses").count == 2, "\(output)")
        }
    }
}
