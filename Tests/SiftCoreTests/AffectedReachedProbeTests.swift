//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// Covers `affected --reached`: a test the lists cut off is still answered for, and one the walk never reached is said not to have been.
///
/// No build: the name-match fallback reaches these tests, which is all the probe needs.
@Suite(.temporaryDirectories)
struct AffectedReachedProbeTests {
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

    private static func suite(_ name: String, tests count: Int) -> String {
        let tests = (0 ..< count).map { "    @Test func uses\($0)() { _ = Widget() }" }.joined(separator: "\n")
        return "import Testing\n@testable import Lib\n\nstruct \(name) {\n\(tests)\n}\n"
    }

    /// Thirty tests in three suites, so the last suite's tests fall past the printed prefix, asked about with and without a probe.
    private static func answers(probing name: String) async throws -> (plain: String, probed: String) {
        let root = try TestSources.makeTempRepo()
        try TestSources.write(manifest(), to: "Package.swift", in: root)
        try TestSources.write("public struct Widget {\n    public init() {}\n}\n", to: "Sources/Lib/Core.swift", in: root)
        for (suite, count) in [("AlphaTests", 14), ("BetaTests", 12), ("GadgetTests", 4)] {
            try TestSources.write(Self.suite(suite, tests: count), to: "Tests/LibTests/\(suite).swift", in: root)
        }
        try TestSources.commitAll(in: root, message: "fixture")
        try TestSources.write("public struct Widget {\n    public init() {}\n    public func shine() {}\n}\n", to: "Sources/Lib/Core.swift", in: root)
        let engine = try SiftEngine(directory: root)
        try await engine.awaitSemanticStore()
        let freshness = try await engine.ensureFresh()
        let plain = try await engine.affected(options: AffectedOptions(), freshness: freshness)
        let probed = try await engine.affected(options: AffectedOptions(probes: [name]), freshness: freshness)
        return (plain, probed)
    }

    /// A test hidden by the list cap is answered with its hop count and where it was found.
    @Test
    func aTestPastTheListCapIsAnsweredWithItsHops() async throws {
        let (plain, probed) = try await Self.answers(probing: "LibTests.GadgetTests/uses3()")

        #expect(!plain.contains("reached?"))
        #expect(!plain.contains("LibTests.GadgetTests/uses3()"))
        #expect(probed.contains("reached? LibTests.GadgetTests/uses3() — 1 match, within 2 reference hops:"))
        #expect(probed.contains("  LibTests.GadgetTests/uses3() — 1 hop, name match — Tests/LibTests/GadgetTests.swift:"))
    }

    /// A name the walk did not reach is said not to have been reached, and not to be unaffected.
    @Test
    func aTestTheWalkNeverReachedIsSaidNotToBeReached() async throws {
        let (_, probed) = try await Self.answers(probing: "LibTests.GizmoTests")

        #expect(probed.contains("reached? LibTests.GizmoTests — not reached within 2 reference hops."))
        #expect(probed.contains("not evidence that it is unaffected"))
    }
}
