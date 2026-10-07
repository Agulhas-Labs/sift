//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// Covers `affected` reaching a test through a helper declared in another suite: the helper names its own suite, and the walk follows it on to the suites that call it.
@Suite(.serialized, .temporaryDirectories)
struct AffectedSuiteHelperRouteTests {
    private static func manifest() -> String {
        """
        // swift-tools-version: 6.0
        import PackageDescription

        let package = Package(
            name: "Lib",
            targets: [
                .target(name: "Lib"),
                .testTarget(name: "LibTests", dependencies: ["Lib"]),
            ]
        )
        """
    }

    /// `LampTests` builds a `Widget` in a helper of its own; `KettleTests` calls that helper and never spells `Widget`.
    ///
    /// The change to `Widget` is left uncommitted, and built over when `built` is set.
    private static func affected(built: Bool) async throws -> String {
        let root = try TestSources.makeTempRepo()
        try TestSources.write(manifest(), to: "Package.swift", in: root)
        try TestSources.write("public struct Widget {\n    public init() {}\n}\n", to: "Sources/Lib/Core.swift", in: root)
        try TestSources.write(
            """
            import Testing
            @testable import Lib

            struct LampTests {
                static func rig() -> Widget {
                    Widget()
                }

                @Test func lights() {
                    _ = Self.rig()
                }
            }
            """,
            to: "Tests/LibTests/LampTests.swift",
            in: root
        )
        try TestSources.write(
            """
            import Testing
            @testable import Lib

            struct KettleTests {
                @Test func boils() {
                    _ = LampTests.rig()
                }
            }
            """,
            to: "Tests/LibTests/KettleTests.swift",
            in: root
        )
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

    /// A changed `Widget` whose only test is four hops out, through three library functions, built over the change: the `affected` answer, and the `diff` one that embeds it.
    private static func answersFourHopsOut() async throws -> (affected: String, diff: String) {
        let root = try TestSources.makeTempRepo()
        try TestSources.write(manifest(), to: "Package.swift", in: root)
        try TestSources.write("public struct Widget {\n    public init() {}\n}\n", to: "Sources/Lib/Core.swift", in: root)
        try TestSources.write(
            """
            func forge() -> String {
                _ = Widget()
                return "forged"
            }

            func temper() -> String {
                forge()
            }

            func finish() -> String {
                temper()
            }
            """,
            to: "Sources/Lib/Chain.swift",
            in: root
        )
        try TestSources.write(
            """
            import Testing
            @testable import Lib

            struct LampTests {
                @Test func lights() {
                    _ = finish()
                }
            }
            """,
            to: "Tests/LibTests/LampTests.swift",
            in: root
        )
        try TestSources.commitAll(in: root, message: "fixture")
        try TestSources.write("public struct Widget {\n    public init() {}\n    public func shine() {}\n}\n", to: "Sources/Lib/Core.swift", in: root)
        try await TestSources.swiftBuildSuspending(packageAt: root, includingTests: true)
        let engine = try SiftEngine(directory: root)
        try await engine.awaitSemanticStore()
        let freshness = try await engine.ensureFresh()
        let affected = try await engine.affected(options: AffectedOptions(), freshness: freshness)
        let range = try DiffRange.resolve(nil, git: GitContext(repoRoot: root))
        let diff = try await engine.diff(options: DiffOptions(range: range), freshness: freshness)
        return (affected, diff)
    }

    /// A changed file that reaches no test within the default two hops is walked on to the first hop that does, and the answer names the file and the hop.
    @Test
    func aChangedFileReachingNoTestWithinTheBoundIsWalkedOnToItsFirst() async throws {
        let (output, diff) = try await Self.answersFourHopsOut()

        #expect(output.contains("depth: 2 reference hops from the changed declarations"))
        #expect(output.contains("LibTests.LampTests/lights() — 4 hops — "))
        #expect(output.contains("note: 1 changed file reached no test within 2 hops, so the resolved walk went on from it to the first hop that reaches one: Sources/Lib/Core.swift at 4 hops"))
        // The limits block names the exception, so the 4-hop entry does not sit under a line saying the walk stopped at two.
        #expect(output.contains("the reference walk stops at 2 hops, except from the changed file the note above names, walked on past it toward its first test, as far as that note says it went — "))
        // `diff` states the bound above the same 4-hop entry, and the exception with it.
        #expect(diff.contains("followed 2 hops, and on from 1 changed file that reached no test within them, toward its first test as far as `sift affected` says it went — "))
        #expect(diff.contains("LibTests.LampTests/lights() — 4 hops — "))
    }

    /// With no store, the helper's written name is carried into the next hop, so the suite calling it is listed beside the suite declaring it.
    @Test
    func aNameMatchFollowsASuitesHelperIntoTheSuitesThatCallIt() async throws {
        let output = try await Self.affected(built: false)

        #expect(output.contains("LibTests.LampTests — 1 hop, name match"))
        #expect(output.contains("LibTests.KettleTests/boils() — 2 hops, name match"))
    }

    /// With a store, the helper's resolved references are followed, so the suite calling it is listed as a resolved reference.
    @Test
    func aResolvedWalkFollowsASuitesHelperIntoTheSuitesThatCallIt() async throws {
        let output = try await Self.affected(built: true)

        #expect(output.contains("mode: syntactic + semantic (index store via .build)"))
        #expect(output.contains("LibTests.LampTests — 1 hop — "))
        #expect(output.contains("LibTests.KettleTests/boils() — 2 hops — "))
    }
}
