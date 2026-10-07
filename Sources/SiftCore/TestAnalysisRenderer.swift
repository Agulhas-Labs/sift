//
// Copyright © Agulhas Labs
//

/// Renders `test --analyse` — the verdict, the per-target table, and then only the residue: a section that would be empty is not printed at all.
public struct TestAnalysisRenderer: Sendable {
    public init() {}

    /// The whole answer below the freshness header, which the engine puts on top of it.
    public func render(_ analysis: TestAnalysis) -> String {
        var sections: [[String]] = [[Self.planSource(analysis)], Self.schemeSource(analysis), headline(analysis), table(analysis)]
        sections.append(findingSection(analysis.neverRun, heading: "never runs", counted: analysis.counts.neverRuns))
        sections.append(findingSection(analysis.conditional, heading: "conditional — decided at runtime, counted in neither direction", counted: analysis.counts.conditional))
        sections.append(targetsRunBySchemeSection(analysis))
        sections.append(targetsNothingRunsSection(analysis))
        sections.append(targetsInNoPlanSection(analysis))
        sections.append(targetsOutsideEveryContainerSection(analysis))
        sections.append(unresolvedContainerSection(analysis))
        sections.append(testsInNoPlanSection(analysis))
        sections.append(exclusionSection(analysis, effect: .ignoredAsSwiftTesting, heading: "plan exclusions with no effect"))
        sections.append(exclusionSection(analysis, effect: .ignoredWithoutParentheses, heading: "plan exclusions with no effect — the identifier carries no parentheses"))
        sections.append(exclusionSection(analysis, effect: .honoured, heading: "plan exclusions that work and leave no trace"))
        sections.append(exclusionSection(analysis, effect: .matchesNothing, heading: "plan entries that match no declared test"))
        sections.append(exclusionSection(analysis, effect: .unreadable, heading: "plan entries that could not be read"))
        sections.append(selectionSection(analysis))
        sections.append(retrySection(analysis))
        sections.append(emptyTargetSection(analysis))
        sections.append(guessedSection(analysis))
        sections.append(unreadableSection(analysis))
        sections.append(unreadableSchemeSection(analysis))
        sections.append(fileScopeSection(analysis))
        sections.append(compiledOutSection(analysis))

        return sections
            .filter { !$0.isEmpty }
            .map { $0.joined(separator: "\n") }
            .joined(separator: "\n\n")
    }
}

private extension TestAnalysisRenderer {
    /// Where the plans came from, under the header, because they are read live off disk and nothing stored stands between the reader and the files.
    ///
    /// A plan's wiring is claimed only from a scheme that was read: with no scheme under this repository the answer says so in the words it always did, and a plan no scheme read names may still be wired to one the repository does not commit.
    static func planSource(_ analysis: TestAnalysis) -> String {
        guard !analysis.plans.isEmpty else {
            return "no .xctestplan under this repository — SwiftPM runs every test in every test target, so `declared` below is the expected set and there is nothing for a plan to subtract."
        }
        let listed = analysis.plans.map { "\($0.name) (\($0.path), \($0.enabledTargets) enabled targets\(Self.wiring(of: $0, in: analysis)))" }.joined(separator: ", ")
        let narrowed = analysis.narrowedTo.map { " — narrowed by --plan \($0)" } ?? ""
        let disabled = analysis.plans.flatMap { plan in plan.disabledTargets.map { "\(plan.name): \($0)" } }
        let off = disabled.isEmpty ? "" : "; disabled in their plan and left out of every count: \(disabled.joined(separator: ", "))"
        let unwired = analysis.plans.contains { $0.wiredTo.isEmpty }
        let tail = analysis.schemes.isEmpty
            ? " Whether a scheme is wired to any of them is not read here."
            : (unwired ? " A plan no scheme read here names may still be wired to one this repository does not commit." : "")
        return "\(analysis.plans.count) test plan\(analysis.plans.count == 1 ? "" : "s") read live off disk\(narrowed): \(listed)\(off).\(tail)"
    }

    /// What one plan's entry says about its wiring, and nothing at all where no scheme was read to say it.
    static func wiring(of plan: TestAnalysis.PlanSummary, in analysis: TestAnalysis) -> String {
        guard !analysis.schemes.isEmpty else {
            return ""
        }
        guard !plan.wiredTo.isEmpty else {
            return ", named by no scheme read here"
        }
        return ", named by scheme \(plan.wiredTo.joined(separator: ", "))"
    }

    /// Which schemes were read and what each one's test action names — the evidence behind every claim below about what runs a target.
    static func schemeSource(_ analysis: TestAnalysis) -> [String] {
        guard !analysis.schemes.isEmpty else {
            return []
        }
        var lines = ["\(analysis.schemes.count) .xcscheme read live off disk — what each TestAction names:"]
        lines += analysis.schemes.map { scheme in
            "  \(Self.label(of: scheme)) (\(scheme.path)) — \(Self.testAction(of: scheme))"
        }
        return lines
    }

    /// A scheme's name, saying where it is a per-user one, since what a per-user scheme runs is true of one machine rather than of every checkout.
    static func label(of scheme: TestAnalysis.SchemeSummary) -> String {
        scheme.isShared ? scheme.name : "\(scheme.name) [per-user]"
    }

    /// What one scheme's test action names, in the shape it is written in.
    static func testAction(of scheme: TestAnalysis.SchemeSummary) -> String {
        guard scheme.hasTestAction else {
            return "no TestAction at all, so it runs no tests"
        }
        var clauses: [String] = []
        if !scheme.plans.isEmpty {
            clauses.append("names test plans: \(scheme.plans.joined(separator: ", "))")
        }
        if !scheme.runs.isEmpty {
            clauses.append("runs \(scheme.runs.joined(separator: ", "))")
        }
        if !scheme.superseded.isEmpty {
            clauses.append("its Testables name \(scheme.superseded.joined(separator: ", ")), superseded by the plans above and read as evidence of neither running nor not")
        }
        if !scheme.skipped.isEmpty {
            clauses.append("skipped: \(scheme.skipped.joined(separator: ", "))")
        }
        return clauses.isEmpty ? "a TestAction that names no target and no plan" : clauses.joined(separator: "; ")
    }

    /// The verdict, then the arithmetic of every figure in it.
    func headline(_ analysis: TestAnalysis) -> [String] {
        let counts = analysis.counts
        let glyph = Self.hasResidue(analysis) ? "⚠" : "✔"
        let plans = analysis.plans.isEmpty ? "no plans" : "\(analysis.plans.count) plan\(analysis.plans.count == 1 ? "" : "s")"
        let headline = "\(glyph) sift test --analyse — \(counts.declared) declared · \(counts.inAPlan) in a plan · "
            + "\(counts.runs) run · \(counts.neverRuns) never run · \(counts.conditional) conditional — "
            + "\(analysis.targets.count + analysis.targetsInNoPlan.count + analysis.targetsOutsideEveryContainer.count) targets, \(plans)"
        let outside = counts.outsideEveryContainer == 0 ? "" : "\(counts.outsideEveryContainer) outside every plan's container − "
        let declined = counts.declared - counts.inAPlan - counts.outsideEveryContainer
        return [
            headline,
            "  runs \(counts.runs) = \(counts.inAPlan) in a plan − \(counts.neverRuns) never runs − \(counts.conditional) conditional",
            "  in a plan \(counts.inAPlan) = \(counts.declared) declared − \(outside)\(declined) no plan under consideration admits",
        ]
    }

    /// Whether this answer found anything a reader has to act on, which is what the verdict glyph says.
    ///
    /// A target no plan names is not one of those things on its own: what runs it is decided by a scheme, so the absence of a plan is reported and never marked. A target no plan names *and* no scheme read runs is a different fact and does mark it, because there the answer read both halves and found nothing that runs the target at all.
    static func hasResidue(_ analysis: TestAnalysis) -> Bool {
        analysis.targetsInNoPlan.contains(where: isRunByNothing)
            || !analysis.unreadableSchemes.isEmpty
            || !analysis.neverRun.isEmpty
            || analysis.exclusions.contains { $0.effect != .honoured }
            || !analysis.unreadablePlans.isEmpty
            || !analysis.unresolvedContainers.isEmpty
            || !analysis.targetsWithNoDeclaredTests.isEmpty
            || !analysis.guessedTargets.isEmpty
            || !analysis.fileScopeTests.isEmpty
    }

    func table(_ analysis: TestAnalysis) -> [String] {
        let rows = analysis.targets
        guard !rows.isEmpty else {
            return []
        }
        let width = max(rows.map(\.name.count).max() ?? 0, "target".count)
        let header = "target".padding(toLength: width, withPad: " ", startingAt: 0)
            + "  declared  in a plan  runs  never runs  conditional"
        return [header] + rows.map { row in
            "  " + row.name.padding(toLength: width, withPad: " ", startingAt: 0)
                + Self.column(row.declared, 8)
                + Self.column(row.inAPlan, 11)
                + Self.column(row.runs, 6)
                + Self.column(row.neverRuns, 12)
                + Self.column(row.conditional, 13)
        }
    }

    static func column(_ value: Int, _ width: Int) -> String {
        let text = String(value)
        return String(repeating: " ", count: max(1, width - text.count)) + text
    }

    /// One `never runs` or `conditional` section: the test, what decides it, and where it is declared.
    func findingSection(_ findings: [TestAnalysis.Finding], heading: String, counted: Int) -> [String] {
        guard !findings.isEmpty else {
            return []
        }
        let outside = findings.count - counted
        let tail = outside > 0 ? " — \(counted) of them in a plan, \(outside) in a target no plan under consideration admits" : ""
        var lines = ["\(heading) (\(findings.count)\(tail))"]
        for finding in findings {
            let plan = finding.outsideEveryPlan ? "  [in no plan]" : ""
            lines.append("  \(Self.identifier(finding.test))  \(finding.cause)\(plan)")
            lines.append("    \(finding.test.path):\(finding.test.line)")
        }
        return lines
    }

    /// A whole test target that no plan names and a scheme's `TestAction` runs anyway, which is the mechanism that makes "no plan names it" a weaker claim than "nothing runs it".
    func targetsRunBySchemeSection(_ analysis: TestAnalysis) -> [String] {
        let rows = analysis.targetsInNoPlan.filter { !$0.runBy.isEmpty }
        guard !rows.isEmpty else {
            return []
        }
        let tests = rows.map(\.tally.declared).reduce(0, +)
        var lines = ["whole targets a scheme's TestAction runs with no plan involved (\(rows.count) target\(rows.count == 1 ? "" : "s"), \(tests) tests)"]
        lines += rows.map { row in
            let schemes = row.runBy.map { name in Self.label(of: analysis.schemes.first { $0.name == name }, named: name) }
            return "  \(row.tally.name) — \(row.tally.declared) declared tests, named by no plan under consideration and run by the TestAction of \(schemes.joined(separator: ", "))"
        }
        return lines
    }

    /// A whole test target that no plan names and no scheme read runs — the strong claim, and the one this section exists to make.
    ///
    /// It is only made where a scheme was actually read whose container holds the target: both halves of "nothing runs it" are then evidence rather than absence.
    func targetsNothingRunsSection(_ analysis: TestAnalysis) -> [String] {
        let rows = analysis.targetsInNoPlan.filter(Self.isRunByNothing)
        guard !rows.isEmpty else {
            return []
        }
        let tests = rows.map(\.tally.declared).reduce(0, +)
        var lines = ["⚠ whole targets nothing under this repository runs (\(rows.count) target\(rows.count == 1 ? "" : "s"), \(tests) tests)"]
        lines += rows.map { "  \($0.tally.name) — \($0.tally.declared) declared tests" }
        lines.append("  named by no .xctestplan found under this repository, and by no TestAction of the \(analysis.schemes.count) .xcscheme read above whose container holds them.")
        return lines
    }

    /// Whether the answer can say outright that nothing runs a target: no plan names it, no scheme read runs it, and a scheme covering it was read.
    static func isRunByNothing(_ target: TestAnalysis.UnplannedTarget) -> Bool {
        target.runBy.isEmpty && target.supersededBy.isEmpty && target.coveredBySchemeRead
    }

    /// A whole test target inside some plan's container that no `.xctestplan` found under this repository names, and that no scheme read here settles either way.
    ///
    /// What runs it is not answered: a scheme's `TestAction` runs the targets it lists with no plan involved, and either no `.xcscheme` covering this target was found or the only one that names it names it in a block its own test plans supersede.
    func targetsInNoPlanSection(_ analysis: TestAnalysis) -> [String] {
        let rows = analysis.targetsInNoPlan.filter { $0.runBy.isEmpty && !Self.isRunByNothing($0) }
        guard !rows.isEmpty else {
            return []
        }
        let tests = rows.map(\.tally.declared).reduce(0, +)
        var lines = ["whole targets named by no .xctestplan found under this repository (\(rows.count) targets, \(tests) tests)"]
        lines += rows.map { row in
            let superseded = row.supersededBy.isEmpty
                ? ""
                : ", named by the superseded Testables of \(row.supersededBy.joined(separator: ", "))"
            return "  \(row.tally.name) — \(row.tally.declared) declared tests, named by no plan under consideration\(superseded)"
        }
        let read = analysis.schemes.isEmpty
            ? "no .xcscheme is read for them here"
            : "no .xcscheme whose container holds them settles it"
        lines.append("  whether anything runs them is not read here: a scheme's TestAction runs the targets it lists with no plan involved, and \(read).")
        return lines
    }

    /// One scheme's name as the answer prints it, falling back to the bare name for a scheme the summary list does not hold.
    static func label(of scheme: TestAnalysis.SchemeSummary?, named name: String) -> String {
        scheme.map(label) ?? name
    }

    /// A target declared outside the container of every plan read, which those plans say nothing about either way.
    ///
    /// A package's own test targets are the ordinary case of this and nothing is wrong with them, so the section states what they are and the verdict glyph above is left alone.
    func targetsOutsideEveryContainerSection(_ analysis: TestAnalysis) -> [String] {
        guard !analysis.targetsOutsideEveryContainer.isEmpty else {
            return []
        }
        let tests = analysis.targetsOutsideEveryContainer.map(\.declared).reduce(0, +)
        var lines = ["targets outside every plan's container (\(analysis.targetsOutsideEveryContainer.count) targets, \(tests) tests)"]
        lines += analysis.targetsOutsideEveryContainer.map { "  \($0.name) — \($0.declared) declared tests, declared outside the container of every plan above" }
        lines.append("  no plan above judged these either way, and what runs them — `swift test`, or a scheme's TestAction — is read by neither this command nor a plan.")
        return lines
    }

    /// A plan target whose `containerPath` could not be read, which widens that plan's judgement back to every declared target.
    func unresolvedContainerSection(_ analysis: TestAnalysis) -> [String] {
        guard !analysis.unresolvedContainers.isEmpty else {
            return []
        }
        var lines = ["plan targets whose container could not be resolved (\(analysis.unresolvedContainers.count))"]
        lines += analysis.unresolvedContainers.map { unresolved in
            let written = unresolved.written.map { "\"\($0)\"" } ?? "no containerPath at all"
            return "  \(unresolved.plan): \(unresolved.target) containerPath \(written) — not read as a directory under this repository, so this entry was judged against every declared target of that name rather than a narrowed set"
        }
        return lines
    }

    /// Tests whose target a plan does name, that its `selectedTests` leaves out.
    func testsInNoPlanSection(_ analysis: TestAnalysis) -> [String] {
        guard !analysis.testsInNoPlan.isEmpty else {
            return []
        }
        var lines = ["tests left out by selectedTests (\(analysis.testsInNoPlan.count))"]
        lines += analysis.testsInNoPlan.map { "  \(Self.identifier($0))  \($0.path):\($0.line)" }
        return lines
    }

    func exclusionSection(_ analysis: TestAnalysis, effect: TestAnalysis.Effect, heading: String) -> [String] {
        let matching = analysis.exclusions.filter { $0.effect == effect }
        guard !matching.isEmpty else {
            return []
        }
        return ["\(heading) (\(matching.count))"] + matching.map { "  \(Self.line(of: $0))" }
    }

    static func line(of exclusion: TestAnalysis.Exclusion) -> String {
        let opening = "\(exclusion.plan): \(exclusion.target) skippedTests \"\(exclusion.written)\" — "
        switch exclusion.effect {
        case .ignoredAsSwiftTesting:
            return opening + "swift-testing, ignored by Xcode in every identifier shape measured; the test runs"
        case .ignoredWithoutParentheses:
            return opening + "XCTest without parentheses in the identifier, which Xcode ignores; the test runs. Write it as \"\(exclusion.written)()\" to have it honoured"
        case .honoured:
            let named = exclusion.test.map(Self.identifier) ?? exclusion.target
            return opening + "honoured: \(named) is removed from the run and leaves no log line, no .xcresult node and a tally smaller by one. Move the exclusion into the test instead, where every report shows it skipped with its reason"
        case .matchesNothing:
            return opening + "matches no declared test — a renamed or deleted test, or a spelling the plan got wrong; it excludes nothing"
        case .unreadable:
            return opening + "could not be read as a Target/Type/function identifier — a step of it is empty, so what it was meant to name is not decided here rather than answered as naming nothing"
        }
    }

    /// `selectedTests` narrows the counts above by the same match rule, and what it does to a swift-testing test is unmeasured.
    func selectionSection(_ analysis: TestAnalysis) -> [String] {
        guard !analysis.selections.isEmpty else {
            return []
        }
        var lines = ["selectedTests — narrowed by the same match rule, and unmeasured for swift-testing (\(analysis.selections.count))"]
        lines += analysis.selections.map { "  \($0.plan): \($0.target) selectedTests \"\($0.written)\" — admits \($0.matched) declared test\($0.matched == 1 ? "" : "s")" }
        lines.append("  no measurement was taken of whether Xcode honours a swift-testing identifier in selectedTests, so the narrowing above is this tool's arithmetic and not a statement about a run.")
        return lines
    }

    func retrySection(_ analysis: TestAnalysis) -> [String] {
        guard !analysis.retries.isEmpty else {
            return []
        }
        var lines = ["repetition (\(analysis.retries.count))"]
        lines += analysis.retries.map { retry in
            let maximum = retry.maximum.map { ", up to \($0) attempts" } ?? ""
            return "  \(retry.plan): testRepetitionMode \(retry.mode)\(maximum) — XCTest counts attempts rather than tests in its own tally, so its number is above the count here whenever anything retried"
        }
        return lines
    }

    /// A target a plan runs that the index declares no test in — the count above says nothing about it either way.
    func emptyTargetSection(_ analysis: TestAnalysis) -> [String] {
        guard !analysis.targetsWithNoDeclaredTests.isEmpty else {
            return []
        }
        var lines = ["plan targets the index declares no test in (\(analysis.targetsWithNoDeclaredTests.count))"]
        lines += analysis.targetsWithNoDeclaredTests.map { "  \($0) — a plan runs it and no declared test is attributed to it, so every count above is silent about it" }
        return lines
    }

    func guessedSection(_ analysis: TestAnalysis) -> [String] {
        guard !analysis.guessedTargets.isEmpty else {
            return []
        }
        return ["⚠ module guessed — no build file declares the files of: \(analysis.guessedTargets.joined(separator: ", ")) — which bundle those tests are in is a guess, so every count that names one of these targets is a guess too"]
    }

    /// A file at the scheme extension that would not parse, named rather than dropped: a scheme nobody could read is a scheme whose test action says nothing here, and the claims above are weaker for it.
    func unreadableSchemeSection(_ analysis: TestAnalysis) -> [String] {
        guard !analysis.unreadableSchemes.isEmpty else {
            return []
        }
        var lines = ["schemes that would not parse (\(analysis.unreadableSchemes.count)) — what their test actions name is read by nothing above"]
        lines += analysis.unreadableSchemes.map { "  \($0.path) — \($0.reason)" }
        return lines
    }

    func unreadableSection(_ analysis: TestAnalysis) -> [String] {
        guard !analysis.unreadablePlans.isEmpty else {
            return []
        }
        var lines = ["plans that would not decode (\(analysis.unreadablePlans.count)) — nothing in them is counted above"]
        lines += analysis.unreadablePlans.map { "  \($0.path) — \($0.reason)" }
        return lines
    }

    /// A test declared at file scope, which no `Target/Type/function` identifier can name.
    func fileScopeSection(_ analysis: TestAnalysis) -> [String] {
        guard !analysis.fileScopeTests.isEmpty else {
            return []
        }
        var lines = ["declared at file scope (\(analysis.fileScopeTests.count)) — counted above, and no plan entry or enumeration identifier can name one, since both spell a test Target/Type/function"]
        lines += analysis.fileScopeTests.map { "  \(Self.identifier($0))  \($0.path):\($0.line)" }
        return lines
    }

    /// A test under an `#if` this platform does not compile, named apart because every count above leaves it out: it cannot run here.
    func compiledOutSection(_ analysis: TestAnalysis) -> [String] {
        guard !analysis.compiledOut.isEmpty else {
            return []
        }
        var lines = ["compiled out here (\(analysis.compiledOut.count)) — under an #if this platform does not compile, so none of the counts above takes them in"]
        lines += analysis.compiledOut.map { "  \(Self.identifier($0))  \($0.path):\($0.line)" }
        return lines
    }

    /// The identifier both a plan entry and an enumeration spell, with the target's own spelling intact and a file-scope test under the type the run inventory gives it.
    static func identifier(_ test: DeclaredTest) -> String {
        "\(test.target)/\(test.suite.isEmpty ? PackageShardPlanner.fileScopeType : test.suite)/\(test.function)"
    }
}
