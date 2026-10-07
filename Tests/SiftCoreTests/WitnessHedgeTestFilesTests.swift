//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// A witness's hedged empty case is a zero-use verdict like any other, so it says which test files the store does not hold, and a property or subscript that satisfies a requirement is hedged as a function is.
///
/// Built without its tests, the store records no call a test makes: a `<` only a test calls reads as unused unless the line says the test file is not in the store.
@Suite(.temporaryDirectories, .serialized)
struct WitnessHedgeTestFilesTests {
    private static var testFilesNote: String {
        "; 1 test file is not in it (build with `sift run -- swift build --build-tests`)"
    }

    /// A package built without its test target, whose one test file is the only direct caller of a `<`; a type whose `description` and `id` nothing reads directly, a second `description`, and a protocol whose subscript and method are witnessed, the method called directly once.
    private static func fixture() async throws -> SharedBuiltFixture {
        try await SharedBuiltFixtures.process.fixture(for: Self.self, named: "witness-hedge-test-files") { root in
            try TestSources.write(
                """
                // swift-tools-version: 6.0
                import PackageDescription

                let package = Package(
                    name: "Gizmo",
                    targets: [.target(name: "GizmoCore"), .testTarget(name: "GizmoTests", dependencies: ["GizmoCore"])]
                )
                """,
                to: "Package.swift",
                in: root
            )
            try TestSources.write(
                """
                public struct Grade: Comparable, CustomStringConvertible, Identifiable {
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

                public func best(_ grades: [Grade]) -> Grade? {
                    grades.max()
                }

                public func show(_ grade: Grade) -> String {
                    "\\(grade)"
                }
                """,
                to: "Sources/GizmoCore/Grade.swift",
                in: root
            )
            try TestSources.write(
                """
                public struct Rank: CustomStringConvertible {
                    let weight: Int

                    public var description: String {
                        "rank \\(weight)"
                    }
                }
                """,
                to: "Sources/GizmoCore/Rank.swift",
                in: root
            )
            try TestSources.write(
                """
                public protocol Shelf {
                    subscript(slot: Int) -> String { get }
                    func label() -> String
                }

                public struct Rack: Shelf {
                    public subscript(slot: Int) -> String {
                        "slot \\(slot)"
                    }

                    public func label() -> String {
                        "rack"
                    }
                }

                public func tag(_ rack: Rack) -> String {
                    rack.label()
                }

                public func peek(_ shelf: any Shelf) -> String {
                    shelf.label() + shelf[0]
                }
                """,
                to: "Sources/GizmoCore/Shelf.swift",
                in: root
            )
            try TestSources.write(
                """
                @testable import GizmoCore
                import Testing

                @Test func orders() {
                    #expect(Grade(score: 1) < Grade(score: 2))
                }
                """,
                to: "Tests/GizmoTests/GizmoTests.swift",
                in: root
            )
            try TestSources.commitAll(in: root, message: "witness test-files fixture")
            try await TestSources.swiftBuildSuspending(packageAt: root)
        }
    }

    /// A `<` only a test calls, with the test target unbuilt, says the test file is not in the store before what the witness satisfies, as every other zero-use line does.
    @Test
    func aWitnessOnlyATestCallsSaysTheTestFileIsNotInTheStore() async throws {
        try await Self.fixture().withEngine { engine in
            let output = try await engine.lookup(symbol: "Grade.<", freshness: engine.ensureFresh())

            #expect(output.contains("semantic: partial (1 test file"), "\(output)")
            #expect(output.contains("no direct callers of GizmoCore.Grade.<(lhs:rhs:) recorded in the store\(Self.testFilesNote) — it satisfies Comparable.<(_:_:), so a call made through Comparable"), "\(output)")
        }
    }

    /// A property and a subscript that satisfy a requirement, read nowhere directly, say no *direct* reads or writes and what they satisfy, with the test-file note, never a bare "no reads or writes".
    @Test
    func aPropertyOrSubscriptWitnessIsHedgedNotNoReadsOrWrites() async throws {
        try await Self.fixture().withEngine { engine in
            let description = try await engine.lookup(symbol: "Grade.description", freshness: engine.ensureFresh())
            let identity = try await engine.lookup(symbol: "Grade.id", freshness: engine.ensureFresh())
            let slot = try await engine.lookup(symbol: "Rack.subscript", freshness: engine.ensureFresh())

            #expect(description.contains("no direct reads or writes of GizmoCore.Grade.description recorded in the store\(Self.testFilesNote) — it satisfies CustomStringConvertible.description, so a use made through CustomStringConvertible, including one a library makes, is not recorded against it"), "\(description)")
            #expect(identity.contains("no direct reads or writes of GizmoCore.Grade.id recorded in the store\(Self.testFilesNote) — it satisfies Identifiable.id, so a use made through Identifiable"), "\(identity)")
            #expect(slot.contains("no direct reads or writes of GizmoCore.Rack.subscript(_:) recorded in the store\(Self.testFilesNote) — it satisfies Shelf.subscript(_:), so a use made through Shelf"), "\(slot)")
            for answer in [description, identity, slot] {
                #expect(!answer.contains("no reads or writes"), "\(answer)")
            }
        }
    }

    /// A bare `description` two types declare counts each owner's direct uses and says what each satisfies: never `0 uses` said of a property string interpolation reads.
    @Test
    func eachOwnersPropertyWitnessCountIsOfDirectUsesAndHedged() async throws {
        try await Self.fixture().withEngine { engine in
            let output = try await engine.lookup(symbol: "description", freshness: engine.ensureFresh())

            #expect(output.contains("under 2 owners"), "\(output)")
            #expect(output.components(separatedBy: "0 direct uses: 0 production").count == 3, "\(output)")
            #expect(output.components(separatedBy: ", and it satisfies CustomStringConvertible.description, so a use made through CustomStringConvertible").count == 3, "\(output)")
            #expect(!output.contains("0 uses"), "\(output)")
        }
    }

    /// A witness with a direct caller lists it under `direct callers`, its count saying what it satisfies: the call made through the protocol is not among them.
    @Test
    func aWitnessWithDirectCallersIsHeadedDirectAndHedged() async throws {
        try await Self.fixture().withEngine { engine in
            let output = try await engine.lookup(symbol: "Rack.label", freshness: engine.ensureFresh())

            #expect(output.contains("direct callers of GizmoCore.Rack.label() (1, it satisfies Shelf.label(), so a call made through Shelf, including one a library makes, is not recorded against it):"), "\(output)")
            #expect(output.contains("tag(_:)"), "\(output)")
            #expect(!output.contains("callers of GizmoCore.Rack.label() (1):"), "\(output)")
        }
    }
}
