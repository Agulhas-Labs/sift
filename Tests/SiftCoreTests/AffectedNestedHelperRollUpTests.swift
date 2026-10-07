//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// Covers `affected` naming the suite that encloses a helper type nested in it: a reference inside a nested type that is no suite counts for the nearest enclosing suite, at any depth, and a nested type with tests of its own is still reported as itself.
@Suite(.serialized, .temporaryDirectories)
struct AffectedNestedHelperRollUpTests {
    /// The answer for a repository whose `Widget` gains a member after the fixture commit, with `tests` written under `Tests/LibTests/`, over a build when `built` is set.
    private static func affected(built: Bool, tests: [(path: String, source: String)]) async throws -> String {
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
        try TestSources.write("public struct Widget {\n    public init() {}\n}\n", to: "Sources/Lib/Core.swift", in: root)
        for test in tests {
            try TestSources.write(test.source, to: "Tests/LibTests/\(test.path)", in: root)
        }
        try TestSources.commitAll(in: root, message: "fixture")
        try TestSources.write("public struct Widget {\n    public init() {}\n    public func shine() {}\n}\n", to: "Sources/Lib/Core.swift", in: root)
        if built {
            try await TestSources.swiftBuildSuspending(packageAt: root, includingTests: true)
        }
        let engine = try SiftEngine(directory: root)
        try await engine.awaitSemanticStore()
        let freshness = try await engine.ensureFresh()
        return try await engine.affected(options: AffectedOptions(), freshness: freshness)
    }

    private static let swiftTestingSuite = (
        path: "LampTests.swift",
        source: """
        import Testing
        @testable import Lib

        struct LampTests {
            struct Fixture {
                let widget = Widget()
            }

            @Test func lights() {
                _ = Fixture()
            }
        }
        """
    )

    /// With no store, the written name of `Widget` inside the nested helper reaches the enclosing suite directly, at the first hop.
    @Test
    func aNameMatchRollsAHelperNestedInASuiteUpToTheSuite() async throws {
        let output = try await Self.affected(built: false, tests: [Self.swiftTestingSuite])

        #expect(output.contains("LibTests.LampTests — 1 hop, name match"))
        #expect(!output.contains("LampTests.Fixture"))
    }

    /// With a store, the recorded reference inside the nested helper names the enclosing suite as a resolved reference.
    @Test
    func aResolvedWalkRollsAHelperNestedInASuiteUpToTheSuite() async throws {
        let output = try await Self.affected(built: true, tests: [Self.swiftTestingSuite])

        #expect(output.contains("mode: syntactic + semantic (index store via .build)"))
        #expect(output.contains("LibTests.LampTests — 1 hop — "))
        #expect(!output.contains("LampTests.Fixture"))
    }

    /// Helpers nested two deep, in a type that is itself no suite, still count for the one suite that encloses them.
    @Test
    func aHelperNestedTwoDeepRollsUpToTheNearestSuite() async throws {
        let output = try await Self.affected(built: false, tests: [(
            path: "KettleTests.swift",
            source: """
            import Testing
            @testable import Lib

            struct KettleTests {
                enum Support {
                    struct Fixture {
                        let widget = Widget()
                    }
                }

                @Test func boils() {
                    _ = Support.Fixture()
                }
            }
            """
        )])

        #expect(output.contains("LibTests.KettleTests — 1 hop, name match"))
        #expect(!output.contains("Support"))
    }

    /// An XCTest case's nested helper struct that uses the type names the case, whose tests are built from it.
    @Test
    func aHelperNestedInAnXCTestCaseRollsUpToTheCase() async throws {
        let output = try await Self.affected(built: false, tests: [(
            path: "GizmoTests.swift",
            source: """
            import XCTest
            @testable import Lib

            final class GizmoTests: XCTestCase {
                struct Fixture {
                    let widget = Widget()
                }

                func testOne() {
                    _ = Fixture()
                }
            }
            """
        )])

        #expect(output.contains("LibTests.GizmoTests — 1 hop, name match"))
        #expect(!output.contains("GizmoTests.Fixture"))
    }

    /// A nested type with a test of its own is a suite, so the reference in its helper names it and not the suite around it.
    @Test
    func aNestedTypeWithItsOwnTestsIsReportedAsItself() async throws {
        let output = try await Self.affected(built: false, tests: [(
            path: "LampTests.swift",
            source: """
            import Testing
            @testable import Lib

            struct LampTests {
                @Test func plain() {}

                struct Inner {
                    let widget = Widget()

                    @Test func deep() {}
                }
            }
            """
        )])

        #expect(output.contains("LibTests.LampTests/Inner — 1 hop, name match"))
        #expect(!output.contains("LibTests.LampTests — "))
    }
}
