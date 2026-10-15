//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// Covers what `affected` says per runner about a nested XCTest case and about a repository that only `xcodebuild` runs: the count a whole-target line gives for `swift test`, the limits clause for each runner, and the xcodebuild-only sections.
///
/// Rendered directly from an inventory and a reached set, so a store's provenance can be stated without building one.
@Suite(.temporaryDirectories)
struct AffectedRunnerLowsTests {
    private static let swiftOnly = AffectedRunners(provenance: .swiftPMBuild)
    private static let xcodebuildOnly = AffectedRunners(provenance: .derivedData)

    private static func declared(suite: String, function: String, style: TestSymbol.Style) -> DeclaredTest {
        DeclaredTest(
            target: "LibTests",
            targetWasGuessed: false,
            suite: suite,
            function: function,
            style: style,
            displayName: nil,
            disposition: .runs,
            path: "Tests/LibTests/\(suite).swift",
            line: 1
        )
    }

    /// Two plain tests, one in a nested XCTest case the runtime names, and one in a nested case it cannot.
    private static func inventory() -> TestInventory {
        var inventory = TestInventory(
            tests: [
                declared(suite: "Alpha", function: "one()", style: .swiftTesting),
                declared(suite: "Alpha", function: "two()", style: .swiftTesting),
                declared(suite: "Outer.Inner", function: "testOne()", style: .xcTest),
                declared(suite: "Hidden.Inner", function: "testTwo()", style: .xcTest),
            ],
            guessedTargets: []
        )
        inventory.runtimeCaseNames = ["LibTests/Outer.Inner": "_TtCO8LibTests10ChoreTasks9LampTests"]
        return inventory
    }

    private static func evidence() -> AffectedRenderer.Evidence {
        AffectedRenderer.Evidence(depth: 1, resolved: true, state: .live, path: "Tests/LibTests/Alpha.swift", line: 1)
    }

    private static func reachedTests() -> [TestSymbol: AffectedRenderer.Evidence] {
        let symbols = [
            TestSymbol(target: "LibTests", suite: "Alpha", function: "one", style: .swiftTesting),
            TestSymbol(target: "LibTests", suite: "Outer.Inner", function: "testOne", style: .xcTest),
            TestSymbol(target: "LibTests", suite: "Hidden.Inner", function: "testTwo", style: .xcTest),
        ]
        return Dictionary(uniqueKeysWithValues: symbols.map { ($0, evidence()) })
    }

    private static func sections(runners: AffectedRunners, provenance: DiscoveredStore.Provenance?) -> String {
        AffectedTestSections(
            reached: reachedTests(),
            inventory: inventory(),
            options: AffectedOptions(),
            ways: 6,
            package: "",
            runners: runners,
            provenance: provenance
        ).lines().joined(separator: "\n")
    }

    // MARK: Whole-target count

    /// A nested case's test is counted in "all N" but no `swift test` filter selects it, so the `swift test` command says how many it leaves out.
    @Test
    func theWholeTargetLineSaysHowManyTestsTheSwiftTestFilterLeavesOut() throws {
        let line = try #require(AffectedTargetLines.wholeTarget("LibTests", affected: 4, in: Self.inventory(), runners: Self.swiftOnly))

        #expect(line.hasPrefix("LibTests: all 4 tests — "))
        #expect(line.hasSuffix(", which leaves out 2 in a nested XCTest case"))
        #expect(line.contains("swift test --filter"))
    }

    /// With both runners the clause follows the `swift test` command and not the `xcodebuild` one.
    @Test
    func theClauseSitsAfterTheSwiftTestCommandWhenBothRunnersPrint() throws {
        let line = try #require(AffectedTargetLines.wholeTarget("LibTests", affected: 4, in: Self.inventory(), runners: .both))
        let parts = line.components(separatedBy: " — ")

        #expect(parts.count == 3)
        #expect(parts[1].hasSuffix(", which leaves out 2 in a nested XCTest case"))
        #expect(parts[2].hasPrefix("xcodebuild test"))
        #expect(!parts[2].contains("leaves out"))
    }

    // MARK: xcodebuild only

    @Test
    func anXcodebuildOnlyWholeTargetLineNamesNoSwiftTestCommandAndNoLeftOutClause() throws {
        let line = try #require(AffectedTargetLines.wholeTarget("LibTests", affected: 4, in: Self.inventory(), runners: Self.xcodebuildOnly))

        #expect(line == "LibTests: all 4 tests — xcodebuild test -only-testing:LibTests")
    }

    @Test
    func anXcodebuildOnlyCollapseNamesTheTargetByXcodebuildAlone() {
        let sample = TestSymbol(target: "LibTests", suite: "Alpha", function: "one", style: .swiftTesting)
        let lines = AffectedTargetLines.collapseLines(target: "LibTests", reached: 3, declared: 4, nameMatched: 0, walkedFrom: nil, sample: sample, runners: Self.xcodebuildOnly)

        #expect(lines.count == 2)
        #expect(lines[1] == "    run the target rather than a list: xcodebuild test -only-testing:LibTests")
        #expect(!lines.joined().contains("swift test"))
    }

    @Test
    func anXcodebuildOnlyAnswerListsOneArgumentPerSelectionAndNoSwiftTestSection() {
        let output = Self.sections(runners: Self.xcodebuildOnly, provenance: .derivedData)

        #expect(output.contains("xcodebuild — one argument per selection:"))
        #expect(output.contains("  -only-testing:LibTests/Alpha/one"))
        #expect(output.contains("  -only-testing:LibTests/_TtCO8LibTests10ChoreTasks9LampTests/testOne"))
        #expect(output.contains("xcodebuild commands only"))
        #expect(!output.contains("swift test —"))
        #expect(!output.contains("--filter"))
        #expect(!output.split(separator: "\n").contains { $0.contains("-only-testing:") && $0.contains("Outer.Inner/testOne") }, "the nested case is named by its runtime class, never by its dotted spelling")
    }

    /// The nested case the runtime name cannot be spelt for is left out of the xcodebuild argument list, counted.
    @Test
    func anXcodebuildOnlyAnswerCountsTheNestedTestItCannotName() {
        let output = Self.sections(runners: Self.xcodebuildOnly, provenance: .derivedData)

        #expect(output.contains(AffectedBlindSpots.leftOutOfOnlyTesting(1, noneLeft: false)))
    }

    @Test
    func aSwiftTestOnlyAnswerHasNoXcodebuildSection() {
        let output = Self.sections(runners: Self.swiftOnly, provenance: .swiftPMBuild)

        #expect(output.contains("swift test — SwiftPM matches --filter"))
        #expect(!output.contains("xcodebuild — one argument per selection"))
        #expect(output.contains(AffectedBlindSpots.leftOutOfTheFilter(2)))
    }

    // MARK: Limits block

    private static func limits(runners: AffectedRunners, reached: [TestSymbol: AffectedRenderer.Evidence]) throws -> String {
        let directory = try TemporaryDirectory.make("limits")
        let store = try IndexStore(databasePath: directory.appendingPathComponent("index.db").path)
        let renderer = AffectedRenderer(store: store, repositoryRoot: directory, projectDirectories: [])
        let resolution = AffectedRenderer.Resolution(declarations: [], unreadable: [], summary: [], capped: false)
        return renderer.blindSpots(
            runners: runners,
            headline: (answeredBy: "a test", depthLine: "depth line"),
            resolution: resolution,
            excludedByConfig: [],
            reached: reached,
            capped: false
        ).lines.joined(separator: "\n")
    }

    /// The `-only-testing:` module caveat belongs to an answer that prints an xcodebuild command.
    @Test
    func theModuleNameClauseIsNamedOnlyWhereXcodebuildPrints() throws {
        let reached = Self.reachedTests()

        #expect(try Self.limits(runners: Self.xcodebuildOnly, reached: reached).contains(AffectedBlindSpots.moduleNameClause))
        #expect(try Self.limits(runners: .both, reached: reached).contains(AffectedBlindSpots.moduleNameClause))
        #expect(try !Self.limits(runners: Self.swiftOnly, reached: reached).contains(AffectedBlindSpots.moduleNameClause))
    }

    /// The nested-case clause names the runner whose command is on the page and no other.
    @Test
    func theNestedCaseClauseNamesOnlyTheRunnersThatPrint() throws {
        let nested = Self.reachedTests()
        let swiftOnly = AffectedBlindSpots.nestedXCTestClause(runners: Self.swiftOnly)
        let xcodebuildOnly = AffectedBlindSpots.nestedXCTestClause(runners: Self.xcodebuildOnly)
        let both = AffectedBlindSpots.nestedXCTestClause(runners: .both)

        #expect(swiftOnly == "an XCTest case nested inside another type is selected by no `swift test --filter`")
        #expect(xcodebuildOnly == "an XCTest case nested inside another type is selected by xcodebuild only through its runtime class name")
        #expect(both == "an XCTest case nested inside another type is selected by no `swift test --filter`, and by xcodebuild only through its runtime class name")
        #expect(try Self.limits(runners: Self.swiftOnly, reached: nested).contains(swiftOnly))
        #expect(try Self.limits(runners: Self.xcodebuildOnly, reached: nested).contains(xcodebuildOnly))
        #expect(try !Self.limits(runners: Self.xcodebuildOnly, reached: nested).contains("swift test --filter"))
    }
}
