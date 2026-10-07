//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// Covers the count of a Swift Testing suite reached whole that has a suite nested inside it, which its filter runs too.
///
/// No build: the name-match fallback reaches the outer suite through its stored property and one nested test through its body.
@Suite(.temporaryDirectories)
struct AffectedNestedSuiteCountTests {
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

    /// Three tests of its own and three in a nested suite, one of which also writes `Widget`: the outer suite stands for all six, once, and the nested test is not listed beside it.
    @Test
    func aWholeSuiteCountsTheTestsOfTheSuitesNestedInIt() async throws {
        let root = try TestSources.makeTempRepo()
        try TestSources.write(Self.manifest(), to: "Package.swift", in: root)
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
                    @Test func deep0() { _ = Widget() }
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

        let output = try await engine.affected(options: AffectedOptions(), freshness: freshness)

        #expect(output.contains("affected tests (6 in 1 target):"))
        #expect(output.contains("  LibTests — 6 tests"))
        #expect(output.contains("    LibTests.LampTests — 1 hop"))
        #expect(!output.contains("LibTests.LampTests/Inner/deep0()"))
    }
}
