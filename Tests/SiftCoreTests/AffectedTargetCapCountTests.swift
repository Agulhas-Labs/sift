//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// Covers the three counts a target past the per-test cap prints — its own line, the line naming it whole, and the truncation line — when a whole suite falls past the cap.
///
/// No build: the name-match fallback reaches each test through its body and the whole suite through its stored property.
@Suite(.temporaryDirectories)
struct AffectedTargetCapCountTests {
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

    private static func suite(_ name: String, tests count: Int, holdsWidget: Bool) -> String {
        let body = holdsWidget ? "" : " _ = Widget() "
        let tests = (0 ..< count).map { "    @Test func case\($0)() {\(body)}" }.joined(separator: "\n")
        let property = holdsWidget ? "    let widget = Widget()\n" : ""
        return "import Testing\n@testable import Lib\n\nstruct \(name) {\n\(property)\(tests)\n}\n"
    }

    /// Twenty-six tests reached one by one and an eight-test suite reached whole, which sorts last: twenty-seven rows, thirty-four tests, nine of them past the cap.
    @Test
    func aTargetPastTheCapCountsTestsOnEveryLine() async throws {
        let root = try TestSources.makeTempRepo()
        try TestSources.write(Self.manifest(), to: "Package.swift", in: root)
        try TestSources.write("public struct Widget {\n    public init() {}\n}\n", to: "Sources/Lib/Core.swift", in: root)
        for (name, count, holdsWidget) in [("AlphaTests", 14, false), ("BetaTests", 12, false), ("WidgetTests", 8, true)] {
            try TestSources.write(Self.suite(name, tests: count, holdsWidget: holdsWidget), to: "Tests/LibTests/\(name).swift", in: root)
        }
        try TestSources.commitAll(in: root, message: "fixture")
        try TestSources.write("public struct Widget {\n    public init() {}\n    public func shine() {}\n}\n", to: "Sources/Lib/Core.swift", in: root)
        let engine = try SiftEngine(directory: root)
        try await engine.awaitSemanticStore()
        let freshness = try await engine.ensureFresh()

        let output = try await engine.affected(options: AffectedOptions(), freshness: freshness)

        #expect(output.contains("affected tests (34 in 1 target):"))
        #expect(output.contains("  LibTests — 34 tests"))
        #expect(output.contains("    34 tests affected — more than this list prints"))
        #expect(output.contains("    truncated: 9 more tests in this target"))
        #expect(output.contains("      LibTests.WidgetTests — 8 tests — --filter 'LibTests\\.WidgetTests'"))
    }
}
