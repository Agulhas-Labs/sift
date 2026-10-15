//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// Covers how `affected` counts tests in a nested XCTest case on the lines that name a whole target: the collapse line, the target-filter replacement of a long suite list, and a target with no test a filter selects.
struct AffectedNestedCountTests {
    private static let swiftOnly = AffectedRunners(provenance: .swiftPMBuild)
    private static var leftOut: String {
        ", which leaves out 2 in a nested XCTest case"
    }

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

    // MARK: Collapse line

    @Test
    func theCollapseLineSaysHowManyReachedTestsTheSwiftTestFilterLeavesOut() {
        let sample = TestSymbol(target: "LibTests", suite: "Alpha", function: "one", style: .swiftTesting)
        let lines = AffectedTargetLines.collapseLines(target: "LibTests", reached: 4, declared: 6, nameMatched: 0, walkedFrom: nil, sample: sample, runners: Self.swiftOnly, nestedReached: 2)

        #expect(lines[1].hasPrefix("    run the target rather than a list: swift test --filter "))
        #expect(lines[1].hasSuffix(Self.leftOut))
    }

    @Test
    func theCollapseLineHasNoClauseWhereNoReachedTestIsNested() {
        let sample = TestSymbol(target: "LibTests", suite: "Alpha", function: "one", style: .swiftTesting)
        let lines = AffectedTargetLines.collapseLines(target: "LibTests", reached: 4, declared: 6, nameMatched: 0, walkedFrom: nil, sample: sample, runners: Self.swiftOnly)

        #expect(!lines[1].contains("leaves out"))
    }

    // MARK: Target-filter replacement

    @Test
    func theTargetFilterReplacementCountsOnlyTheTestsTheFilterRuns() {
        let tests = (0 ..< 80).map { TestSymbol(target: "LibTests", suite: "GizmoCore\($0)" + String(repeating: "x", count: 30), function: "check", style: .swiftTesting) }
        let counts = AffectedTargetLines.TargetCounts(target: "LibTests", declared: 100, affected: 85, nested: 10, affectedNested: 5)
        let commands = AffectedTargetLines.suiteCommandLines(for: tests, in: nil, runners: Self.swiftOnly, target: counts)
        let line = commands.lines.first { $0.contains("run the target") }

        #expect(line?.hasSuffix("— all 90 of its tests, 10 beyond the 80 affected") == true)
    }

    // MARK: Every test nested

    @Test
    func aTargetWithOnlyNestedTestsIsNamedByTheBareRunnerCommand() throws {
        let inventory = TestInventory(
            tests: [
                Self.declared(suite: "Outer.Inner", function: "testOne()", style: .xcTest),
                Self.declared(suite: "Hidden.Inner", function: "testTwo()", style: .xcTest),
            ],
            guessedTargets: []
        )
        let line = try #require(AffectedTargetLines.wholeTarget("LibTests", affected: 2, in: inventory, runners: Self.swiftOnly))

        #expect(line == "LibTests: all 2 tests — swift test, the whole suite: every test of LibTests is in a nested XCTest case, which no filter selects")
    }

    @Test
    func theCollapseLineNamesTheBareRunnerWhereEveryDeclaredTestIsNestedThoughFewerAreReached() {
        let sample = TestSymbol(target: "LibTests", suite: "Outer.Inner", function: "testOne", style: .xcTest)
        let lines = AffectedTargetLines.collapseLines(target: "LibTests", reached: 12, declared: 20, nameMatched: 0, walkedFrom: nil, sample: sample, runners: Self.swiftOnly, nestedReached: 12, nestedDeclared: 20)

        #expect(lines[1] == "    run the target rather than a list: swift test, the whole suite: every test of LibTests is in a nested XCTest case, which no filter selects")
    }

    @Test
    func aTargetWithSomeNestedTestsStillNamesTheFilter() throws {
        let inventory = TestInventory(
            tests: [
                Self.declared(suite: "Alpha", function: "one()", style: .swiftTesting),
                Self.declared(suite: "Outer.Inner", function: "testOne()", style: .xcTest),
            ],
            guessedTargets: []
        )
        let line = try #require(AffectedTargetLines.wholeTarget("LibTests", affected: 2, in: inventory, runners: Self.swiftOnly))

        #expect(line.contains("--filter"))
        #expect(line.hasSuffix(", which leaves out 1 in a nested XCTest case"))
    }
}
