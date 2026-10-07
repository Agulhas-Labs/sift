//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// Covers the answer `test --analyse` prints: the verdict and its arithmetic, and the rule that a section with nothing in it is not printed at all.
@Suite(.temporaryDirectories)
struct TestAnalysisRendererTests {
    private static let demoRoot = URL(filePath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("ValidationProjects/TestDemo")

    private static func rendered(plan: String? = nil) throws -> String {
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
        let analysis = try TestAnalysis.of(
            inventory: TestInventory.read(store: store, repositoryRoot: demoRoot),
            survey: TestPlanDiscovery.plans(under: demoRoot),
            plan: plan
        )
        return TestAnalysisRenderer().render(analysis)
    }

    /// The verdict leads, and every figure in it is followed by how it was made.
    @Test
    func theVerdictLeadsAndCarriesItsArithmetic() throws {
        let answer = try Self.rendered(plan: "Excluding")
        let lines = answer.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)

        #expect(lines[0].hasPrefix("1 test plan read live off disk — narrowed by --plan Excluding"))
        #expect(lines[2] == "⚠ sift test --analyse — 38 declared · 38 in a plan · 35 run · 3 never run · 0 conditional — 4 targets, 1 plan")
        #expect(lines[3] == "  runs 35 = 38 in a plan − 3 never runs − 0 conditional")
    }

    /// The two exclusions of the committed plan are named under headings that say opposite things.
    @Test
    func theTwoExclusionsAreNamedWithTheirOppositeVerdicts() throws {
        let answer = try Self.rendered(plan: "Excluding")

        #expect(answer.contains("""
        plan exclusions with no effect (1)
          Excluding: DemoUnitTests skippedTests "MathSuite/addsTwoNumbers()" — swift-testing, ignored by Xcode in every identifier shape measured; the test runs
        """))
        #expect(answer.contains("plan exclusions that work and leave no trace (1)"))
        #expect(answer.contains("Move the exclusion into the test instead"))
    }

    /// A section with nothing in it is nothing, not an empty heading.
    @Test
    func aSectionWithNoResidueIsNotPrintedAtAll() throws {
        let answer = try Self.rendered(plan: "Default")

        #expect(answer.contains("conditional — decided at runtime") == false)
        #expect(answer.contains("plan exclusions") == false)
        #expect(answer.contains("selectedTests") == false)
        #expect(answer.contains("would not decode") == false)
        #expect(answer.contains("file scope") == false)
        #expect(answer.contains("repetition") == false)
        #expect(answer.contains("never runs (2)"))
    }

    /// Every target keeps the spelling both a plan and an enumeration use, spaces included, and the table is ordered by name.
    @Test
    func theTableNamesEveryTargetAsBothSidesSpellIt() throws {
        let answer = try Self.rendered(plan: "Default")

        #expect(answer.contains("target             declared  in a plan  runs  never runs  conditional"))
        #expect(answer.contains("  Demo Spaced Tests       2          2     2           0            0"))
        #expect(answer.contains("  DemoUnitTests          16         16    14           2            0"))
    }

    /// A repository with no plan is answered rather than refused, and the answer says why nothing is subtracted.
    @Test
    func withNoPlanTheAnswerSaysDeclaredIsTheExpectedSet() throws {
        let empty = TestInventory(tests: [], guessedTargets: [])
        let analysis = try TestAnalysis.of(inventory: empty, survey: TestPlanSurvey(plans: [], unreadable: []))
        let answer = TestAnalysisRenderer().render(analysis)

        #expect(answer.hasPrefix("no .xctestplan under this repository — SwiftPM runs every test in every test target"))
        #expect(answer.contains("✔ sift test --analyse — 0 declared · 0 in a plan · 0 run"))
    }

    /// A plan file that would not decode is declared, because nothing in it was counted.
    @Test
    func aPlanThatWouldNotDecodeIsDeclaredRatherThanOmitted() throws {
        let survey = TestPlanSurvey(
            plans: [],
            unreadable: [TestPlanSurvey.Unreadable(path: "TestPlans/Broken.xctestplan", reason: "not a test plan")]
        )
        let analysis = try TestAnalysis.of(inventory: TestInventory(tests: [], guessedTargets: []), survey: survey)
        let answer = TestAnalysisRenderer().render(analysis)

        #expect(answer.contains("plans that would not decode (1) — nothing in them is counted above"))
        #expect(answer.contains("  TestPlans/Broken.xctestplan — not a test plan"))
    }

    // MARK: - The sections that carry a number

    /// One test written by hand, for the sections the committed demo project prints none of.
    private static func declared(target: String, suite: String, function: String, path: String) -> DeclaredTest {
        DeclaredTest(
            target: target,
            targetWasGuessed: false,
            suite: suite,
            function: function,
            style: .xcTest,
            displayName: nil,
            disposition: .runs,
            path: path,
            line: 1
        )
    }

    private static func rendered(of tests: [DeclaredTest], planJSON: String, guessed: [String] = []) throws -> String {
        let plan = try TestPlanFile.read(Data(planJSON.utf8), name: "Inline", path: "Alpha/TestPlans/Inline.xctestplan")
        let analysis = try TestAnalysis.of(
            inventory: TestInventory(tests: tests, guessedTargets: guessed),
            survey: TestPlanSurvey(plans: [plan], unreadable: [])
        )
        return TestAnalysisRenderer().render(analysis)
    }

    /// Every section that carries a number prints it, and each says what its own number is about.
    @Test
    func eachSectionThatCarriesANumberSaysWhatItCounts() throws {
        let answer = try Self.rendered(
            of: [
                Self.declared(target: "AlphaTests", suite: "CalculatorTests", function: "testOne()", path: "Alpha/AlphaTests/CalculatorTests.swift"),
                Self.declared(target: "AlphaTests", suite: "CalculatorTests", function: "testTwo()", path: "Alpha/AlphaTests/CalculatorTests.swift"),
                Self.declared(target: "AlphaTests", suite: "", function: "testThree()", path: "Alpha/AlphaTests/AlphaHelpers.swift"),
                Self.declared(target: "BetaTests", suite: "CalculatorTests", function: "testOne()", path: "Alpha/BetaTests/CalculatorTests.swift"),
                Self.declared(target: "DepotKitTests", suite: "CalculatorTests", function: "testOne()", path: "Tests/DepotKitTests/CalculatorTests.swift"),
            ],
            planJSON: """
            {"version":1,"defaultOptions":{"testRepetitionMode":"retryOnFailure","maximumTestRepetitions":3},"testTargets":[
            {"selectedTests":["CalculatorTests/testOne()"],"target":{"containerPath":"container:Alpha.xcodeproj","identifier":"30E1","name":"AlphaTests"}},
            {"target":{"containerPath":"container:Alpha.xcodeproj","identifier":"30E2","name":"AlphaKit"}}]}
            """,
            guessed: ["BetaTests"]
        )

        #expect(answer.contains("whole targets named by no .xctestplan found under this repository (1 targets, 1 tests)"))
        #expect(answer.contains("  BetaTests — 1 declared tests, named by no plan under consideration"))
        #expect(answer.contains("a scheme's TestAction runs the targets it lists with no plan involved"))
        #expect(answer.contains("targets outside every plan's container (1 targets, 1 tests)"))
        #expect(answer.contains("  DepotKitTests — 1 declared tests, declared outside the container of every plan above"))
        #expect(answer.contains("tests left out by selectedTests (2)"))
        #expect(answer.contains("selectedTests — narrowed by the same match rule, and unmeasured for swift-testing (1)"))
        #expect(answer.contains("repetition (1)"))
        #expect(answer.contains("  Inline: testRepetitionMode retryOnFailure, up to 3 attempts"))
        #expect(answer.contains("plan targets the index declares no test in (1)"))
        #expect(answer.contains("  AlphaKit — a plan runs it and no declared test is attributed to it"))
        #expect(answer.contains("⚠ module guessed — no build file declares the files of: BetaTests"))
        #expect(answer.contains("declared at file scope (1)"))
        #expect(answer.contains("  AlphaTests/(file scope)/testThree()  Alpha/AlphaTests/AlphaHelpers.swift:1"))
    }

    /// The answer never says a target no plan names is run by nothing, because nothing here reads what runs it.
    @Test
    func aTargetNoPlanNamesIsNeverCalledUnrunAndDoesNotOpenTheVerdict() throws {
        let answer = try Self.rendered(
            of: [
                Self.declared(target: "AlphaTests", suite: "CalculatorTests", function: "testOne()", path: "Alpha/AlphaTests/CalculatorTests.swift"),
                Self.declared(target: "DepotKitTests", suite: "CalculatorTests", function: "testTwo()", path: "Tests/DepotKitTests/CalculatorTests.swift"),
            ],
            planJSON: """
            {"version":1,"testTargets":[{"target":{"containerPath":"container:Alpha.xcodeproj","identifier":"30E1","name":"AlphaTests"}}]}
            """
        )

        #expect(answer.contains("run by nothing") == false)
        #expect(answer.contains("is never run by anything") == false)
        #expect(answer.contains("✔ sift test --analyse — 2 declared · 1 in a plan · 1 run"))
        #expect(answer.contains("  in a plan 1 = 2 declared − 1 outside every plan's container − 0 no plan under consideration admits"))
    }

    /// A container that could not be read, and an entry that could not be read, are each said rather than folded into a verdict about something else.
    @Test
    func whatCouldNotBeReadIsSaidRatherThanGuessedAt() throws {
        let answer = try Self.rendered(
            of: [
                Self.declared(target: "AlphaTests", suite: "CalculatorTests", function: "testOne()", path: "Alpha/AlphaTests/CalculatorTests.swift"),
            ],
            planJSON: """
            {"version":1,"testTargets":[{"skippedTests":["CalculatorTests//testOne()"],
            "target":{"containerPath":"TestDemo.xcodeproj","identifier":"30E1","name":"AlphaTests"}}]}
            """
        )

        #expect(answer.contains("plan targets whose container could not be resolved (1)"))
        #expect(answer.contains("  Inline: AlphaTests containerPath \"TestDemo.xcodeproj\" — not read as a directory under this repository"))
        #expect(answer.contains("plan entries that could not be read (1)"))
        #expect(answer.contains("could not be read as a Target/Type/function identifier"))
    }

    /// A `skippedTests` entry naming a whole class carries no function to put parentheses on, and is reported honoured on the same wording as a function-level entry — measured 23 Sep 2026 on `ValidationProjects/TestDemo` (Docs/Design.md, next to the function-level measurement).
    @Test
    func aWholeClassExclusionIsReportedHonoured() throws {
        let answer = try Self.rendered(
            of: [
                Self.declared(target: "AlphaTests", suite: "StringHelperTests", function: "testJoining()", path: "Alpha/AlphaTests/StringHelperTests.swift"),
            ],
            planJSON: """
            {"version":1,"testTargets":[{"skippedTests":["StringHelperTests"],
            "target":{"containerPath":"container:Alpha.xcodeproj","identifier":"30E1","name":"AlphaTests"}}]}
            """
        )

        #expect(answer.contains("plan exclusions that work and leave no trace"))
        #expect(answer.contains(
            "honoured: AlphaTests/StringHelperTests/testJoining() is removed from the run and leaves no log line, no .xcresult node and a tally smaller by one."
        ))
    }
}
