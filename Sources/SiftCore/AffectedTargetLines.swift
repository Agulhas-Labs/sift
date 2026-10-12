//
// Copyright © Agulhas Labs
//

import Foundation

/// The lines `affected` names a target past its list cap by: whole, or by the commands that run exactly its affected suites, and how many tests one listed entry stands for.
struct AffectedTargetLines {
    /// The one line a target whose every test is affected is named by, with its count and the commands that run it, or `nil` where the inventory is unknown or declares tests the answer did not reach.
    ///
    /// The suites are not listed: all of them are affected, so the list would say what the command already does.
    static func wholeTarget(_ target: String, affected: Int, in inventory: TestInventory?, package: String = "") -> String? {
        guard let inventory else { return nil }
        let declared = inventory.tests.filter { $0.target == target }
        guard !declared.isEmpty, affected >= declared.count else { return nil }
        let filter = TestSymbol.anchoredTargetFilter(target)
        let only = TestSymbol(target: target, suite: nil, function: nil, style: .swiftTesting).onlyTestingArgument
        return "\(target): all \(declared.count) test\(declared.count == 1 ? "" : "s") — \(DiscoveredStore.swiftPMTestCommand(package: package)) --filter '\(filter)' — xcodebuild test \(only)"
    }

    /// What the after-edit walk walked from, for ``collapseLines(target:reached:declared:nameMatched:walkedFrom:sample:package:)``.
    static func walkedFromClause(count: Int, listed: String, scanned: Int) -> String {
        "the \(count) touched name\(count == 1 ? "" : "s") (\(listed)), \(scanned) name\(scanned == 1 ? "" : "s") over every hop"
    }

    /// The two lines a target past the list cap is named by when half its tests or more are reached: that it could not be narrowed, and the one command per runner that runs it.
    ///
    /// Printed on every path. The clause naming the walk is given only where every reached test rests on a name match from the after-edit walk, and says which names it walked from.
    static func collapseLines(target: String, reached: Int, declared: Int, nameMatched: Int, walkedFrom: String?, sample: TestSymbol, package: String = "") -> [String] {
        let why = walkedFrom.map { "are reached by name match from \($0)" } ?? (nameMatched == 0 ? "are reached" : "are reached, \(nameMatched) of them by name match")
        return [
            "  \(target): could not narrow below the target — \(reached) of its \(declared) tests \(why)",
            "    run the target rather than a list: \(DiscoveredStore.swiftPMTestCommand(package: package)) --filter '\(TestSymbol.anchoredTargetFilter(target))' — xcodebuild test \(sample.targetOnly.onlyTestingArgument)",
        ]
    }

    /// The commands that run exactly the affected suites of a partly affected target past the cap, one line per runner, and a count of the tests no suite selects.
    ///
    /// Built from every affected test in the target. The lines are what a caller pastes, so they are complete however long.
    static func suiteCommandLines(for tests: [TestSymbol], in inventory: TestInventory?, package: String = "") -> [String] {
        var suites: Set<TestSymbol> = []
        var nestedSuites: Set<TestSymbol> = []
        var outsideAnySuite = 0
        var nestedNamed = 0
        var nestedUnnamed = 0
        let runtimeCaseNames = inventory?.runtimeCaseNames ?? [:]
        for test in tests {
            let count = testCount(of: test, in: inventory)
            if test.suite == nil {
                outsideAnySuite += count
            } else if test.swiftTestFilterSelectsNothing {
                // No `swift test` filter selects it, but `xcodebuild` does by the case's runtime name, where the inventory has one.
                if test.suiteOnly.onlyTestingArgument(runtimeCaseNames: runtimeCaseNames) != nil {
                    nestedSuites.insert(test.suiteOnly)
                    nestedNamed += count
                } else {
                    nestedUnnamed += count
                }
            } else {
                suites.insert(test.suiteOnly)
            }
        }
        let sorted = suites.sorted()
        let xcodebuildArguments = (sorted + nestedSuites.sorted()).compactMap { $0.onlyTestingArgument(runtimeCaseNames: runtimeCaseNames) }
        let swiftNoun = "\(sorted.count) suite\(sorted.count == 1 ? "" : "s")"
        let xcodebuildNoun = "\(xcodebuildArguments.count) suite\(xcodebuildArguments.count == 1 ? "" : "s")"
        var lines: [String] = []
        if !sorted.isEmpty {
            lines.append("    to run just these \(swiftNoun): " + DiscoveredStore.swiftPMTestCommand(package: package) + " " + sorted.map { "--filter '\($0.anchoredSwiftTestFilter)'" }.joined(separator: " "))
        }
        if !xcodebuildArguments.isEmpty {
            lines.append("    to run just these \(xcodebuildNoun): xcodebuild test " + xcodebuildArguments.joined(separator: " "))
        }
        if lines.isEmpty {
            lines = ["    no affected suite in this target has a filter of its own"]
        }
        if outsideAnySuite > 0 {
            lines.append("      left out: \(outsideAnySuite) test\(outsideAnySuite == 1 ? "" : "s") declared outside any suite, which only the whole target's filter selects")
        }
        if nestedNamed > 0 {
            lines.append("      left out of the swift test line: \(nestedNamed) test\(nestedNamed == 1 ? "" : "s") in a nested XCTest case, which no swift test filter selects (the xcodebuild line names it by its runtime name; see the limits above)")
        }
        if nestedUnnamed > 0 {
            lines.append("      left out: \(nestedUnnamed) test\(nestedUnnamed == 1 ? "" : "s") in a nested XCTest case, which no filter selects (see the limits above)")
        }
        return lines
    }

    /// How many tests one listed entry stands for: one for a test, and for a whole suite every test the inventory declares it to run, a Swift Testing suite's nested suites included.
    static func testCount(of test: TestSymbol, in inventory: TestInventory?) -> Int {
        guard test.function == nil, test.suite != nil, let inventory else { return 1 }
        return inventory.tests.count { test.wholeSuiteRuns(TestSymbol(declared: $0)) }
    }
}
