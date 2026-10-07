//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// A test build that ran leaves no build advice behind for a test file outside every target.
///
/// A file importing `Testing` that no target builds has no unit after any build, so advising a test build for it repeated on every answer however often it was followed; it is named as outside any built target instead, and still never read as `0 tests`.
@Suite(.serialized, .temporaryDirectories)
struct WhereUnbuiltTestsStrayFileTests {
    /// Built with its tests, a package with one stray test file: the tally and the zero-use verdict name the file as outside any built target, advise no build, and the header is not partial.
    @Test
    func aStrayTestFileIsNamedOutsideAnyBuiltTarget() async throws {
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
        try TestSources.write("public struct Box {\n    public var walk = 1\n    public var idle = 0\n    public init() {}\n}\n", to: "Sources/Lib/Box.swift", in: root)
        try TestSources.write("func make() -> Box {\n    Box()\n}\n", to: "Sources/Lib/Maker.swift", in: root)
        try TestSources.write("@testable import Lib\nimport Testing\n\n@Test func reads() {\n    #expect(Box().walk == 1)\n}\n", to: "Tests/LibTests/GadgetTests.swift", in: root)
        try TestSources.write("@testable import Lib\nimport Testing\n\n@Test func strays() {\n    #expect(Box().walk == 1)\n}\n", to: "Fixtures/BetaTests.swift", in: root)
        try TestSources.commitAll(in: root, message: "seed")
        try await TestSources.swiftBuildSuspending(packageAt: root, includingTests: true)

        let engine = try SiftEngine(directory: root)
        try await engine.awaitSemanticStore()
        let type = try await engine.lookup(symbol: "Box", freshness: engine.ensureFresh())
        let property = try await engine.lookup(symbol: "Box.idle", freshness: engine.ensureFresh())
        let verdict = type.split(separator: "\n").first { $0.hasPrefix("used by ") }.map(String.init) ?? ""

        #expect(verdict.contains("production · 1 test, a lower bound (1 test file outside any built target)"), "\(type)")
        #expect(property.contains("no reads or writes of Lib.Box.idle recorded in the store; not counting 1 test file outside any built target"), "\(property)")
        for answer in [type, property] {
            #expect(!answer.contains("build with `sift run -- swift build --build-tests`"), "\(answer)")
            #expect(!answer.contains("partial ("), "\(answer)")
        }
    }
}
