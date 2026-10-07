//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// A type's `used by` verdict never says `0 tests` of test files the store holds no unit for.
///
/// A plain `swift build` compiles no test target, so the store records no reference from a test: the count of tests is not zero, it was never taken, and a deletion or a rename is decided on it.
@Suite(.serialized, .temporaryDirectories)
struct WhereUnbuiltTestsTallyTests {
    /// Built without the test target, the verdict says the tests were not counted and how to count them.
    @Test
    func aStoreWithoutTheTestTargetDoesNotClaimZeroTests() async throws {
        let root = try TestSources.makeTempRepo()
        try TestSources.write(
            """
            // swift-tools-version:5.9
            import PackageDescription

            let package = Package(
                name: "Lib",
                targets: [.target(name: "Lib"), .testTarget(name: "LibTests", dependencies: ["Lib"])]
            )
            """,
            to: "Package.swift",
            in: root
        )
        try TestSources.write("public struct Box {\n    public var walk = 1\n    public init() {}\n}\n", to: "Sources/Lib/Box.swift", in: root)
        try TestSources.write("func make() -> Box {\n    Box()\n}\n", to: "Sources/Lib/Maker.swift", in: root)
        try TestSources.write("@testable import Lib\nimport Testing\n\n@Test func reads() {\n    #expect(Box().walk == 1)\n}\n", to: "Tests/LibTests/GadgetTests.swift", in: root)
        try TestSources.commitAll(in: root, message: "seed")
        try await TestSources.swiftBuildSuspending(packageAt: root)

        let engine = try SiftEngine(directory: root)
        try await engine.awaitSemanticStore()
        let output = try await engine.lookup(symbol: "Box", freshness: engine.ensureFresh())
        let verdict = output.split(separator: "\n").first { $0.hasPrefix("used by ") }.map(String.init) ?? ""

        #expect(verdict.contains("production · tests not counted (1 test file has no unit in the store; build with `sift run -- swift build --build-tests`)"), "\(output)")
        #expect(!verdict.contains("0 tests"), "\(output)")
    }

    /// The tally of a split with unbuilt test files: not counted at zero, a lower bound above it, and unchanged where every test file has a unit.
    @Test
    func theTallyNamesWhatItCouldNotCount() {
        var split = WhereRenderer.UsageSplit(production: 3)
        #expect(split.tally == ["3 production", "0 tests"])

        split.unbuiltTestFiles = 2
        split.unbuiltTestBuild = "build the test target"
        #expect(split.tally == ["3 production", "tests not counted (2 test files have no unit in the store; build the test target)"])

        split.tests = 1
        #expect(split.tally == ["3 production", "1 test, a lower bound (2 test files have no unit in the store; build the test target)"])
    }
}
