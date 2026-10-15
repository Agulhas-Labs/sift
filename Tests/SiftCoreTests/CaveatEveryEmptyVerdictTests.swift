//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// Every empty `where` verdict carries the standing caveats (``StandingCaveats``), not only the three with an empty callers, uses or references list: a type used only by itself or named only by its aliases, a witness called only through its requirement, a several-owners row counting none, and a no-store sweep that found nothing, which says exactly one (Docs/Design.md §2, *Superseded: the caveat is said where it applies*).
@Suite(.temporaryDirectories, .serialized)
struct CaveatEveryEmptyVerdictTests {
    /// A built package with a type used only by itself, a type named only by an alias, a witness and a property witness called only through their protocol, a name two owners declare and nothing calls, and a function with callers whose own `--refs` code sites all sit under `callers of`.
    private static func fixture() async throws -> SharedBuiltFixture {
        try await SharedBuiltFixtures.process.fixture(for: Self.self, named: "caveat-every-empty-verdict") { root in
            try TestSources.write(
                """
                // swift-tools-version: 6.0
                import PackageDescription

                let package = Package(name: "Lib", targets: [.target(name: "Lib")])
                """,
                to: "Package.swift",
                in: root
            )
            try TestSources.write(
                """
                public struct Spiral {
                    public var next: Spiral? { nil }
                }

                public struct Dead {}
                public typealias Echo = Dead

                public protocol Shape {
                    func area() -> Int
                    var sides: Int { get }
                }

                public struct Square: Shape {
                    public func area() -> Int { 1 }
                    public var sides: Int { 4 }
                }

                public func total(_ shape: some Shape) -> Int {
                    shape.area() + shape.sides
                }

                public struct Alpha {
                    public func dup() {}
                    public func shared() {}
                }

                public struct Beta {
                    public func dup() {}
                    public func shared() {}
                }

                public func go(_ alpha: Alpha, _ beta: Beta) {
                    alpha.shared()
                    beta.shared()
                }
                """,
                to: "Sources/Lib/Lib.swift",
                in: root
            )
            try TestSources.commitAll(in: root, message: "caveat every empty verdict fixture")
            try await TestSources.swiftBuildSuspending(packageAt: root)
        }
    }

    private static func answer(_ symbol: String) async throws -> String {
        try await fixture().withEngine { engine in
            try await engine.lookup(symbol: symbol, freshness: engine.ensureFresh())
        }
    }

    @Test
    func aTypeUsedOnlyByItselfCarriesTheSentences() async throws {
        let output = try await Self.answer("Spiral")

        #expect(output.contains("falls inside its own declaration"), "\(output)")
        #expect(output.contains(StandingCaveats.sentences), "\(output)")
    }

    @Test
    func aTypeNamedOnlyByItsAliasesCarriesTheSentences() async throws {
        let output = try await Self.answer("Dead")

        #expect(output.contains("so they go with it"), "\(output)")
        #expect(output.contains(StandingCaveats.sentences), "\(output)")
    }

    @Test
    func anAliasNamedOnlyByItsAliasesCarriesTheSentences() async throws {
        let output = try await Self.answer("Echo")

        #expect(output.contains("counts the alias's own name"), "\(output)")
        #expect(output.contains(StandingCaveats.sentences), "\(output)")
    }

    @Test
    func aWitnessHedgedAsHavingNoDirectCallersCarriesTheSentences() async throws {
        let output = try await Self.answer("Square.area")

        #expect(output.contains("no direct callers"), "\(output)")
        #expect(output.contains(StandingCaveats.sentences), "\(output)")
    }

    @Test
    func aPropertyWitnessHedgedAsHavingNoDirectUsesCarriesTheSentences() async throws {
        let output = try await Self.answer("Square.sides")

        #expect(output.contains("it satisfies Shape.sides"), "\(output)")
        #expect(output.contains(StandingCaveats.sentences), "\(output)")
    }

    @Test
    func aSeveralOwnersTableWithARowCountingNoneCarriesTheSentences() async throws {
        let output = try await Self.answer("dup")

        #expect(output.contains("under 2 owners"), "\(output)")
        #expect(output.contains("0 call sites"), "\(output)")
        #expect(output.contains(StandingCaveats.sentences), "\(output)")
    }

    @Test
    func aSeveralOwnersTableWhoseRowsAllCountSomethingDoesNot() async throws {
        let output = try await Self.answer("shared")

        #expect(output.contains("under 2 owners"), "\(output)")
        #expect(!output.contains("0 call sites"), "\(output)")
        #expect(!output.contains(StandingCaveats.sentences), "\(output)")
    }

    // MARK: No store

    private static func noStoreAnswer(_ symbol: String) async throws -> String {
        let root = try TestSources.makeTempRepo()
        try TestSources.write(
            """
            public func lonely() {}

            public enum Mode {
                case a
                case b
            }

            public struct Holder {
                public var idle = 0
            }

            public func pick() -> Mode { .a }
            """,
            to: "Sources/Lib/Lib.swift",
            in: root
        )
        let engine = try SiftEngine(directory: root)
        return try await engine.lookup(symbol: symbol, freshness: engine.ensureFresh())
    }

    private static func caveatCount(in answer: String) -> Int {
        answer.components(separatedBy: "an empty list is not").count - 1
    }

    @Test(arguments: ["lonely", "Mode.b", "Holder.idle"])
    func anEmptyNoStoreSweepCarriesExactlyOneCaveat(symbol: String) async throws {
        let output = try await Self.noStoreAnswer(symbol)

        #expect(output.contains("anywhere in the working tree"), "\(output)")
        #expect(output.contains(StandingCaveats.sentences), "\(output)")
        #expect(Self.caveatCount(in: output) == 1, "\(output)")
    }

    @Test
    func aNoStoreSweepThatFindsASiteCarriesNoSentences() async throws {
        let output = try await Self.noStoreAnswer("Mode.a")

        #expect(output.contains("1 use by written name"), "\(output)")
        #expect(!output.contains(StandingCaveats.sentences), "\(output)")
    }
}
