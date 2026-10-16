//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// Pins, end to end through the engine, that `affected` hands the nested XCTest counts to the lines of a target past the list cap: the collapse lines, the partly affected target's line, and the xcodebuild line that replaces a long suite list.
///
/// No build: the name-match fallback reaches these tests, which is all the counts need.
@Suite(.temporaryDirectories)
struct AffectedNestedWiringTests {
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

    /// A repository whose test target has one file per entry, each naming `Widget`, with the change to `Widget` left uncommitted.
    private static func affected(testFiles: [String: String]) async throws -> String {
        let root = try TestSources.makeTempRepo()
        try TestSources.write(manifest(), to: "Package.swift", in: root)
        try TestSources.write("public struct Widget {\n    public init() {}\n}\n", to: "Sources/Lib/Core.swift", in: root)
        for (name, source) in testFiles {
            try TestSources.write(source, to: "Tests/LibTests/\(name).swift", in: root)
        }
        try TestSources.commitAll(in: root, message: "fixture")
        try TestSources.write("public struct Widget {\n    public init() {}\n    public func shine() {}\n}\n", to: "Sources/Lib/Core.swift", in: root)
        let engine = try SiftEngine(directory: root)
        try await engine.awaitSemanticStore()
        let freshness = try await engine.ensureFresh()
        return try await engine.affected(options: AffectedOptions(range: nil, depth: AffectedOptions.defaultDepth), freshness: freshness)
    }

    /// `count` Swift Testing suites of one test each, all naming `Widget`, in one file because a name written in more files than the fallback's evidence cap stops counting as evidence.
    private static func suites(_ count: Int) -> String {
        let body = (0 ..< count).map { "struct Suite\($0)Tests {\n    @Test func uses() { _ = Widget() }\n}\n" }.joined(separator: "\n")
        return "import Testing\n@testable import Lib\n\n" + body
    }

    /// `count` XCTest cases nested in one enum, one test each, all naming `Widget`.
    private static func nestedCases(_ count: Int) -> String {
        let body = (0 ..< count).map { "    final class Lamp\($0)Tests: XCTestCase {\n        func testOne() { _ = Widget() }\n    }\n" }.joined(separator: "\n")
        return "import XCTest\n@testable import Lib\n\nenum ChoreTasks {\n\(body)}\n"
    }

    /// Tests no change reaches, so the target declares more than it is reached by.
    private static func idle(tests count: Int) -> String {
        let tests = (0 ..< count).map { "    @Test func idle\($0)() {}" }.joined(separator: "\n")
        return "import Testing\n\nstruct Orchard {\n\(tests)\n}\n"
    }

    private static func line(_ output: String, prefix: String) -> String? {
        output.split(separator: "\n").first { $0.hasPrefix(prefix) }.map(String.init)
    }

    /// Where half the target or more is reached, the collapse lines count the nested tests the reached ones include.
    @Test
    func theCollapseLinesCountTheNestedTests() async throws {
        let output = try await Self.affected(testFiles: [
            "GizmoTests": Self.suites(AffectedRenderer.testListCap + 5),
            "Chores": Self.nestedCases(2),
            "Orchard": Self.idle(tests: 4),
        ])

        #expect(output.contains("  LibTests: could not narrow below the target — 32 of its 36 tests are reached"))
        let command = try #require(Self.line(output, prefix: "    run the target rather than a list: "))
        #expect(command.contains(", which leaves out 2 in a nested XCTest case"))
        #expect(command.contains("xcodebuild test -only-testing:LibTests"))
    }

    /// Where under half is reached, the swift test line that replaces a long suite list leaves the nested tests out of both counts, and the xcodebuild line keeps them.
    @Test
    func thePartlyAffectedTargetLinesCountTheNestedTests() async throws {
        let output = try await Self.affected(testFiles: [
            "GizmoTests": Self.suites(70),
            "Chores": Self.nestedCases(2),
            "Orchard": Self.idle(tests: 300),
        ])

        let swiftLine = try #require(Self.line(output, prefix: "    to run them, run the target: swift test "))
        let xcodebuildLine = try #require(Self.line(output, prefix: "    to run them, run the target: xcodebuild test "))

        #expect(swiftLine.hasSuffix("— all 370 of its tests, 300 beyond the 70 affected"))
        #expect(xcodebuildLine.hasSuffix("— all 372 of its tests, 300 beyond the 72 affected"))
    }

    /// Where the xcodebuild suite list is replaced by the target's filter, which runs the nested cases, the answer counts them in that line and leaves them out of the swift test line only.
    @Test
    func aReplacedXcodebuildLineRunsTheNestedTestsAndOnlyTheSwiftLineLeavesThemOut() async throws {
        let output = try await Self.affected(testFiles: [
            "GizmoTests": Self.suites(3),
            "Chores": Self.nestedCases(60),
            "Orchard": Self.idle(tests: 100),
        ])

        let xcodebuildLine = try #require(Self.line(output, prefix: "    to run them, run the target: xcodebuild test "))

        #expect(xcodebuildLine.hasSuffix("— all 163 of its tests, 100 beyond the 63 affected"))
        #expect(output.contains("    to run just these 3 suites: swift test "))
        #expect(output.contains("      left out of the swift test line: 60 tests in a nested XCTest case, which no swift test filter selects (the xcodebuild line runs the whole target)"))
        #expect(!output.contains("      left out: "))
        #expect(!output.contains("names it by its runtime name"))
        #expect(!output.split(separator: "\n").contains { $0.hasPrefix("      left out") && $0.contains("which no filter selects") })
    }

    /// Where no plain suite is affected, no swift test line prints, so the answer names no such line, in a note or otherwise.
    @Test
    func aReplacedXcodebuildLineWithNoPlainSuiteNamesNoSwiftTestLine() async throws {
        let output = try await Self.affected(testFiles: [
            "Chores": Self.nestedCases(60),
            "Orchard": Self.idle(tests: 200),
        ])

        #expect(output.contains("xcodebuild test "))
        #expect(!output.contains("to run just these"))
        #expect(!output.contains("swift test line"))
    }

    /// Where every test of the target is in a nested XCTest case, the collapse line names the bare `swift test`, since a filter would run nothing; the declared nested count decides that.
    @Test
    func theCollapseLineOfATargetOfOnlyNestedCasesNamesTheBareSwiftTest() async throws {
        let output = try await Self.affected(testFiles: [
            "Chores": Self.nestedCases(AffectedRenderer.testListCap + 5),
            "Quiet": "import XCTest\n\nenum ChoreTasks {\n    final class Orchard: XCTestCase {\n        func testOne() {}\n    }\n}\n",
        ])

        let command = try #require(Self.line(output, prefix: "    run the target rather than a list: "))

        #expect(command.contains(", the whole suite: every test of LibTests is in a nested XCTest case, which no filter selects"))
        #expect(!command.contains("--filter"))
    }
}
