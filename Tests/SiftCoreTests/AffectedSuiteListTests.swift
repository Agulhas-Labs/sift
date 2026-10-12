//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// Covers the suite commands under a partly affected target past the cap: one line per runner naming every affected suite, built from all the target's affected tests, with the tests no suite selects counted.
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

    /// A suite no test of which names `Widget`, so it is declared in the target and never reached: it keeps the reached tests under half of what the target declares, where the suite commands are given.
    private static func idle(tests count: Int) -> String {
        let tests = (0 ..< count).map { "    @Test func idle\($0)() {}" }.joined(separator: "\n")
        return "import Testing\n\nstruct Orchard {\n\(tests)\n}\n"
    }

    /// A target past the per-test cap gives one command per runner naming every affected suite, and counts the tests no suite filter selects.
    @Test
    func aTargetPastTheCapGivesTheCommandsThatRunExactlyItsAffectedSuites() async throws {
        let output = try await Self.affected(testFiles: [
            "AlphaTests": Self.suite("AlphaTests", tests: 14),
            "BetaTests": Self.suite("BetaTests", tests: 12),
            "GadgetTests": Self.suite("GadgetTests", tests: 6),
            "Orchard": Self.idle(tests: 60),
            "Loose": "import Testing\n@testable import Lib\n\n@Test func aTest() { _ = Widget() }\n",
            "Chores": "import XCTest\n@testable import Lib\n\nenum ChoreTasks {\n    final class LampTests: XCTestCase {\n        func testOne() { _ = Widget() }\n    }\n}\n",
        ])

        #expect(output.contains("the commands below run exactly the affected suites"))
        #expect(output.contains(#"    to run just these 3 suites: swift test --filter '^LibTests\.AlphaTests(/|$)' --filter '^LibTests\.BetaTests(/|$)' --filter '^LibTests\.GadgetTests(/|$)'"#))
        #expect(output.contains("    to run just these 4 suites: xcodebuild test -only-testing:LibTests/AlphaTests -only-testing:LibTests/BetaTests -only-testing:LibTests/GadgetTests -only-testing:LibTests/_TtCO8LibTests10ChoreTasks9LampTests"))
        #expect(!output.contains("LibTests.GadgetTests/uses0()"))
        #expect(!output.contains("affected suites in this target"))
        #expect(output.contains("      left out: 1 test declared outside any suite, which only the whole target's filter selects"))
        #expect(output.contains("      left out of the swift test line: 1 test in a nested XCTest case, which no swift test filter selects (the xcodebuild line names it by its runtime name; see the limits above)"))
    }

    /// However many suites there are, each runner gets one complete line and no per-suite row follows it.
    @Test
    func aLongSuiteListStaysOnOneLinePerRunnerWithNoRows() async throws {
        let count = AffectedRenderer.testListCap + 15
        // One file, because a name written in more files than the fallback's evidence cap stops counting as evidence.
        let suites = (0 ..< count).map { Self.declaration("Suite\($0)Tests", tests: 1) }.joined(separator: "\n")
        let output = try await Self.affected(testFiles: [
            "GizmoTests": "import Testing\n@testable import Lib\n\n" + suites,
            "Orchard": Self.idle(tests: count * 3),
        ])

        #expect(output.split(separator: "\n").filter { $0.hasPrefix("      LibTests.") }.isEmpty)
        #expect(!output.contains("truncated: "))
        let swiftLine = try #require(output.split(separator: "\n").first { $0.hasPrefix("    to run just these \(count) suites: swift test ") })
        #expect(swiftLine.components(separatedBy: "--filter").count - 1 == count)
        let xcodebuildLine = try #require(output.split(separator: "\n").first { $0.hasPrefix("    to run just these \(count) suites: xcodebuild test ") })
        #expect(xcodebuildLine.components(separatedBy: "-only-testing:LibTests/").count - 1 == count)
    }

    /// A nested XCTest case is no `--filter` suite, but the xcodebuild line names it by its runtime class name, as the footers do, rather than dropping it.
    @Test
    func aNestedXCTestCaseIsNamedByItsRuntimeNameOnTheXcodebuildLineOnly() async throws {
        let output = try await Self.affected(testFiles: [
            "AlphaTests": Self.suite("AlphaTests", tests: AffectedRenderer.testListCap + 5),
            "Chores": "import XCTest\n@testable import Lib\n\nenum ChoreTasks {\n    final class LampTests: XCTestCase {\n        func testOne() { _ = Widget() }\n    }\n}\n",
            "Orchard": Self.idle(tests: 80),
        ])

        let swiftLine = output.split(separator: "\n").first { $0.hasPrefix("    to run just these 1 suite: swift test ") }

        #expect(swiftLine != nil)
        #expect(swiftLine?.contains("ChoreTasks") == false)
        #expect(output.contains("    to run just these 2 suites: xcodebuild test -only-testing:LibTests/AlphaTests -only-testing:LibTests/_TtCO8LibTests10ChoreTasks9LampTests"))
    }
}
