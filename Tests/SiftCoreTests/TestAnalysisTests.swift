//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// Covers the join between the declared inventory and the test plans: which counts it makes, and what it says a plan's `skippedTests` entry actually does.
///
/// The inventory side is the committed demo project, read as its own repository, so every verdict below is about the real files and the real plans beside them rather than about a fixture written to agree with them.
@Suite(.temporaryDirectories)
struct TestAnalysisTests {
    private static let demoRoot = URL(filePath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("ValidationProjects/TestDemo")

    private static func inventory() throws -> TestInventory {
        let store = try TestSources.makeStore()
        let resolver = ModuleResolver(repoRoot: demoRoot, config: SiftConfig())
        let paths = try FileManager.default.subpathsOfDirectory(atPath: demoRoot.path)
            .filter { $0.hasSuffix(".swift") }
            .sorted()
        let parsed = paths.compactMap { path in
            FileParser.parse(absoluteURL: demoRoot.appendingPathComponent(path), repoRelativePath: path)
        }
        try store.replaceFiles(parsed) { path in
            (resolver.module(for: path), resolver.resolvedModule(for: path) == nil)
        }
        return try TestInventory.read(store: store, repositoryRoot: demoRoot)
    }

    private static func analysis(plan: String? = nil) throws -> TestAnalysis {
        try TestAnalysis.of(
            inventory: inventory(),
            survey: TestPlanDiscovery.plans(under: demoRoot),
            plan: plan
        )
    }

    /// One plan built from JSON, so a shape the three committed plans do not carry can be joined to the real inventory.
    private static func analysis(planJSON: String, named name: String = "Inline") throws -> TestAnalysis {
        let plan = try TestPlanFile.read(Data(planJSON.utf8), name: name, path: "TestPlans/\(name).xctestplan")
        return try TestAnalysis.of(inventory: inventory(), survey: TestPlanSurvey(plans: [plan], unreadable: []))
    }

    private static func exclusion(_ written: String, in analysis: TestAnalysis, sourceLocation: SourceLocation = #_sourceLocation) throws -> TestAnalysis.Exclusion {
        try #require(analysis.exclusions.first { $0.written == written }, sourceLocation: sourceLocation)
    }

    // MARK: - What a skippedTests entry does

    /// The crux: the two entries of the committed `Excluding` plan sit side by side and do opposite things.
    @Test
    func theXCTestEntryIsHonouredAndTheSwiftTestingEntryBesideItDoesNothing() throws {
        let analysis = try Self.analysis(plan: "Excluding")

        let xcTest = try Self.exclusion("CalculatorTests/testAddition()", in: analysis)
        #expect(xcTest.effect == .honoured)
        #expect(xcTest.test?.function == "testAddition()")
        #expect(xcTest.test?.style == .xcTest)
        #expect(xcTest.target == "DemoUnitTests")
        #expect(xcTest.plan == "Excluding")

        let swiftTesting = try Self.exclusion("MathSuite/addsTwoNumbers()", in: analysis)
        #expect(swiftTesting.effect == .ignoredAsSwiftTesting)
        #expect(swiftTesting.test?.function == "addsTwoNumbers()")
        #expect(swiftTesting.test?.style == .swiftTesting)
    }

    /// The same entry without parentheses matches the same test and stops being honoured, which is the whole of the form rule.
    @Test
    func theSameXCTestEntryWithoutParenthesesMatchesTheTestAndIsIgnored() throws {
        let analysis = try Self.analysis(planJSON: """
        {"version":1,"testTargets":[{"skippedTests":["CalculatorTests/testAddition"],
        "target":{"containerPath":"container:TestDemo.xcodeproj","identifier":"30E1","name":"DemoUnitTests"}}]}
        """)

        let entry = try Self.exclusion("CalculatorTests/testAddition", in: analysis)

        #expect(entry.effect == .ignoredWithoutParentheses)
        #expect(entry.test?.function == "testAddition()")
        // Matched, and therefore not the fourth case: the parentheses decide the verdict, never the match.
        #expect(analysis.exclusions.contains { $0.effect == .matchesNothing } == false)
        // The two DemoUnitTests declarations that switch themselves off, and nothing removed by the plan.
        #expect(analysis.counts.neverRuns == 2)
        #expect(analysis.neverRun.contains { $0.test.function == "testAddition()" } == false)
    }

    /// Parentheses do not save a swift-testing entry, because the framework decides it before the form does.
    @Test
    func aSwiftTestingEntryIsIgnoredInEveryFormTheMatchAccepts() throws {
        let analysis = try Self.analysis(planJSON: """
        {"version":1,"testTargets":[{"skippedTests":["MathSuite/addsTwoNumbers()","MathSuite/subtractsTwoNumbers","MathSuite"],
        "target":{"containerPath":"container:TestDemo.xcodeproj","identifier":"30E1","name":"DemoUnitTests"}}]}
        """)

        let allIgnored = analysis.exclusions.allSatisfy { $0.effect == .ignoredAsSwiftTesting }

        #expect(allIgnored)
        // Four `MathSuite` tests for the whole-suite entry, and one each for the two named ones.
        #expect(analysis.exclusions.count == 6)
    }

    /// An entry naming nothing the index declares is its own verdict, never folded into the three above.
    @Test
    func anEntryThatMatchesNoDeclaredTestIsReportedAsMatchingNothing() throws {
        let analysis = try Self.analysis(planJSON: """
        {"version":1,"testTargets":[{"skippedTests":["CalculatorTests/testOldMath()","LegacyTests"],
        "target":{"containerPath":"container:TestDemo.xcodeproj","identifier":"30E1","name":"DemoUnitTests"}}]}
        """)

        #expect(analysis.exclusions.map(\.effect) == [.matchesNothing, .matchesNothing])
        let namedNothing = analysis.exclusions.allSatisfy { $0.test == nil }
        #expect(namedNothing)
        // Unchanged by the plan: an entry that matches nothing excludes nothing.
        #expect(analysis.counts.neverRuns == 2)
    }

    /// A whole-class entry carries no function to put parentheses on, and takes every test of that class with it.
    @Test
    func aWholeClassEntryIsHonouredAndRemovesEveryTestOfThatClass() throws {
        let analysis = try Self.analysis(planJSON: """
        {"version":1,"testTargets":[{"skippedTests":["CalculatorTests"],
        "target":{"containerPath":"container:TestDemo.xcodeproj","identifier":"30E1","name":"DemoUnitTests"}}]}
        """)

        let allHonoured = analysis.exclusions.allSatisfy { $0.effect == .honoured }

        #expect(allHonoured)
        #expect(analysis.exclusions.count == 6)
        // The six tests of the class, plus the disabled swift-testing one the class knows nothing about.
        #expect(analysis.counts.neverRuns == 7)
    }

    // MARK: - The counts

    /// Every count states the same arithmetic the answer prints, over the plan that excludes.
    @Test
    func narrowingToOnePlanCountsItsHonouredExclusionAsATestThatNeverRuns() throws {
        let analysis = try Self.analysis(plan: "Excluding")

        #expect(analysis.counts.declared == 38)
        #expect(analysis.counts.inAPlan == 38)
        #expect(analysis.counts.neverRuns == 3)
        #expect(analysis.counts.conditional == 0)
        #expect(analysis.counts.runs == 35)
        let never = analysis.neverRun.map(\.test.function).sorted()
        #expect(never == ["multipliesLargeNumbers()", "testAddition()", "testSkipsWhenUnsupported()"])
        // In a plan and removed by it, which is not the same fact as a target no plan names.
        #expect(analysis.neverRun.allSatisfy { $0.outsideEveryPlan == false })
    }

    /// A test one plan removes and another runs still runs, because `in a plan` is satisfied by any plan.
    @Test
    func aTestOnlyOnePlanExcludesStillRunsWhenEveryPlanIsRead() throws {
        let analysis = try Self.analysis()

        #expect(analysis.counts.inAPlan == 38)
        #expect(analysis.counts.neverRuns == 2)
        #expect(analysis.counts.runs == 36)
        #expect(analysis.neverRun.contains { $0.test.function == "testAddition()" } == false)
        #expect(analysis.plans.map(\.name) == ["Default", "Excluding", "Retrying"])
    }

    /// With no plan to subtract anything, `declared` is the expected set — the SwiftPM shape, answered rather than refused.
    @Test
    func withNoPlansEveryDeclaredTestIsInTheExpectedSet() throws {
        let analysis = try TestAnalysis.of(inventory: Self.inventory(), survey: TestPlanSurvey(plans: [], unreadable: []))

        #expect(analysis.plans.isEmpty)
        #expect(analysis.counts.declared == 38)
        #expect(analysis.counts.inAPlan == 38)
        #expect(analysis.counts.neverRuns == 2)
        #expect(analysis.counts.runs == 36)
        #expect(analysis.targetsInNoPlan.isEmpty)
        #expect(analysis.exclusions.isEmpty)
    }

    /// A disabled target is left out of every count, and the per-target rows add up to the whole.
    @Test
    func aDisabledTargetIsInNoPlanAndTheRowsAddUpToTheCounts() throws {
        let analysis = try Self.analysis(planJSON: """
        {"version":1,"testTargets":[
        {"enabled":false,"target":{"containerPath":"container:TestDemo.xcodeproj","identifier":"30E1","name":"DemoUnitTests"}},
        {"target":{"containerPath":"container:TestDemo.xcodeproj","identifier":"0339","name":"DemoLogicTests"}}]}
        """)

        #expect(analysis.counts.inAPlan == 8)
        #expect(analysis.targets.map(\.name) == ["DemoLogicTests"])
        #expect(analysis.targetsInNoPlan.map(\.tally.name) == ["Demo Spaced Tests", "DemoUITests", "DemoUnitTests"])
        #expect(analysis.plans.first?.disabledTargets == ["DemoUnitTests"])
        let rowsAddUp = analysis.targets.allSatisfy { $0.runs == $0.inAPlan - $0.neverRuns - $0.conditional }
        #expect(rowsAddUp)
    }

    /// A target spelled with spaces is matched with its spaces, because that is the spelling both sides use.
    @Test
    func aTargetNamedWithSpacesIsMatchedWithThem() throws {
        let analysis = try Self.analysis(plan: "Default")
        let spaced = try #require(analysis.targets.first { $0.name == "Demo Spaced Tests" })

        #expect(spaced.declared == 2)
        #expect(spaced.inAPlan == 2)
        #expect(spaced.runs == 2)
    }

    // MARK: - selectedTests, and the rest of the residue

    /// `selectedTests` narrows by the same match rule, and every entry is named because its swift-testing behaviour is unmeasured.
    @Test
    func selectedTestsNarrowsTheCountAndEveryEntryIsNamed() throws {
        let analysis = try Self.analysis(planJSON: """
        {"version":1,"testTargets":[{"selectedTests":["CalculatorTests/testAddition()","MathSuite/addsTwoNumbers()"],
        "target":{"containerPath":"container:TestDemo.xcodeproj","identifier":"30E1","name":"DemoUnitTests"}}]}
        """)

        #expect(analysis.counts.inAPlan == 2)
        #expect(analysis.counts.runs == 2)
        #expect(analysis.selections.map(\.written) == ["CalculatorTests/testAddition()", "MathSuite/addsTwoNumbers()"])
        #expect(analysis.selections.map(\.matched) == [1, 1])
        #expect(analysis.testsInNoPlan.count == 14)
    }

    /// A plan target the index declares no test in is named, because every count above is silent about it.
    @Test
    func aPlanTargetWithNoDeclaredTestIsNamed() throws {
        let analysis = try Self.analysis(planJSON: """
        {"version":1,"testTargets":[{"target":{"containerPath":"container:TestDemo.xcodeproj","identifier":"AAAA","name":"DepotKitTests"}}]}
        """)

        #expect(analysis.targetsWithNoDeclaredTests == ["DepotKitTests"])
        #expect(analysis.counts.inAPlan == 0)
    }

    /// A plan's repetition setting is carried verbatim, since it is what makes XCTest's own tally disagree with this one.
    @Test
    func aRetryingPlanIsCarriedVerbatim() throws {
        let analysis = try Self.analysis(plan: "Retrying")

        #expect(analysis.retries.map(\.mode) == ["retryOnFailure"])
        #expect(analysis.retries.map(\.maximum) == [3])
    }

    /// A `--plan` naming no plan found refuses, and the refusal lists what there was.
    @Test
    func aPlanNameNothingCarriesRefusesWithTheNamesThatWereFound() throws {
        #expect(throws: TestAnalysisError.self) {
            try Self.analysis(plan: "Nightly")
        }
        let refusal = TestAnalysisError.noSuchPlan(name: "Nightly", found: ["Default", "Excluding"]).description
        #expect(refusal.contains("Default, Excluding"))
        #expect(refusal.contains("no test plan is named Nightly"))
    }

    // MARK: - The shapes the demo project does not carry

    /// One declared test written by hand, for a shape the committed demo project has no file for — a nested suite, a body that is both conditional and excluded, and a target declared outside the plans' own container.
    private static func declared(
        target: String,
        suite: String,
        function: String,
        path: String,
        style: TestSymbol.Style = .xcTest,
        disposition: DeclaredTest.Disposition = .runs
    ) -> DeclaredTest {
        DeclaredTest(
            target: target,
            targetWasGuessed: false,
            suite: suite,
            function: function,
            style: style,
            displayName: nil,
            disposition: disposition,
            path: path,
            line: 1
        )
    }

    /// One plan built from JSON joined to an inventory built by hand, both stated in the same test.
    private static func analysis(of tests: [DeclaredTest], planJSON: String, planPath: String = "Alpha/TestPlans/Inline.xctestplan", guessed: [String] = []) throws -> TestAnalysis {
        let plan = try TestPlanFile.read(Data(planJSON.utf8), name: "Inline", path: planPath)
        return try TestAnalysis.of(
            inventory: TestInventory(tests: tests, guessedTargets: guessed),
            survey: TestPlanSurvey(plans: [plan], unreadable: [])
        )
    }

    /// A plan removal decides the test: it never runs, whatever its body would have done at runtime, and the three figures partition `in a plan` instead of overlapping.
    @Test
    func aTestBothConditionalAndExcludedIsCountedOnceAndAsANeverRun() throws {
        let tests = [
            Self.declared(target: "AlphaTests", suite: "CalculatorTests", function: "testSkipsOnACondition()", path: "Alpha/AlphaTests/CalculatorTests.swift", disposition: .conditional(marker: "the body opens try XCTSkipIf(…)")),
            Self.declared(target: "AlphaTests", suite: "CalculatorTests", function: "testOne()", path: "Alpha/AlphaTests/CalculatorTests.swift"),
        ]
        let analysis = try Self.analysis(of: tests, planJSON: """
        {"version":1,"testTargets":[{"skippedTests":["CalculatorTests/testSkipsOnACondition()"],
        "target":{"containerPath":"container:Alpha.xcodeproj","identifier":"30E1","name":"AlphaTests"}}]}
        """)

        #expect(analysis.counts.inAPlan == 2)
        #expect(analysis.counts.runs + analysis.counts.neverRuns + analysis.counts.conditional == analysis.counts.inAPlan)
        #expect(analysis.counts.runs == 1)
        #expect(analysis.counts.neverRuns == 1)
        #expect(analysis.counts.conditional == 0)
        #expect(analysis.conditional.isEmpty)
        #expect(analysis.neverRun.map(\.test.function) == ["testSkipsOnACondition()"])
    }

    /// The identifier Xcode writes for a test of a nested class names it here too, rather than being reported as a spelling that excludes nothing.
    @Test
    func theIdentifierForATestOfANestedSuiteIsMatched() throws {
        let tests = [
            Self.declared(target: "AlphaTests", suite: "AlphaTests.NamedSuite", function: "testX()", path: "Alpha/AlphaTests/NamedSuite.swift"),
        ]
        let analysis = try Self.analysis(of: tests, planJSON: """
        {"version":1,"testTargets":[{"skippedTests":["AlphaTests/NamedSuite/testX()"],
        "target":{"containerPath":"container:Alpha.xcodeproj","identifier":"30E1","name":"AlphaTests"}}]}
        """)

        let entry = try Self.exclusion("AlphaTests/NamedSuite/testX()", in: analysis)

        #expect(entry.effect == .honoured)
        #expect(entry.test?.function == "testX()")
        #expect(analysis.counts.runs == 0)
        #expect(analysis.counts.neverRuns == 1)
    }

    /// An entry naming only the last step of a nested suite removes nothing, because one entry can remove at most one suite's tests and two suites in a target can share a last step.
    @Test
    func anEntryNamingOnlyTheLastStepOfANestedSuiteRemovesNeitherOfThem() throws {
        let tests = [
            Self.declared(target: "AlphaTests", suite: "AlphaTests.NamedSuite", function: "testX()", path: "Alpha/AlphaTests/NamedSuite.swift"),
            Self.declared(target: "AlphaTests", suite: "BetaTests.NamedSuite", function: "testX()", path: "Alpha/AlphaTests/BetaTests.swift"),
        ]
        let analysis = try Self.analysis(of: tests, planJSON: """
        {"version":1,"testTargets":[{"skippedTests":["NamedSuite/testX()"],
        "target":{"containerPath":"container:Alpha.xcodeproj","identifier":"30E1","name":"AlphaTests"}}]}
        """)

        #expect(analysis.counts.inAPlan == 2)
        #expect(analysis.counts.runs == 2)
        #expect(analysis.counts.neverRuns == 0)
        #expect(try Self.exclusion("NamedSuite/testX()", in: analysis).effect == .matchesNothing)
    }

    /// An entry with an empty step is answered as unreadable, which is a different verdict from naming nothing and has a different next move.
    @Test
    func anEntryWithAnEmptyStepIsAnsweredAsUnreadable() throws {
        let tests = [
            Self.declared(target: "AlphaTests", suite: "CalculatorTests", function: "testOne()", path: "Alpha/AlphaTests/CalculatorTests.swift"),
        ]
        let analysis = try Self.analysis(of: tests, planJSON: """
        {"version":1,"testTargets":[{"skippedTests":["CalculatorTests//testOne()"],
        "target":{"containerPath":"container:Alpha.xcodeproj","identifier":"30E1","name":"AlphaTests"}}]}
        """)

        #expect(try Self.exclusion("CalculatorTests//testOne()", in: analysis).effect == .unreadable)
        #expect(analysis.counts.runs == 1)
    }

    // MARK: - What a plan's container confines it to

    /// A target declared outside the container of every plan is not a target a plan declined, so nothing subtracts it from `in a plan`.
    @Test
    func aTargetOutsideEveryContainerIsReportedAndNeverSubtractedFromTheCount() throws {
        let tests = [
            Self.declared(target: "AlphaTests", suite: "CalculatorTests", function: "testOne()", path: "Alpha/AlphaTests/CalculatorTests.swift"),
            Self.declared(target: "DepotKitTests", suite: "CalculatorTests", function: "testTwo()", path: "Tests/DepotKitTests/CalculatorTests.swift"),
        ]
        let analysis = try Self.analysis(of: tests, planJSON: """
        {"version":1,"testTargets":[{"target":{"containerPath":"container:Alpha.xcodeproj","identifier":"30E1","name":"AlphaTests"}}]}
        """)

        #expect(analysis.counts.declared == 2)
        #expect(analysis.counts.inAPlan == 1)
        #expect(analysis.counts.outsideEveryContainer == 1)
        #expect(analysis.targetsOutsideEveryContainer.map(\.name) == ["DepotKitTests"])
        #expect(analysis.targetsInNoPlan.isEmpty)
        #expect(analysis.testsInNoPlan.isEmpty)
    }

    /// A target of the same name inside the container is still judged, so the narrowing above is by the declaring file and not by the target's name.
    @Test
    func aTargetInsideTheContainerThatNoPlanNamesIsStillReportedAsInNoPlan() throws {
        let tests = [
            Self.declared(target: "AlphaTests", suite: "CalculatorTests", function: "testOne()", path: "Alpha/AlphaTests/CalculatorTests.swift"),
            Self.declared(target: "BetaTests", suite: "CalculatorTests", function: "testTwo()", path: "Alpha/BetaTests/CalculatorTests.swift"),
        ]
        let analysis = try Self.analysis(of: tests, planJSON: """
        {"version":1,"testTargets":[{"target":{"containerPath":"container:Alpha.xcodeproj","identifier":"30E1","name":"AlphaTests"}}]}
        """)

        #expect(analysis.targetsInNoPlan.map(\.tally.name) == ["BetaTests"])
        #expect(analysis.targetsOutsideEveryContainer.isEmpty)
        #expect(analysis.counts.outsideEveryContainer == 0)
    }

    /// A container that cannot be read narrows nothing and is said so, because widening in silence would judge a target no plan names.
    @Test
    func aContainerThatCannotBeReadIsNamedAndNarrowsNothing() throws {
        let tests = [
            Self.declared(target: "AlphaTests", suite: "CalculatorTests", function: "testOne()", path: "Alpha/AlphaTests/CalculatorTests.swift"),
            Self.declared(target: "DepotKitTests", suite: "CalculatorTests", function: "testTwo()", path: "Tests/DepotKitTests/CalculatorTests.swift"),
        ]
        let analysis = try Self.analysis(of: tests, planJSON: """
        {"version":1,"testTargets":[{"target":{"identifier":"30E1","name":"AlphaTests"}}]}
        """)

        #expect(analysis.unresolvedContainers.map(\.target) == ["AlphaTests"])
        #expect(analysis.unresolvedContainers.map(\.written) == [nil])
        #expect(analysis.counts.outsideEveryContainer == 0)
        #expect(analysis.targetsOutsideEveryContainer.isEmpty)
        #expect(analysis.targetsInNoPlan.map(\.tally.name) == ["DepotKitTests"])
    }

    // MARK: - A plan admitting nothing at all

    /// A plan whose only target is disabled admits nothing, but the target itself must not vanish along with `inAPlan` — it is a target that runs in no plan under consideration, the same fact as one no plan names at all.
    @Test
    func aPlanWhoseOnlyTargetIsDisabledStillReportsItAsInNoPlan() throws {
        let tests = [
            Self.declared(target: "AlphaTests", suite: "CalculatorTests", function: "testOne()", path: "Alpha/AlphaTests/CalculatorTests.swift"),
        ]
        let analysis = try Self.analysis(of: tests, planJSON: """
        {"version":1,"testTargets":[
        {"enabled":false,"target":{"containerPath":"container:Alpha.xcodeproj","identifier":"30E1","name":"AlphaTests"}}]}
        """)

        #expect(analysis.counts.inAPlan == 0)
        #expect(analysis.counts.runs == 0)
        #expect(analysis.targetsInNoPlan.map(\.tally.name) == ["AlphaTests"])
    }

    /// Two plans enable a target, and one of them carries two `skippedTests` entries — a whole-suite one and a function-level one — both honoured against the same test.
    ///
    /// `removals` counts plans, the same unit `admissions` does, so that test must cost the excluding plan one removal, not two, or the other plan's admission is swallowed and a test that still runs there is reported as never running.
    @Test
    func aTestTwoEntriesInOnePlanRemoveCostsThatPlanOneRemovalNotTwo() throws {
        let tests = [
            Self.declared(target: "AlphaTests", suite: "CalculatorTests", function: "testOne()", path: "Alpha/AlphaTests/CalculatorTests.swift"),
        ]
        let excludingBoth = try TestPlanFile.read(Data("""
        {"version":1,"testTargets":[{"skippedTests":["CalculatorTests","CalculatorTests/testOne()"],
        "target":{"containerPath":"container:Alpha.xcodeproj","identifier":"30E1","name":"AlphaTests"}}]}
        """.utf8), name: "Excluding", path: "Alpha/TestPlans/Excluding.xctestplan")
        let excludingNothing = try TestPlanFile.read(Data("""
        {"version":1,"testTargets":[{"target":{"containerPath":"container:Alpha.xcodeproj","identifier":"30E1","name":"AlphaTests"}}]}
        """.utf8), name: "Default", path: "Alpha/TestPlans/Default.xctestplan")

        let analysis = try TestAnalysis.of(
            inventory: TestInventory(tests: tests, guessedTargets: []),
            survey: TestPlanSurvey(plans: [excludingBoth, excludingNothing], unreadable: [])
        )

        #expect(analysis.counts.inAPlan == 1)
        #expect(analysis.counts.runs == 1)
        #expect(analysis.counts.neverRuns == 0)
        #expect(analysis.neverRun.isEmpty)
    }
}
