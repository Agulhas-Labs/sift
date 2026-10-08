//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// Covers `affected --reached` asked about a member of a suite the walk reached whole, which the list prints as the suite alone.
///
/// No build: the name-match fallback reaches the suite through its stored property.
@Suite(.temporaryDirectories)
struct AffectedReachedMemberTests {
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

    /// A suite holding a `Widget`, with three tests of its own and three in a nested suite, asked about each name in turn.
    private static func answers(probing names: [String]) async throws -> [String] {
        let root = try TestSources.makeTempRepo()
        try TestSources.write(manifest(), to: "Package.swift", in: root)
        try TestSources.write("public struct Widget {\n    public init() {}\n}\n", to: "Sources/Lib/Core.swift", in: root)
        try TestSources.write(
            """
            import Testing
            @testable import Lib

            struct LampTests {
                let widget = Widget()
                @Test func case0() {}
                @Test func case1() {}
                @Test func case2() {}

                struct Inner {
                    @Test func deep0() {}
                    @Test func deep1() {}
                    @Test func deep2() {}
                }
            }
            """,
            to: "Tests/LibTests/LampTests.swift",
            in: root
        )
        try TestSources.commitAll(in: root, message: "fixture")
        try TestSources.write("public struct Widget {\n    public init() {}\n    public func shine() {}\n}\n", to: "Sources/Lib/Core.swift", in: root)
        let engine = try SiftEngine(directory: root)
        try await engine.awaitSemanticStore()
        let freshness = try await engine.ensureFresh()
        var answers: [String] = []
        for name in names {
            try await answers.append(engine.affected(options: AffectedOptions(probes: [name]), freshness: freshness))
        }
        return answers
    }

    /// A member the inventory lists under the suite is run by it, in either spelling of a nested one; a name it does not list is no known test, not covered.
    @Test
    func aMemberOfAWholeSuiteIsCoveredOnlyWhereTheInventoryListsIt() async throws {
        let answers = try await Self.answers(probing: [
            "LibTests.LampTests/case1()",
            "LibTests.LampTests.Inner/deep0()",
            "LibTests.LampTests/case9()",
        ])

        #expect(answers[0].contains("reached? LibTests.LampTests/case1() — 1 match, within 2 reference hops:"))
        #expect(answers[0].contains("  LibTests.LampTests/case1() — 1 hop, name match, run by LibTests.LampTests, reached whole — Tests/LibTests/LampTests.swift:"))
        #expect(answers[1].contains("  LibTests.LampTests/Inner/deep0() — 1 hop, name match, run by LibTests.LampTests, reached whole — "))
        #expect(answers[2].contains("reached? LibTests.LampTests/case9() — not a known test: LibTests.LampTests, which the walk reached whole, declares no test by that name in the inventory."))
        #expect(!answers[2].contains("match, within"))
        #expect(!answers[2].contains("matches, within"))
        #expect(!answers[2].contains("run by"))
    }

    /// A fragment of a member's name matches it as a fragment of a listed name does, a nested suite's member included.
    @Test
    func aFragmentOfAMemberOfAWholeSuiteMatchesIt() async throws {
        let answers = try await Self.answers(probing: ["LampTests/case1()", "Inner/deep0()"])

        #expect(answers[0].contains("reached? LampTests/case1() — 1 match, within 2 reference hops:"))
        #expect(answers[0].contains("  LibTests.LampTests/case1() — 1 hop, name match, run by LibTests.LampTests, reached whole — "))
        #expect(answers[1].contains("reached? Inner/deep0() — 1 match, within 2 reference hops:"))
        #expect(answers[1].contains("  LibTests.LampTests/Inner/deep0() — 1 hop, name match, run by LibTests.LampTests, reached whole — "))
    }
}
