//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// A test-file declaration SwiftPM's store has no unit for names `swift build --build-tests`, in `where` and `affected` alike; any other declaration without a unit keeps the generic advice.
@Suite(.serialized, .temporaryDirectories)
struct NoUnitRebuildCommandTests {
    /// A test target the last build skipped: `where` on one of its members, and `affected` over a commit that changed it, both name `swift build --build-tests`.
    @Test
    func anUnbuiltTestTargetNamesTheBuildTestsCommandInWhereAndAffected() async throws {
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
        let reads = "\n@Test func reads() {\n    #expect(Holder().probe == 1)\n}\n"
        try TestSources.write("@testable import Lib\nimport Testing\n\nstruct Holder {\n    var probe = Box().walk\n}\n" + reads, to: "Tests/LibTests/GadgetTests.swift", in: root)
        try TestSources.commitAll(in: root, message: "seed")
        try TestSources.write("@testable import Lib\nimport Testing\n\nstruct Holder {\n    var probe = Box().walk * 1\n}\n" + reads, to: "Tests/LibTests/GadgetTests.swift", in: root)
        try TestSources.commitAll(in: root, message: "change")
        // Built after both commits and without the test target, so its files are older than the build and simply have no unit.
        try await TestSources.swiftBuildSuspending(packageAt: root)

        let engine = try SiftEngine(directory: root)
        try await engine.awaitSemanticStore()
        let located = try await engine.lookup(symbol: "Holder.probe", freshness: engine.ensureFresh())
        let affected = try await engine.affected(options: AffectedOptions(range: AffectedOptions.CommitRange(from: "HEAD~1", to: "HEAD")), freshness: engine.ensureFresh())

        let instruction = "; build with `sift run -- swift build --build-tests`, then retry"

        #expect(located.contains(instruction), "\(located)")
        #expect(affected.contains(instruction), "\(affected)")
    }
}
