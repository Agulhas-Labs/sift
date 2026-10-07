//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// Covers the count a Swift Testing suite reached whole stands for in an answer that reached no XCTest case, which is the one answer that used to read no inventory.
///
/// No build: the name-match fallback reaches the suite, which is all the count needs.
@Suite(.temporaryDirectories)
struct AffectedWholeSwiftTestingSuiteTests {
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

    /// A suite of four tests holding a `Widget` as a stored property is reached whole, and is counted as the four tests it runs, in the headline, the target line and the suite's own line.
    @Test
    func aSwiftTestingSuiteReachedWholeIsCountedByItsTests() async throws {
        let root = try TestSources.makeTempRepo()
        try TestSources.write(Self.manifest(), to: "Package.swift", in: root)
        try TestSources.write("public struct Widget {\n    public init() {}\n}\n", to: "Sources/Lib/Core.swift", in: root)
        let tests = (0 ..< 4).map { "    @Test func case\($0)() {}" }.joined(separator: "\n")
        try TestSources.write(
            "import Testing\n@testable import Lib\n\nstruct LampTests {\n    let widget = Widget()\n\(tests)\n}\n",
            to: "Tests/LibTests/LampTests.swift",
            in: root
        )
        try TestSources.commitAll(in: root, message: "fixture")
        try TestSources.write("public struct Widget {\n    public init() {}\n    public func shine() {}\n}\n", to: "Sources/Lib/Core.swift", in: root)
        let engine = try SiftEngine(directory: root)
        try await engine.awaitSemanticStore()
        let freshness = try await engine.ensureFresh()

        let output = try await engine.affected(options: AffectedOptions(), freshness: freshness)

        #expect(output.contains("affected tests (4 in 1 target):"))
        #expect(output.contains("  LibTests — 4 tests"))
        #expect(output.contains("    LibTests.LampTests — 1 hop"))
    }
}
