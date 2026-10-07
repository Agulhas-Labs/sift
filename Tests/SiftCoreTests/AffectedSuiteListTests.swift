//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// Covers the suite list under a target `affected` names whole: every affected suite with the filter that selects it, built from all the target's affected tests rather than the printed ones, capped and counted, and never one pasteable line.
///
/// No build: the name-match fallback reaches these tests, which is all the list's shape needs.
@Suite(.temporaryDirectories)
struct AffectedSuiteListTests {
    private static var changedWidget: String {
        "public struct Widget {\n    public init() {}\n    public func shine() {}\n}\n"
    }

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

    /// A repository whose test target has one file per entry, each naming `Widget` in every test, with the change to `Widget` left uncommitted.
    private static func affected(testFiles: [String: String]) async throws -> String {
        let root = try TestSources.makeTempRepo()
        try TestSources.write(manifest(), to: "Package.swift", in: root)
        try TestSources.write("public struct Widget {\n    public init() {}\n}\n", to: "Sources/Lib/Core.swift", in: root)
        for (name, source) in testFiles {
            try TestSources.write(source, to: "Tests/LibTests/\(name).swift", in: root)
        }
        try TestSources.commitAll(in: root, message: "fixture")
        try TestSources.write(changedWidget, to: "Sources/Lib/Core.swift", in: root)
        let engine = try SiftEngine(directory: root)
        try await engine.awaitSemanticStore()
        let freshness = try await engine.ensureFresh()
        return try await engine.affected(options: AffectedOptions(range: nil, depth: AffectedOptions.defaultDepth), freshness: freshness)
    }

    private static func suite(_ name: String, tests count: Int) -> String {
        "import Testing\n@testable import Lib\n\n" + declaration(name, tests: count)
    }

    private static func declaration(_ name: String, tests count: Int) -> String {
        let tests = (0 ..< count).map { "    @Test func uses\($0)() { _ = Widget() }" }.joined(separator: "\n")
        return "struct \(name) {\n\(tests)\n}\n"
    }

    /// A target past the per-test cap lists every affected suite with its count and filter, including the suite whose tests all fall past the printed prefix, and counts the tests no suite filter selects.
    @Test
    func aTargetNamedWholeListsEveryAffectedSuiteWithTheFilterThatSelectsIt() async throws {
        let output = try await Self.affected(testFiles: [
            "AlphaTests": Self.suite("AlphaTests", tests: 14),
            "BetaTests": Self.suite("BetaTests", tests: 12),
            "GadgetTests": Self.suite("GadgetTests", tests: 6),
            "Loose": "import Testing\n@testable import Lib\n\n@Test func aTest() { _ = Widget() }\n",
            "Chores": "import XCTest\n@testable import Lib\n\nenum ChoreTasks {\n    final class LampTests: XCTestCase {\n        func testOne() { _ = Widget() }\n    }\n}\n",
        ])

        #expect(output.contains("more than this list prints, so the whole target is named below"))
        #expect(output.contains("    affected suites in this target (3), each with the filter that selects it:"))
        #expect(output.contains(#"      LibTests.AlphaTests — 14 tests — --filter 'LibTests\.AlphaTests'"#))
        #expect(output.contains(#"      LibTests.BetaTests — 12 tests — --filter 'LibTests\.BetaTests'"#))
        // None of GadgetTests' tests is among the printed ones, which is the case the list exists for.
        #expect(!output.contains("LibTests.GadgetTests/uses0()"))
        #expect(output.contains(#"      LibTests.GadgetTests — 6 tests — --filter 'LibTests\.GadgetTests'"#))
        #expect(output.contains("      left out: 1 test declared outside any suite, which only the whole target's filter selects"))
        #expect(output.contains("      left out: 1 test in a nested XCTest case, which no filter selects (see the limits above)"))
    }

    /// Past the suite cap the rest are counted, and no line joins the suites into one command that would look complete.
    @Test
    func aSuiteListPastItsCapCountsTheRestAndNeverJoinsThemIntoOneLine() async throws {
        let count = AffectedRenderer.suiteListCap + 3
        // One file, because a name written in more files than the fallback's evidence cap stops counting as evidence.
        let suites = (0 ..< count).map { Self.declaration("Suite\($0)Tests", tests: 1) }.joined(separator: "\n")
        let output = try await Self.affected(testFiles: ["GizmoTests": "import Testing\n@testable import Lib\n\n" + suites])

        #expect(output.contains("    affected suites in this target (\(count)), each with the filter that selects it:"))
        #expect(output.contains("      truncated: 3 more suites in this target"))
        let suiteLines = output.split(separator: "\n").filter { $0.hasPrefix("      LibTests.") }
        #expect(suiteLines.count == AffectedRenderer.suiteListCap)
        #expect(!output.split(separator: "\n").contains { $0.components(separatedBy: "--filter").count > 2 })
    }
}
