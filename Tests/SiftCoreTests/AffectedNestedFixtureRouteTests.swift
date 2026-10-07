//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// Covers `affected` following a helper type nested in one suite on to another suite that builds it: the reference inside the helper names its own suite, and the suite that constructs the helper is reached one hop later.
@Suite(.serialized, .temporaryDirectories)
struct AffectedNestedFixtureRouteTests {
    /// The answer for a built repository whose `Widget` gains a member after the fixture commit, with `tests` written under `Tests/LibTests/`.
    private static func affected(tests: [(path: String, source: String)]) async throws -> String {
        let root = try TestSources.makeTempRepo()
        try TestSources.write(
            """
            // swift-tools-version: 6.0
            import PackageDescription

            let package = Package(
                name: "Lib",
                targets: [.target(name: "Lib"), .testTarget(name: "LibTests", dependencies: ["Lib"])]
            )
            """,
            to: "Package.swift",
            in: root
        )
        try TestSources.write("public protocol Shiny {}\n\npublic struct Widget {\n    public init() {}\n}\n", to: "Sources/Lib/Core.swift", in: root)
        for test in tests {
            try TestSources.write(test.source, to: "Tests/LibTests/\(test.path)", in: root)
        }
        try TestSources.commitAll(in: root, message: "fixture")
        try TestSources.write(
            "public protocol Shiny {}\n\npublic struct Widget {\n    public init() {}\n    public func shine() {}\n}\n",
            to: "Sources/Lib/Core.swift",
            in: root
        )
        try await TestSources.swiftBuildSuspending(packageAt: root, includingTests: true)
        let engine = try SiftEngine(directory: root)
        try await engine.awaitSemanticStore()
        let freshness = try await engine.ensureFresh()
        return try await engine.affected(options: AffectedOptions(), freshness: freshness)
    }

    /// A suite whose extension nests the helper that uses the changed type, written with `fixture` as the helper's body.
    private static func lampSuite(fixture: String) -> (path: String, source: String) {
        (path: "LampTests.swift", source: """
        import Testing
        @testable import Lib

        struct LampTests {
            @Test func lights() {}
        }

        extension LampTests {
        \(fixture)

            struct Holder {
                init() {}
            }
        }
        """)
    }

    /// Another suite that builds the helper through `construction`, and one that builds only the suite's other nested type.
    private static func otherSuites(construction: String) -> [(path: String, source: String)] {
        [
            (path: "KettleTests.swift", source: """
            import Testing
            @testable import Lib

            struct KettleTests {
                @Test func boils() {
                    _ = \(construction)
                }
            }
            """),
            (path: "GizmoTests.swift", source: """
            import Testing
            @testable import Lib

            struct GizmoTests {
                @Test func spins() {
                    _ = LampTests.Holder()
                }
            }
            """),
        ]
    }

    /// The changed type used in a stored property of the helper reaches the suite that calls the helper's declared initialiser, and not the suite that builds the other nested type.
    @Test
    func aSuiteBuildingTheHelperThroughItsInitialiserIsReached() async throws {
        let output = try await Self.affected(tests: [Self.lampSuite(fixture: """
            struct Fixture {
                let widget = Widget()
                let count: Int

                init(count: Int) {
                    self.count = count
                }
            }
        """)] + Self.otherSuites(construction: "LampTests.Fixture(count: 1)"))

        #expect(output.contains("mode: syntactic + semantic (index store via .build)"))
        #expect(output.contains("LibTests.LampTests — 1 hop — "))
        #expect(output.contains("LibTests.KettleTests/boils() — 2 hops — "))
        #expect(!output.contains("GizmoTests"))
        #expect(!output.contains("LampTests.Fixture"))
    }

    /// A helper built through its memberwise initialiser, which declares no initialiser of its own, is still followed through its type.
    @Test
    func aSuiteBuildingTheHelperMemberwiseIsReached() async throws {
        let output = try await Self.affected(tests: [Self.lampSuite(fixture: """
            struct Fixture {
                let widget = Widget()
                let count: Int
            }
        """)] + Self.otherSuites(construction: "LampTests.Fixture(count: 1)"))

        #expect(output.contains("LibTests.KettleTests/boils() — 2 hops — "))
        #expect(!output.contains("GizmoTests"))
    }

    /// A reference in the helper's own inheritance clause also leads on to the suite that builds it.
    @Test
    func aConformanceOfTheHelperReachesTheSuiteThatBuildsIt() async throws {
        let output = try await Self.affected(tests: [Self.lampSuite(fixture: """
            struct Fixture: Shiny {
                init(count: Int) {}
            }
        """)] + Self.otherSuites(construction: "LampTests.Fixture(count: 1)"))

        #expect(output.contains("LibTests.LampTests — 1 hop — "))
        #expect(output.contains("LibTests.KettleTests/boils() — 2 hops — "))
        #expect(!output.contains("GizmoTests"))
    }
}
