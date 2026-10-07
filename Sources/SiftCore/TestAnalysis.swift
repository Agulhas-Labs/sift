//
// Copyright © Agulhas Labs
//

import Foundation

/// How many tests are *supposed* to run: the declared inventory joined to the test plans that narrow it, and the gaps between the two.
///
/// Nothing here is read from a run. The tests come from the index and the plans come off disk, so every figure below is a statement about what the sources and the `.xctestplan` files say together — which is the one count no runner's output can give, because a plan's exclusion leaves no trace, a crash loses what never started, and a target in no plan is never mentioned by anything.
public struct TestAnalysis: Sendable, Equatable {
    /// The whole-repository counts, each of which the answer prints its arithmetic beside.
    public let counts: Counts
    /// One row per test target the index attributes a test to, ordered by name.
    public let targets: [TargetTally]
    /// The plans this answer was built from, by path, in the order they were found.
    public let plans: [PlanSummary]
    /// The name `--plan` narrowed to, when it did.
    public let narrowedTo: String?
    /// Every declared test whose declaration or whose plan says it will not run.
    public let neverRun: [Finding]
    /// Every declared test whose running is decided at runtime, counted in neither direction.
    public let conditional: [Finding]
    /// Tests whose target a plan does name, that the plan's `selectedTests` leaves out.
    public let testsInNoPlan: [DeclaredTest]
    /// Targets inside some plan's container that no plan under consideration names, each with what the schemes read say about it.
    public let targetsInNoPlan: [UnplannedTarget]
    /// The schemes this answer read, by name and then by path, whose test actions say what runs a target no plan names.
    public let schemes: [SchemeSummary]
    /// Files at the scheme extension that would not parse.
    public let unreadableSchemes: [SchemeSurvey.Unreadable]
    /// Targets whose declaring files sit outside the container of every plan under consideration, so no plan here judged them either way.
    public let targetsOutsideEveryContainer: [TargetTally]
    /// Plan targets whose `containerPath` could not be read as a path, each of which was judged against every declared target rather than a narrowed one.
    public let unresolvedContainers: [UnresolvedContainer]
    /// Every `skippedTests` entry, with what it actually does.
    public let exclusions: [Exclusion]
    /// Every `selectedTests` entry, whose swift-testing behaviour nobody has measured.
    public let selections: [Selection]
    /// Every plan that repeats its tests, and what that costs a tally.
    public let retries: [Retry]
    /// Targets a plan runs that the index declares no test in, so nothing above counts a single test for them.
    public let targetsWithNoDeclaredTests: [String]
    /// Targets whose module attribution was guessed, so which bundle their tests are in is a guess too.
    public let guessedTargets: [String]
    /// Files at the plan extension that would not decode.
    public let unreadablePlans: [TestPlanSurvey.Unreadable]
    /// Tests declared at file scope, which no `Target/Type/function` identifier can name.
    public let fileScopeTests: [DeclaredTest]
    /// Tests declared inside an `#if` clause this platform provably does not compile, which none of the counts above takes in: they cannot run here.
    public var compiledOut: [DeclaredTest] = []
}

public extension TestAnalysis {
    /// The counts, over the set a plan admits — `runs` is what is left of `in a plan` once the two decided kinds are taken out of it.
    struct Counts: Sendable, Equatable {
        /// Every declared test in the index.
        public let declared: Int
        /// Those whose target appears, enabled, in at least one plan under consideration, and that its `selectedTests` admits.
        public let inAPlan: Int
        /// Those declared outside the container of every plan under consideration, which no plan here declined and none of the figures beside this one is about.
        public let outsideEveryContainer: Int
        /// `inAPlan` less `neverRuns` and less `conditional`.
        public let runs: Int
        /// In a plan, and either switched off in its declaration or removed by a plan exclusion Xcode honours.
        public let neverRuns: Int
        /// In a plan, and decided at runtime — never folded into either of the two above.
        public let conditional: Int
    }

    /// One target's share of the counts.
    struct TargetTally: Sendable, Equatable {
        public let name: String
        public let declared: Int
        public let inAPlan: Int
        public let runs: Int
        public let neverRuns: Int
        public let conditional: Int
    }

    /// One plan as the answer names it: what it is called, where it sits, how many enabled targets it runs, and which schemes read here name it.
    struct PlanSummary: Sendable, Equatable {
        public let name: String
        public let path: String
        public let enabledTargets: Int
        public let disabledTargets: [String]
        /// The schemes whose `TestAction` names this plan file, and empty where no scheme read here does — which is not the same as a plan nothing is wired to, since the scheme may be one the repository does not commit.
        public let wiredTo: [String]
    }

    /// One scheme as the answer names it: where it sits, whether it is shared, and what its test action names.
    struct SchemeSummary: Sendable, Equatable {
        public let name: String
        public let path: String
        /// Whether the scheme is shared rather than one developer's, which decides whether what it runs is true of every checkout or of one machine.
        public let isShared: Bool
        /// Whether the document carries a `TestAction` at all.
        public let hasTestAction: Bool
        /// The targets its test action runs, with no plan involved.
        public let runs: [String]
        /// The plans it names, as the repository-relative paths they resolve to, or as written where a reference resolves to nothing.
        public let plans: [String]
        /// The targets its `Testables` block names that its own test plans supersede, which this answer reads as evidence of nothing either way.
        public let superseded: [String]
        /// The targets its test action lists as skipped.
        public let skipped: [String]
    }

    /// One whole test target no plan under consideration names, and what the schemes read say runs it.
    struct UnplannedTarget: Sendable, Equatable {
        public let tally: TargetTally
        /// The schemes whose test action runs this target, and empty where none read does.
        public let runBy: [String]
        /// The schemes whose `Testables` block names it under test plans that supersede that block — evidence for nothing, and enough to withhold the claim that nothing runs it.
        public let supersededBy: [String]
        /// Whether some scheme was read whose container holds this target's declaring files, which is what makes "no scheme runs it" a reading rather than an absence.
        public let coveredBySchemeRead: Bool
    }

    /// One test that will not run, or cannot be decided here, and the declaration or plan entry that says so.
    struct Finding: Sendable, Equatable {
        public let test: DeclaredTest
        /// What decides it, in the spelling the reader will find in the source or the plan.
        public let cause: String
        /// True where no plan under consideration admits this test, so the finding is a fact about the source alone.
        public let outsideEveryPlan: Bool
    }

    /// One `skippedTests` entry paired with one test it names — or with none, which is its own verdict.
    struct Exclusion: Sendable, Equatable {
        public let plan: String
        public let target: String
        /// The entry exactly as the plan spells it.
        public let written: String
        /// The test it matched, or `nil` where it matched nothing declared.
        public let test: DeclaredTest?
        public let effect: Effect
    }

    /// One plan target whose `containerPath` could not be read, so nothing narrowed the targets that plan was judged against.
    struct UnresolvedContainer: Sendable, Equatable {
        public let plan: String
        public let target: String
        /// The path exactly as the plan spells it, or `nil` where the plan states none.
        public let written: String?
    }

    /// What a `skippedTests` entry does, which the entry's own form and the matched test's framework decide between them.
    enum Effect: Sendable, Equatable {
        /// XCTest, with parentheses: the test is removed from the run and leaves no trace anywhere.
        case honoured
        /// Swift Testing: measured to be ignored by Xcode in every identifier shape tried, so the test still runs.
        case ignoredAsSwiftTesting
        /// XCTest without parentheses in the identifier: ignored, so the test still runs.
        case ignoredWithoutParentheses
        /// The entry names nothing the index declares — a renamed or deleted test, or a spelling the plan got wrong.
        case matchesNothing
        /// The entry could not be read as an identifier at all, which is a different answer from naming nothing and has a different next move.
        case unreadable
    }

    /// One `selectedTests` entry and how many declared tests it admits.
    struct Selection: Sendable, Equatable {
        public let plan: String
        public let target: String
        public let written: String
        public let matched: Int
    }

    /// One plan's repetition setting, verbatim.
    struct Retry: Sendable, Equatable {
        public let plan: String
        public let mode: String
        public let maximum: Int?
    }
}

public extension TestAnalysis {
    /// Joins the declared inventory to the plans, narrowing to one plan by name where a caller asked for it.
    ///
    /// Targets are matched by exact name string and nothing is normalised: a target spelled with spaces is matched with its spaces, which is measured to be the spelling the index, a plan and an enumeration all use.
    ///
    /// `schemes` is what the repository's `.xcscheme` files say runs a target, and an unread survey is the honest default: a caller that read none gets an answer claiming only what a plan states.
    static func of(
        inventory: TestInventory,
        survey: TestPlanSurvey,
        schemes: SchemeSurvey = .unread,
        plan named: String? = nil
    ) throws -> TestAnalysis {
        let considered = try considering(survey.plans, named: named)
        let byTarget = Dictionary(grouping: compiledHere(inventory).tests, by: \.target)
        var join = Join(byTarget: byTarget)
        for plan in considered {
            join.read(plan)
        }
        return assemble(
            inventory: inventory,
            survey: survey,
            schemes: schemes,
            considered: considered,
            join: join,
            narrowedTo: named
        )
    }

    /// The plans this answer is built from, or the refusal a `--plan` naming none of them is owed.
    private static func considering(_ plans: [TestPlanFile], named: String?) throws -> [TestPlanFile] {
        guard let named else {
            return plans
        }
        let matching = plans.filter { $0.name == named }
        guard !matching.isEmpty else {
            throw TestAnalysisError.noSuchPlan(name: named, found: plans.map(\.name).sorted())
        }
        return matching
    }
}

private extension TestAnalysis {
    /// What one pass over the plans accumulates: which tests a plan admits, which of them it removes, and every entry's verdict.
    struct Join {
        let byTarget: [String: [DeclaredTest]]
        /// Tests some plan admits — the target is named and enabled, and `selectedTests` lets the test through.
        var admitted: Set<DeclaredTest> = []
        /// Tests every plan that admits them also removes, which is what makes an honoured exclusion a never-run.
        var admissions: [DeclaredTest: Int] = [:]
        var removals: [DeclaredTest: Int] = [:]
        /// Targets a plan names and enables, whether or not the index knows any test in them.
        var namedTargets: Set<String> = []
        /// Every container directory a plan under consideration confined one of its targets to, the empty string standing for the whole repository.
        var scopes: Set<String> = []
        var unresolvedContainers: [TestAnalysis.UnresolvedContainer] = []
        var exclusions: [TestAnalysis.Exclusion] = []
        var selections: [TestAnalysis.Selection] = []
        var causes: [DeclaredTest: String] = [:]

        mutating func read(_ plan: TestPlanFile) {
            for target in plan.targets where target.isEnabled {
                namedTargets.insert(target.name)
                let scope = plan.containerScope(of: target)
                scopes.insert(scope ?? "")
                if scope == nil {
                    unresolvedContainers.append(
                        TestAnalysis.UnresolvedContainer(plan: plan.name, target: target.name, written: target.containerPath)
                    )
                }
                // A plan states what one container's targets run, so a target of the same name declared somewhere else in the
                // repository is not the target this entry names, and judging it by this plan would report a package's own test
                // target as one a plan declined.
                let declared = (byTarget[target.name] ?? []).filter { Join.inside(scope, $0) }
                let admits = admitting(target, of: declared, in: plan)
                for test in admits {
                    admitted.insert(test)
                    admissions[test, default: 0] += 1
                }
                removing(target, of: declared, admitted: admits, in: plan)
            }
        }

        /// The declared tests this target admits: all of them, or the ones a non-empty `selectedTests` names.
        private mutating func admitting(_ target: TestPlanFile.Target, of declared: [DeclaredTest], in plan: TestPlanFile) -> [DeclaredTest] {
            guard !target.selected.isEmpty else {
                return declared
            }
            for entry in target.selected {
                let matched = declared.filter { TestAnalysis.matches(entry, $0) }
                selections.append(
                    TestAnalysis.Selection(plan: plan.name, target: target.name, written: entry.written, matched: matched.count)
                )
            }
            return declared.filter { test in target.selected.contains { TestAnalysis.matches($0, test) } }
        }

        /// Every `skippedTests` entry's verdict, and the removals the honoured ones make.
        ///
        /// An entry is matched against everything the target declares rather than against what the plan admits, because an entry naming a test `selectedTests` already left out has still named something and is not the fourth case.
        private mutating func removing(_ target: TestPlanFile.Target, of declared: [DeclaredTest], admitted admits: [DeclaredTest], in plan: TestPlanFile) {
            // One plan can carry more than one `skippedTests` entry that honours against the same test — a whole-suite
            // entry beside a function-level one naming a test inside it — and `removals` counts plans, the same unit as
            // `admissions`, so a test this plan removes twice must still only cost it one.
            var removedByThisPlan: Set<DeclaredTest> = []
            for entry in target.skipped {
                guard entry.isReadable else {
                    exclusions.append(
                        TestAnalysis.Exclusion(plan: plan.name, target: target.name, written: entry.written, test: nil, effect: .unreadable)
                    )
                    continue
                }
                let matched = declared.filter { TestAnalysis.matches(entry, $0) }
                guard !matched.isEmpty else {
                    exclusions.append(
                        TestAnalysis.Exclusion(plan: plan.name, target: target.name, written: entry.written, test: nil, effect: .matchesNothing)
                    )
                    continue
                }
                for test in matched {
                    let effect = TestAnalysis.effect(of: entry, on: test)
                    exclusions.append(
                        TestAnalysis.Exclusion(plan: plan.name, target: target.name, written: entry.written, test: test, effect: effect)
                    )
                    guard effect == .honoured, admits.contains(test) else { continue }
                    causes[test] = "removed by \(plan.name)'s skippedTests \"\(entry.written)\""
                    guard removedByThisPlan.insert(test).inserted else { continue }
                    removals[test, default: 0] += 1
                }
            }
        }

        /// Whether a test's declaring file sits inside a container's directory, which an unresolved container and the repository root both answer for every test.
        static func inside(_ scope: String?, _ test: DeclaredTest) -> Bool {
            guard let scope, !scope.isEmpty else {
                return true
            }
            return test.path.hasPrefix(scope + "/")
        }

        /// Whether no plan under consideration holds this test's declaring file, which is a statement about the containers and not about what runs it.
        func outsideEveryContainer(_ test: DeclaredTest) -> Bool {
            !scopes.isEmpty && !scopes.contains { Join.inside($0, test) }
        }
    }
}

extension TestAnalysis {
    /// What a `skippedTests` entry does to the test it names.
    ///
    /// Swift Testing first, because the framework decides it before the form does: a swift-testing identifier in `skippedTests` was measured to be ignored by Xcode in every shape tried, parentheses included, so no spelling of one is honoured. An XCTest entry is honoured only when its identifier carries parentheses.
    static func effect(of entry: TestPlanFile.Entry, on test: DeclaredTest) -> Effect {
        guard test.style == .xcTest else {
            return .ignoredAsSwiftTesting
        }
        // A whole-class entry carries no function to put parentheses on, and Xcode honours it as written.
        guard entry.function != nil else {
            return .honoured
        }
        return entry.carriesParentheses ? .honoured : .ignoredWithoutParentheses
    }

    /// Whether a plan entry names a declared test.
    ///
    /// The suite path is matched whole and never by its last component: one entry can remove at most one suite's tests, and matching the leaf would let `NamedSuite/testX()` remove a test of `AlphaTests.NamedSuite` and one of `BetaTests.NamedSuite` alike, for an entry that can remove neither.
    static func matches(_ entry: TestPlanFile.Entry, _ test: DeclaredTest) -> Bool {
        guard entry.isReadable, !test.suite.isEmpty else {
            return false
        }
        guard entry.type == test.suite else {
            return false
        }
        guard let function = entry.function else {
            return true
        }
        return withoutParentheses(function) == withoutParentheses(test.function)
    }

    /// A function identifier with an empty trailing argument list taken off, so `testAddition` and `testAddition()` are the same name.
    ///
    /// Only the empty list: `doublingIsEven(_:)` carries labels a plan spells the same way, and dropping them would match two parameterised tests that differ only in their signature.
    private static func withoutParentheses(_ function: String) -> String {
        function.hasSuffix("()") ? String(function.dropLast(2)) : function
    }
}

private extension TestAnalysis {
    /// The counts and the sections, once the pass over the plans is done.
    ///
    /// With no plan under consideration there is nothing to subtract: SwiftPM has no plans and `swift test` runs every test in every test target, so `declared` is the expected set and every test is in it.
    static func assemble(
        inventory: TestInventory,
        survey: TestPlanSurvey,
        schemes: SchemeSurvey,
        considered: [TestPlanFile],
        join: Join,
        narrowedTo: String?
    ) -> TestAnalysis {
        let (tests, compiledOut) = compiledHere(inventory)
        // Admission is about the plan naming the test, not about the test surviving it: a test an honoured
        // exclusion removes is in a plan and never runs, which is a different fact from one no plan names at
        // all, and folding the two would report a working exclusion as a target nobody wired up.
        let admitted: (DeclaredTest) -> Bool = considered.isEmpty ? { _ in true } : { join.admitted.contains($0) }
        let inAPlan = tests.filter(admitted)
        let outside = tests.filter(join.outsideEveryContainer)
        let neverRun = findings(tests, admitted: admitted, join: join, keeping: { isNeverRun($0, in: $1) })
        // A plan removal decides the test: an honoured exclusion takes it out of the run whatever its body would have done,
        // so it is a never-run and nothing else, and the three figures below partition `in a plan` instead of overlapping.
        let decided = Set(neverRun.map(\.test))
        let conditional = findings(tests, admitted: admitted, join: join, keeping: { isConditional($0, in: $1) })
            .filter { !decided.contains($0.test) }
        let neverRunInAPlan = Set(neverRun.filter { !$0.outsideEveryPlan }.map(\.test))
        let conditionalInAPlan = Set(conditional.filter { !$0.outsideEveryPlan }.map(\.test))
        let tallies = tallying(tests, inAPlan: Set(inAPlan), neverRuns: neverRunInAPlan, conditional: conditionalInAPlan)
        let outsideByTarget = Dictionary(grouping: outside, by: \.target).mapValues(\.count)
        let outsideTargets = tallies.filter { outsideByTarget[$0.name] == $0.declared }
        let outsideNames = Set(outsideTargets.map(\.name))

        return TestAnalysis(
            counts: Counts(
                declared: tests.count,
                inAPlan: inAPlan.count,
                outsideEveryContainer: outside.count,
                runs: inAPlan.count - neverRunInAPlan.count - conditionalInAPlan.count,
                neverRuns: neverRunInAPlan.count,
                conditional: conditionalInAPlan.count
            ),
            targets: tallies.filter { !join.namedTargets.isEmpty ? join.namedTargets.contains($0.name) : true },
            plans: considered.map { summary(of: $0, schemes: schemes.schemes) },
            narrowedTo: narrowedTo,
            neverRun: neverRun,
            conditional: conditional,
            testsInNoPlan: tests.filter { join.namedTargets.contains($0.target) && !join.admitted.contains($0) && !join.outsideEveryContainer($0) },
            // Gated on a plan having been considered at all, not on `namedTargets` being non-empty: a plan whose every
            // target is disabled leaves `namedTargets` empty too, and that must still report every one of them as run
            // by no plan under consideration rather than fall silent because nothing happened to be named.
            targetsInNoPlan: tallies
                .filter { !considered.isEmpty && !join.namedTargets.contains($0.name) && !outsideNames.contains($0.name) }
                .map { unplanned($0, tests: join.byTarget[$0.name] ?? [], schemes: schemes.schemes) },
            schemes: schemes.schemes.map(summary),
            unreadableSchemes: schemes.unreadable,
            targetsOutsideEveryContainer: outsideTargets,
            unresolvedContainers: join.unresolvedContainers,
            exclusions: join.exclusions,
            selections: join.selections,
            retries: considered.compactMap(retry),
            targetsWithNoDeclaredTests: join.namedTargets.subtracting(tallies.map(\.name)).sorted(),
            guessedTargets: inventory.guessedTargets,
            unreadablePlans: survey.unreadable,
            fileScopeTests: tests.filter(\.suite.isEmpty),
            compiledOut: compiledOut
        )
    }

    /// The declared tests this platform compiles, and the ones under an `#if` it provably does not, which the counts leave out and the answer names apart.
    ///
    /// A test an `#if` and its `#else` both declare is one test the compiled clause already carries, so it is neither counted twice nor named as compiled out.
    static func compiledHere(_ inventory: TestInventory) -> (tests: [DeclaredTest], compiledOut: [DeclaredTest]) {
        func key(_ test: DeclaredTest) -> [String] {
            [test.target, test.suite, test.function]
        }
        var compiledOut: [DeclaredTest] = []
        var tests: [DeclaredTest] = []
        for test in inventory.tests {
            if case .compiledOut = test.compilation {
                compiledOut.append(test)
            } else {
                tests.append(test)
            }
        }
        let compiled = Set(tests.map(key))
        return (tests, compiledOut.filter { !compiled.contains(key($0)) })
    }

    /// The tests one disposition rule keeps, each with what decides it and whether any plan admits it.
    static func findings(
        _ tests: [DeclaredTest],
        admitted: (DeclaredTest) -> Bool,
        join: Join,
        keeping rule: (DeclaredTest, Join) -> String?
    ) -> [Finding] {
        tests.compactMap { test in
            guard let cause = rule(test, join) else { return nil }
            return Finding(test: test, cause: cause, outsideEveryPlan: !admitted(test))
        }
    }

    /// What says a test never runs: its own declaration, or an exclusion every plan that admits it honours.
    static func isNeverRun(_ test: DeclaredTest, in join: Join) -> String? {
        switch test.disposition {
        case let .disabled(reason):
            return "@Test(.disabled(\(quoted(reason))))"
        case let .skips(reason):
            return "the body opens throw XCTSkip(\(quoted(reason)))"
        case .excludedByXCTFail:
            return "the body opens XCTFail(…), which reports as an ordinary failure on every surface"
        case .runs, .conditional:
            guard let cause = join.causes[test], join.removals[test, default: 0] >= join.admissions[test, default: 0], join.admissions[test, default: 0] > 0 else {
                return nil
            }
            return cause
        }
    }

    static func isConditional(_ test: DeclaredTest, in _: Join) -> String? {
        guard case let .conditional(marker) = test.disposition else {
            return nil
        }
        return marker
    }

    static func quoted(_ reason: String?) -> String {
        reason.map { "\"\($0)\"" } ?? ""
    }

    /// One row per target the index attributes a test to, ordered by name.
    static func tallying(
        _ tests: [DeclaredTest],
        inAPlan: Set<DeclaredTest>,
        neverRuns: Set<DeclaredTest>,
        conditional: Set<DeclaredTest>
    ) -> [TargetTally] {
        Dictionary(grouping: tests, by: \.target)
            .map { name, group in
                let planned = group.filter(inAPlan.contains)
                let never = planned.filter(neverRuns.contains).count
                let undecided = planned.filter(conditional.contains).count
                return TargetTally(
                    name: name,
                    declared: group.count,
                    inAPlan: planned.count,
                    runs: planned.count - never - undecided,
                    neverRuns: never,
                    conditional: undecided
                )
            }
            .sorted { $0.name < $1.name }
    }

    static func summary(of plan: TestPlanFile, schemes: [SchemeFile]) -> PlanSummary {
        PlanSummary(
            name: plan.name,
            path: plan.path,
            enabledTargets: plan.targets.filter(\.isEnabled).count,
            disabledTargets: plan.targets.filter { !$0.isEnabled }.map(\.name),
            wiredTo: schemes.filter { scheme in
                (scheme.testAction?.planReferences ?? []).contains { scheme.planPath(of: $0) == plan.path }
            }.map(\.name)
        )
    }

    static func summary(of scheme: SchemeFile) -> SchemeSummary {
        SchemeSummary(
            name: scheme.name,
            path: scheme.path,
            isShared: scheme.isShared,
            hasTestAction: scheme.testAction != nil,
            runs: scheme.testAction?.runTargets ?? [],
            plans: (scheme.testAction?.planReferences ?? []).map { scheme.planPath(of: $0) ?? $0.reference },
            superseded: scheme.testAction?.supersededTargets ?? [],
            skipped: scheme.testAction?.testables.filter(\.isSkipped).map(\.target) ?? []
        )
    }

    /// One target no plan names, judged against the schemes read: which of them runs it, and whether any of them was even in a position to.
    ///
    /// A scheme judges a target only where its container holds that target's declaring files, exactly as a plan does: two projects in one repository each have a scheme, and a target one of them never heard of is not a target its scheme declines to run.
    static func unplanned(_ tally: TargetTally, tests: [DeclaredTest], schemes: [SchemeFile]) -> UnplannedTarget {
        let reaching = schemes.filter { scheme in
            tests.contains { Join.inside(scheme.containerScope, $0) }
        }
        return UnplannedTarget(
            tally: tally,
            runBy: reaching.filter { ($0.testAction?.runTargets ?? []).contains(tally.name) }.map(\.name),
            supersededBy: reaching.filter { ($0.testAction?.supersededTargets ?? []).contains(tally.name) }.map(\.name),
            coveredBySchemeRead: !reaching.isEmpty
        )
    }

    static func retry(of plan: TestPlanFile) -> Retry? {
        plan.repetitionMode.map { Retry(plan: plan.name, mode: $0, maximum: plan.maximumRepetitions) }
    }
}
