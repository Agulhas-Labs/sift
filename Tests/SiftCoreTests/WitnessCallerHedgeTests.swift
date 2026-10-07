//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// A function that satisfies a protocol requirement or overrides a superclass member is called through it, and the store records none of those calls against the function, so its empty case is never a bare "no callers" or "0 call sites".
///
/// `sorted()` reaches a `<` from inside the standard library, and an existential call goes to the requirement; both read as dead code unhedged. A function that implements nothing still says "no callers" unhedged.
@Suite(.temporaryDirectories, .serialized)
struct WitnessCallerHedgeTests {
    /// A built package with two `Comparable` types whose `<` only `sorted()` and `max()` reach, a protocol method called only through an existential, an override called only through its superclass, and functions that implement nothing and are called by nothing.
    private static func fixture() async throws -> SharedBuiltFixture {
        try await SharedBuiltFixtures.process.fixture(for: Self.self, named: "witness-caller-hedge") { root in
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
                public enum Rank: Comparable {
                    case low
                    case high

                    public static func < (lhs: Rank, rhs: Rank) -> Bool {
                        lhs.weight < rhs.weight
                    }

                    var weight: Int {
                        self == .low ? 0 : 1
                    }

                    func spare() -> Int {
                        0
                    }
                }

                public func ordered(_ ranks: [Rank]) -> [Rank] {
                    ranks.sorted()
                }
                """,
                to: "Sources/GizmoCore/Rank.swift",
                in: root
            )
            try TestSources.write(
                """
                public struct Grade: Comparable {
                    let score: Int

                    public static func < (lhs: Grade, rhs: Grade) -> Bool {
                        lhs.score < rhs.score
                    }

                    func spare() -> Int {
                        1
                    }
                }

                public func best(_ grades: [Grade]) -> Grade? {
                    grades.max()
                }
                """,
                to: "Sources/GizmoCore/Grade.swift",
                in: root
            )
            try TestSources.write(
                """
                public protocol Shape {
                    func area() -> Double
                }

                public struct Square: Shape {
                    let side: Double

                    public func area() -> Double {
                        side * side
                    }
                }

                public func total(_ shapes: [any Shape]) -> Double {
                    shapes.reduce(0) { $0 + $1.area() }
                }

                open class Base {
                    open func ping() {}
                }

                public final class Leaf: Base {
                    override public func ping() {}
                }

                public func poke(_ base: Base) {
                    base.ping()
                }

                public func lonely() {}
                """,
                to: "Sources/GizmoCore/Shape.swift",
                in: root
            )
            try TestSources.commitAll(in: root, message: "witness fixture")
            try await TestSources.swiftBuildSuspending(packageAt: root)
        }
    }

    /// A standard-library requirement's witness that only `sorted()` calls says it has no *direct* callers and names the requirement it satisfies, by the protocol the store resolves from the conformance clause.
    @Test
    func aComparableWitnessOnlySortedCallsIsHedgedNotNoCallers() async throws {
        try await Self.fixture().withEngine { engine in
            let output = try await engine.lookup(symbol: "Rank.<", freshness: engine.ensureFresh())

            #expect(output.contains("semantic: fresh"), "\(output)")
            #expect(output.contains("no direct callers of GizmoCore.Rank.<(lhs:rhs:) recorded in the store — it satisfies Comparable.<(_:_:), so a call made through Comparable, including one a library makes, is not recorded against it"), "\(output)")
            #expect(!output.contains("existential"), "\(output)")
            #expect(!output.contains("no callers"), "\(output)")
            #expect(!output.contains("where Comparable"), "\(output)")
        }
    }

    /// A project protocol's witness called only through an existential is hedged the same way, its protocol named from the requirement's own definition.
    @Test
    func aProjectProtocolWitnessCalledOnlyThroughAnExistentialIsHedged() async throws {
        try await Self.fixture().withEngine { engine in
            let output = try await engine.lookup(symbol: "Square.area", freshness: engine.ensureFresh())

            #expect(output.contains("no direct callers of GizmoCore.Square.area() recorded in the store — it satisfies Shape.area(), so a call made through Shape, including one a library makes, is not recorded against it"), "\(output)")
            #expect(!output.contains("no callers"), "\(output)")
        }
    }

    /// An override called only through its superclass says what it overrides, in the superclass's words rather than a protocol's.
    @Test
    func anOverrideCalledOnlyThroughItsSuperclassIsHedged() async throws {
        try await Self.fixture().withEngine { engine in
            let output = try await engine.lookup(symbol: "Leaf.ping", freshness: engine.ensureFresh())

            #expect(output.contains("no direct callers of GizmoCore.Leaf.ping() recorded in the store — it overrides Base.ping(), so a call made through Base, as a superclass reference or a library makes one, is not recorded against it"), "\(output)")
            #expect(!output.contains("no callers"), "\(output)")
        }
    }

    /// A bare `<` two types declare is counted per owner, and each count is of direct call sites, hedged in the same field: never `0 call sites` said of a function `sorted()` calls.
    @Test
    func eachOwnersWitnessCountIsOfDirectCallSitesAndHedged() async throws {
        try await Self.fixture().withEngine { engine in
            let output = try await engine.lookup(symbol: "<", freshness: engine.ensureFresh())

            #expect(output.contains("under 2 owners"), "\(output)")
            #expect(output.components(separatedBy: "0 direct call sites: 0 production · 0 tests, and it satisfies Comparable.<(_:_:), so a call made through Comparable").count == 3, "\(output)")
            #expect(!output.contains("0 call sites"), "\(output)")
        }
    }

    /// A function that implements nothing and that nothing calls still says so unhedged, alone and counted per owner.
    @Test
    func aFunctionThatImplementsNothingStillSaysNoCallers() async throws {
        try await Self.fixture().withEngine { engine in
            let alone = try await engine.lookup(symbol: "lonely", freshness: engine.ensureFresh())
            let counted = try await engine.lookup(symbol: "spare", freshness: engine.ensureFresh())

            #expect(alone.contains("no callers of GizmoCore.lonely() recorded in the store"), "\(alone)")
            #expect(!alone.contains("direct"), "\(alone)")
            #expect(counted.contains("under 2 owners"), "\(counted)")
            #expect(counted.components(separatedBy: "0 call sites: 0 production · 0 tests").count == 3, "\(counted)")
            #expect(!counted.contains("direct"), "\(counted)")
            #expect(!counted.contains("satisfies"), "\(counted)")
        }
    }
}
