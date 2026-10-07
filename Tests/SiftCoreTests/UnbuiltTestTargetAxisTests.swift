//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// A store holding a package's library but not its test target, which is what a plain `swift build` leaves: the store records no reference from a test, so an answer about tests read from it alone is a lower bound and must say so rather than read `fresh`.
@Suite(.serialized, .temporaryDirectories)
struct UnbuiltTestTargetAxisTests {
    /// A library change a test reaches, built without `--build-tests`: `affected` and `diff` read `partial`, say which build adds the test files, and still list the test, as a name match; `where` on the changed type reads `partial` too.
    @Test
    func aStoreWithoutTheTestTargetReadsPartialAndNameMatchesTheTests() async throws {
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
        try TestSources.write("@testable import Lib\nimport Testing\n\n@Test func reads() {\n    #expect(Box().walk == 1)\n}\n", to: "Tests/LibTests/GadgetTests.swift", in: root)
        try TestSources.commitAll(in: root, message: "seed")
        try TestSources.write("public struct Box {\n    public var walk = 2\n    public init() {}\n}\n", to: "Sources/Lib/Box.swift", in: root)
        try TestSources.commitAll(in: root, message: "change")
        // Built after both commits and without the test target, so the library is fresh and the test file simply has no unit.
        try await TestSources.swiftBuildSuspending(packageAt: root)

        let engine = try SiftEngine(directory: root)
        try await engine.awaitSemanticStore()
        let affected = try await engine.affected(options: AffectedOptions(range: AffectedOptions.CommitRange(from: "HEAD~1", to: "HEAD")), freshness: engine.ensureFresh())
        let diff = try await DiffEngineTests.diff(root, range: "HEAD~1..HEAD")
        let located = try await engine.lookup(symbol: "Box", freshness: engine.ensureFresh())
        let partial = "semantic: partial (1 test file has no unit in the store — references from tests are a lower bound)"

        #expect(affected.contains(partial), "\(affected)")
        #expect(affected.contains("test files without a unit: 1 test file has no unit in the store"), "\(affected)")
        #expect(affected.contains("build it with `sift run -- swift build --build-tests`"), "\(affected)")
        #expect(affected.split(separator: "\n").contains { $0.contains("reads()") && $0.contains("name match") }, "\(affected)")
        #expect(diff.contains(partial), "\(diff)")
        #expect(diff.contains("reads()"), "\(diff)")
        #expect(located.contains(partial), "\(located)")
    }
}
