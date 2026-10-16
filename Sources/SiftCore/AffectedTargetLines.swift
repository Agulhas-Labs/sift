//
// Copyright © Agulhas Labs
//

import Foundation

/// The lines `affected` names a target past its list cap by: whole, or by the commands that run exactly its affected suites, and how many tests one listed entry stands for.
struct AffectedTargetLines {
    /// The one line a target whose every test is affected is named by, with its count and the commands that run it, or `nil` where the inventory is unknown or declares tests the answer did not reach.
    ///
    /// The suites are not listed: all of them are affected, so the list would say what the command already does.
    static func wholeTarget(_ target: String, affected: Int, in inventory: TestInventory?, package: String = "", runners: AffectedRunners = .both) -> String? {
        guard let inventory else { return nil }
        let declared = inventory.tests.filter { $0.target == target }
        guard !declared.isEmpty, affected >= declared.count else { return nil }
        let only = TestSymbol(target: target, suite: nil, function: nil, style: .swiftTesting)
        let nested = declared.count { TestSymbol(declared: $0).swiftTestFilterSelectsNothing }
        return "\(target): all \(declared.count) test\(declared.count == 1 ? "" : "s") — \(targetCommands(target: target, sample: only, package: package, runners: runners, nestedCount: nested, everyTestNested: nested > 0 && nested >= declared.count))"
    }

    /// The command that runs a whole target, one per runner printed, joined by ` — `.
    ///
    /// The tests of the target in a nested XCTest case, which no `swift test` filter selects, are counted, and the `swift test` command says it leaves them out. Where every test of the target is in such a case, the filter would run nothing, so the bare runner command is named instead, with what it runs.
    private static func targetCommands(target: String, sample: TestSymbol, package: String, runners: AffectedRunners, nestedCount: Int = 0, everyTestNested: Bool = false) -> String {
        var commands: [String] = []
        if runners.swiftPM {
            if everyTestNested {
                commands.append("\(DiscoveredStore.swiftPMTestCommand(package: package)), the whole suite: every test of \(target) is in a nested XCTest case, which no filter selects")
            } else {
                let leftOut = nestedCount > 0 ? ", which leaves out \(nestedCount) in a nested XCTest case" : ""
                commands.append("\(DiscoveredStore.swiftPMTestCommand(package: package)) --filter '\(TestSymbol.anchoredTargetFilter(target))'\(leftOut)")
            }
        }
        if runners.xcodebuild {
            commands.append("xcodebuild test \(sample.targetOnly.onlyTestingArgument)")
        }
        return commands.joined(separator: " — ")
    }

    /// What the after-edit walk walked from, for ``collapseLines(target:reached:declared:nameMatched:walkedFrom:sample:package:)``.
    static func walkedFromClause(count: Int, listed: String, scanned: Int) -> String {
        "the \(count) touched name\(count == 1 ? "" : "s") (\(listed)), \(scanned) name\(scanned == 1 ? "" : "s") over every hop"
    }

    /// The two lines a target past the list cap is named by when half its tests or more are reached: that it could not be narrowed, and the one command per runner that runs it.
    ///
    /// Printed on every path. The clause naming the walk is given only where every reached test rests on a name match from the after-edit walk, and says which names it walked from.
    static func collapseLines(target: String, reached: Int, declared: Int, nameMatched: Int, walkedFrom: String?, sample: TestSymbol, package: String = "", runners: AffectedRunners = .both, nestedReached: Int = 0, nestedDeclared: Int = 0) -> [String] {
        let why = walkedFrom.map { "are reached by name match from \($0)" } ?? (nameMatched == 0 ? "are reached" : "are reached, \(nameMatched) of them by name match")
        return [
            "  \(target): could not narrow below the target — \(reached) of its \(declared) tests \(why)",
            "    run the target rather than a list: " + targetCommands(target: target, sample: sample, package: package, runners: runners, nestedCount: nestedReached, everyTestNested: nestedDeclared > 0 && nestedDeclared >= declared),
        ]
    }

    /// The commands that run exactly the affected suites of a partly affected target past the cap, one line per runner, and a count of the tests no suite selects.
    ///
    /// Built from every affected test in the target. The lines are what a caller pastes, so they are complete however long, up to ``suiteLineLimit`` characters: a runner's line past that is replaced by the target's own filter, with the counts, unless `listSuites` asks for every suite. Only the runners given print.
    static func suiteCommandLines(
        for tests: [TestSymbol],
        in inventory: TestInventory?,
        package: String = "",
        runners: AffectedRunners = .both,
        target: TargetCounts? = nil,
        listSuites: Bool = false
    ) -> SuiteCommands {
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
        var replaced: [Int] = []
        var swiftReplaced = false
        var xcodebuildReplaced = false
        var printed = 0
        let targetSample = target.map { TestSymbol(target: $0.target, suite: nil, function: nil, style: .swiftTesting) }
        // Both notes about the swift test line print only where that line does.
        let swiftLinePrinted = runners.swiftPM && !sorted.isEmpty
        if swiftLinePrinted {
            let line = "    to run just these \(swiftNoun): " + DiscoveredStore.swiftPMTestCommand(package: package) + " " + sorted.map { "--filter '\($0.anchoredSwiftTestFilter)'" }.joined(separator: " ")
            printed += 1
            if let target, !listSuites, line.count > suiteLineLimit {
                lines.append(target.line(command: "\(DiscoveredStore.swiftPMTestCommand(package: package)) --filter '\(TestSymbol.anchoredTargetFilter(target.target))'", selectsNested: false))
                replaced.append(sorted.count)
                swiftReplaced = true
            } else {
                lines.append(line)
            }
        }
        if runners.xcodebuild, !xcodebuildArguments.isEmpty {
            let line = "    to run just these \(xcodebuildNoun): xcodebuild test " + xcodebuildArguments.joined(separator: " ")
            printed += 1
            if let target, let targetSample, !listSuites, line.count > suiteLineLimit {
                lines.append(target.line(command: "xcodebuild test \(targetSample.targetOnly.onlyTestingArgument)", selectsNested: true))
                replaced.append(xcodebuildArguments.count)
                xcodebuildReplaced = true
            } else {
                lines.append(line)
            }
        }
        if let most = replaced.max() {
            lines.append("    --suites lists the \(most) suites one by one")
        }
        if lines.isEmpty {
            lines = ["    no affected suite in this target has a filter of its own"]
        }
        // The target's own filter selects the tests outside any suite, so a line that replaced every runner's list has no use for the note.
        let namesTarget = printed > 0 && replaced.count == printed
        let mixed = !replaced.isEmpty && !namesTarget
        // Where only one runner's list became the target's filter, the other line still lists suites, and only that line leaves the tests outside any suite out.
        let leftOutOf = mixed ? " of the \(swiftReplaced ? "xcodebuild" : "swift test") line" : ""
        if outsideAnySuite > 0, !namesTarget {
            lines.append("      left out\(leftOutOf): \(outsideAnySuite) test\(outsideAnySuite == 1 ? "" : "s") declared outside any suite, which only the whole target's filter selects")
        }
        if xcodebuildReplaced {
            // The target's own xcodebuild filter runs every nested test, so only the swift test line leaves them out.
            let nested = nestedNamed + nestedUnnamed
            if nested > 0, swiftLinePrinted {
                lines.append("      left out of the swift test line: \(nested) test\(nested == 1 ? "" : "s") in a nested XCTest case, which no swift test filter selects (the xcodebuild line runs the whole target)")
            }
        } else if nestedNamed > 0, swiftLinePrinted {
            let named = runners.xcodebuild ? " (the xcodebuild line names it by its runtime name; see the limits above)" : " (see the limits above)"
            lines.append("      left out of the swift test line: \(nestedNamed) test\(nestedNamed == 1 ? "" : "s") in a nested XCTest case, which no swift test filter selects" + named)
        }
        if nestedUnnamed > 0, !xcodebuildReplaced {
            lines.append("      left out: \(nestedUnnamed) test\(nestedUnnamed == 1 ? "" : "s") in a nested XCTest case, which no filter selects (see the limits above)")
        }
        let runs = if namesTarget {
            "the commands below run the whole target"
        } else if mixed {
            "the \(swiftReplaced ? "xcodebuild" : "swift test") line runs exactly the affected suites; the \(xcodebuildReplaced ? "xcodebuild" : "swift test") line runs the whole target"
        } else {
            "the commands below run exactly the affected suites"
        }
        return SuiteCommands(lines: lines, runs: runs)
    }

    /// The tests of `target` declared in a nested XCTest case, which no `swift test` filter selects.
    static func nestedDeclared(in target: String, inventory: TestInventory?) -> Int {
        inventory?.tests.count { $0.target == target && TestSymbol(declared: $0).swiftTestFilterSelectsNothing } ?? 0
    }

    /// The reached tests in a nested XCTest case, counted as the headline counts.
    static func nestedCount(of tests: [TestSymbol], in inventory: TestInventory?) -> Int {
        tests.filter(\.swiftTestFilterSelectsNothing).reduce(0) { $0 + testCount(of: $1, in: inventory) }
    }

    /// How many tests one listed entry stands for: one for a test, and for a whole suite every test the inventory declares it to run, a Swift Testing suite's nested suites included.
    static func testCount(of test: TestSymbol, in inventory: TestInventory?) -> Int {
        guard test.function == nil, test.suite != nil, let inventory else { return 1 }
        return inventory.tests.count { test.wholeSuiteRuns(TestSymbol(declared: $0)) }
    }
}

extension AffectedTargetLines {
    /// A suite list longer than this, in characters, is replaced by the target's own filter unless `--suites` asks for it.
    static let suiteLineLimit = 2000

    /// What a partly affected target past the cap is named by in the target-filter form: its counts.
    struct TargetCounts {
        let target: String
        let declared: Int
        let affected: Int
        /// The target's tests in a nested XCTest case, which a `swift test` filter does not run.
        var nested = 0
        /// The affected tests among them.
        var affectedNested = 0

        /// The `swift test` filter runs neither the nested tests nor the affected ones among them, so its counts leave both out.
        fileprivate func line(command: String, selectsNested: Bool) -> String {
            let runs = selectsNested ? declared : declared - nested
            let reached = selectsNested ? affected : affected - affectedNested
            return "    to run them, run the target: \(command) — all \(runs) of its tests, \(runs - reached) beyond the \(reached) affected"
        }
    }

    /// The lines under a partly affected target, and the intro line's account of what they run, which is not "exactly the affected suites" where a runner's list became the target's filter.
    struct SuiteCommands {
        let lines: [String]
        /// What the intro line says the commands run, true of each runner's line.
        let runs: String
    }
}
