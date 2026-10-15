//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// Covers a plain `where <Type>` against a built index store: up to ``WhereRenderer/listedInPlaceCap`` uses beyond a protocol's conformances are listed under the verdict with their source text and no pointer; more than that keep the pointer to `--refs` and list none.
@Suite(.temporaryDirectories, .serialized)
struct WhereListsFewUsesTests {
    /// A built package with a type used on five lines, a type used on nine, and the first naming itself inside its own declaration.
    private static func fixture() async throws -> SharedBuiltFixture {
        try await SharedBuiltFixtures.process.fixture(for: Self.self, named: "lists-few") { root in
            try TestSources.write(
                """
                // swift-tools-version: 6.0
                import PackageDescription

                let package = Package(
                    name: "Lib",
                    targets: [
                        .target(name: "Lib"),
                    ]
                )
                """,
                to: "Package.swift",
                in: root
            )
            try TestSources.write(
                """
                public struct Few {
                    public init() {}
                    public func copy() -> Few { Few() }
                }

                public struct Many {
                    public init() {}
                }

                public struct Edge {
                    public init() {}
                }

                public protocol Shape {}
                """,
                to: "Sources/Lib/Types.swift",
                in: root
            )
            try TestSources.write(
                (1 ... 5).map { "public func few\($0)() -> Few { Few() }\n" }.joined(),
                to: "Sources/Lib/Orchard.swift",
                in: root
            )
            try TestSources.write(
                (1 ... 9).map { "public func many\($0)() -> Many { Many() }\n" }.joined(),
                to: "Sources/Lib/Depot.swift",
                in: root
            )
            try TestSources.write(
                (1 ... 8).map { "public func edge\($0)() -> Edge { Edge() }\n" }.joined(),
                to: "Sources/Lib/Border.swift",
                in: root
            )
            try TestSources.write(
                "public struct Square: Shape {}\npublic struct Circle: Shape {}\npublic struct Oval: Shape {}\n",
                to: "Sources/Lib/Shapes.swift",
                in: root
            )
            try TestSources.write(
                (1 ... 8).map { "public func shape\($0)(_ shape: Shape) {}\n" }.joined(),
                to: "Sources/Lib/Gallery.swift",
                in: root
            )
            try TestSources.commitAll(in: root, message: "lists-few fixture")
            try await TestSources.swiftBuildSuspending(packageAt: root, includingTests: false)
        }
    }

    /// Five uses are listed under the verdict, each with its source text, and no pointer names `--refs`.
    @Test
    func fiveUsesAreListedWithNoPointer() async throws {
        try await Self.fixture().withEngine { engine in
            let output = try await engine.lookup(symbol: "Few", freshness: engine.ensureFresh())

            #expect(output.contains("used by Lib.Few: 5 references in 1 file"), "\(output)")
            #expect(!output.contains("where --refs Few lists them"), "\(output)")
            #expect(output.contains("Sources/Lib/Orchard.swift (5):"), "\(output)")
            #expect(output.contains(":1  | public func few1() -> Few { Few() }"), "\(output)")
            #expect(output.contains(":5  | public func few5() -> Few { Few() }"), "\(output)")
        }
    }

    /// Nine uses keep the verdict alone and the pointer to `--refs`.
    @Test
    func nineUsesKeepThePointerAndListNone() async throws {
        try await Self.fixture().withEngine { engine in
            let output = try await engine.lookup(symbol: "Many", freshness: engine.ensureFresh())

            #expect(output.contains("used by Lib.Many: 9 references in 1 file"), "\(output)")
            #expect(output.contains(" — where --refs Many lists them"), "\(output)")
            #expect(!output.contains("Sources/Lib/Depot.swift (9)"), "\(output)")
            #expect(!output.contains("| public func many1()"), "\(output)")
        }
    }

    /// A line inside the type's own declaration is counted in the verdict and never listed.
    @Test
    func aLineInsideTheOwnDeclarationIsNotListed() async throws {
        try await Self.fixture().withEngine { engine in
            let output = try await engine.lookup(symbol: "Few", freshness: engine.ensureFresh())

            #expect(output.contains("more line inside its own declaration"), "\(output)")
            #expect(!output.contains("public func copy() -> Few"), "\(output)")
            #expect(!output.contains("Sources/Lib/Types.swift ("), "\(output)")
        }
    }

    /// Exactly the cap is few enough: eight uses are listed with no pointer, where nine keep it.
    @Test
    func exactlyEightUsesAreListed() async throws {
        try await Self.fixture().withEngine { engine in
            let output = try await engine.lookup(symbol: "Edge", freshness: engine.ensureFresh())

            #expect(output.contains("used by Lib.Edge: 8 references in 1 file"), "\(output)")
            #expect(!output.contains("where --refs Edge lists them"), "\(output)")
            #expect(output.contains("Sources/Lib/Border.swift (8):"), "\(output)")
            #expect(output.contains(":8  | public func edge8() -> Edge { Edge() }"), "\(output)")
        }
    }

    /// A protocol's conformance lines are neither counted against the cap nor listed twice: three conformances and eight uses list the eight, and the conformers block holds the three.
    @Test
    func aProtocolsConformancesAreLeftOutOfTheCapAndTheRows() async throws {
        try await Self.fixture().withEngine { engine in
            let output = try await engine.lookup(symbol: "Shape", freshness: engine.ensureFresh())

            #expect(output.contains("used by Lib.Shape: 11 references in 2 files, 3 of them the conformances listed below"), "\(output)")
            #expect(!output.contains("where --refs Shape lists them"), "\(output)")
            #expect(output.contains("Sources/Lib/Gallery.swift (8):"), "\(output)")
            #expect(output.contains(":1  | public func shape1(_ shape: Shape) {}"), "\(output)")
            #expect(!output.contains("| public struct Square: Shape {}"), "\(output)")
            #expect(output.contains("conformers of Shape (3"), "\(output)")
        }
    }

    /// Under `--refs` the verdict stands alone with no pointer, the sweep following it.
    @Test
    func underRefsTheVerdictIsUnchanged() async throws {
        try await Self.fixture().withEngine { engine in
            let output = try await engine.lookup(symbol: "Few", freshness: engine.ensureFresh(), options: WhereOptions(includeReferences: true))

            #expect(output.contains("used by Lib.Few: 5 references in 1 file — 5 production · 0 tests; "), "\(output)")
            #expect(!output.contains("lists them\n"), "\(output)")
        }
    }
}
