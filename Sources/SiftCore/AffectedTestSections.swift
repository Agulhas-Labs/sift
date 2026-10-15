//
// Copyright © Agulhas Labs
//

/// The tests of an `affected` answer, then the arguments that select them.
///
/// Under an after-edit walk, a target past the list cap whose name-matched tests are at least half of what it declares is not listed: the answer says it could not narrow below that target, and why.
struct AffectedTestSections {
    let reached: [TestSymbol: AffectedRenderer.Evidence]
    let inventory: TestInventory?
    let options: AffectedOptions
    let ways: Int
    let package: String
    var runners = AffectedRunners.both
    var provenance: DiscoveredStore.Provenance?
    var afterEdit: (seeds: AffectedAfterEditSeeds, scanned: Int)?

    /// The section's lines, from the blank line above its heading.
    func lines() -> [String] {
        guard !reached.isEmpty else {
            return [
                "",
                "no test references found within \(options.depth) hop\(options.depth == 1 ? "" : "s").",
                "that is not evidence that no test is affected: it means the index found no reference, which the limits (the standing list is `sift help affected-limits`) count \(ways) ways of being wrong about. Run the full suite.",
            ]
        }
        let byTarget = Dictionary(grouping: reached.keys, by: \.target)
        let total = reached.keys.reduce(0) { $0 + AffectedTargetLines.testCount(of: $1, in: inventory) }
        var lines = ["", "affected tests (\(total) in \(byTarget.count) target\(byTarget.count == 1 ? "" : "s"))\(runners.headingClause(provenance: provenance, package: package)):"]
        var arguments: [String] = []
        var filters: [String] = []
        var leftOutOfXcodebuild = 0
        var unfilterable = 0
        var nameOnly = 0
        var listedAny = false
        var namedWhole = false

        for target in byTarget.keys.sorted() {
            let tests = (byTarget[target] ?? []).sorted()
            // Counted the way the headline counts: a whole suite is every test the inventory declares in it, not the one row it prints as.
            let targetTotal = tests.reduce(0) { $0 + AffectedTargetLines.testCount(of: $1, in: inventory) }
            let declared = inventory?.tests.count { $0.target == target } ?? 0
            // Past the cap a per-test list would look complete and is not: the target is named by commands printed once, here, and never again in the sections below.
            let nameMatched = tests.filter { reached[$0]?.resolved == false }.reduce(0) { $0 + AffectedTargetLines.testCount(of: $1, in: inventory) }
            // Where the after-edit walk alone reached the target, the collapse says which names it walked from, which "all N tests" would not.
            let names = nameMatched == targetTotal ? afterEdit.map { AffectedTargetLines.walkedFromClause(count: $0.seeds.nameCount, listed: $0.seeds.namesListed, scanned: $0.scanned) } : nil
            // A target whose every test is affected is named whole at any size; under the cap its rows are kept beside the line, which carries the detail they do.
            let wholeTarget = names == nil ? AffectedTargetLines.wholeTarget(target, affected: targetTotal, in: inventory, package: package, runners: runners) : nil
            if tests.count > AffectedRenderer.testListCap, let sample = tests.first {
                if let wholeTarget {
                    lines.append("  " + wholeTarget)
                } else if declared > 0, targetTotal * 2 >= declared {
                    lines.append(contentsOf: AffectedTargetLines.collapseLines(target: target, reached: targetTotal, declared: declared, nameMatched: nameMatched, walkedFrom: names, sample: sample, package: package, runners: runners, nestedReached: AffectedTargetLines.nestedCount(of: tests, in: inventory), nestedDeclared: AffectedTargetLines.nestedDeclared(in: target, inventory: inventory)))
                } else {
                    lines.append("  \(target) — \(targetTotal) tests")
                    let restOnNames = nameMatched > 0 ? "; \(nameMatched) of them rest on a name match rather than a resolved reference" : ""
                    let section = AffectedTargetLines.suiteCommandLines(
                        for: tests,
                        in: inventory,
                        package: package,
                        runners: runners,
                        target: declared > 0 ? AffectedTargetLines.TargetCounts(target: target, declared: declared, affected: targetTotal, nested: AffectedTargetLines.nestedDeclared(in: target, inventory: inventory), affectedNested: AffectedTargetLines.nestedCount(of: tests, in: inventory)) : nil,
                        listSuites: options.listSuites
                    )
                    lines.append("    \(targetTotal) tests affected — \(section.runs)\(restOnNames)")
                    lines.append(contentsOf: section.lines)
                }
                namedWhole = true
                continue
            }
            listedAny = true
            lines.append("  \(target) — \(targetTotal) test\(targetTotal == 1 ? "" : "s")")
            wholeTarget.map { lines.append("    " + $0) }
            for test in tests {
                let evidence = reached[test]
                var detail = ["\(evidence?.depth ?? 1) hop\((evidence?.depth ?? 1) == 1 ? "" : "s")"]
                if evidence?.resolved == false {
                    detail.append("name match")
                    nameOnly += 1
                }
                lines.append("    \(test.described) — \(detail.joined(separator: ", ")) — \(evidence?.path ?? "?"):\(evidence?.line ?? 0)\(evidence?.state.marker ?? "")")
                if let argument = test.onlyTestingArgument(runtimeCaseNames: inventory?.runtimeCaseNames ?? [:]) {
                    arguments.append(argument)
                } else {
                    leftOutOfXcodebuild += AffectedTargetLines.testCount(of: test, in: inventory)
                }
                if test.swiftTestFilterSelectsNothing {
                    unfilterable += AffectedTargetLines.testCount(of: test, in: inventory)
                } else {
                    filters.append(test.anchoredSwiftTestFilter)
                }
            }
        }
        // Every target named by commands above has said how to run it; what is left to select is only what was listed.
        guard listedAny else { return lines }
        // Beside a target named by its own command, a line that read as the whole selection would leave that target out of the run it is pasted into.
        let listedOnly = namedWhole ? " (listed targets only; the targets above are named by their own command)" : ""

        if runners.xcodebuild {
            lines.append("")
            lines.append("xcodebuild — one argument per selection\(listedOnly)\(nameOnly > 0 ? "; \(nameOnly) of the tests these select rest on a name match rather than a resolved reference" : ""):")
            lines.append(contentsOf: arguments.sorted().map { "  \($0)" })
            if leftOutOfXcodebuild > 0 {
                lines.append("  " + AffectedBlindSpots.leftOutOfOnlyTesting(leftOutOfXcodebuild, noneLeft: arguments.isEmpty))
            }
        }
        if runners.swiftPM {
            lines.append("")
            lines.append("swift test — SwiftPM matches --filter as a regex against the printed test id\(listedOnly):")
            if filters.isEmpty {
                lines.append("  " + DiscoveredStore.swiftPMTestCommand(package: package) + " — " + AffectedBlindSpots.nothingFilterable(unfilterable))
            } else {
                lines.append((["  " + DiscoveredStore.swiftPMTestCommand(package: package)] + filters.sorted().map { "--filter '\($0)'" }).joined(separator: " "))
                if unfilterable > 0 {
                    lines.append("  " + AffectedBlindSpots.leftOutOfTheFilter(unfilterable))
                }
            }
        }
        return lines
    }
}
