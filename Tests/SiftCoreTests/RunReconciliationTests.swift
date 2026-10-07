//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// Covers the join between a finished run's own output and the inventory the index declares: what the arithmetic makes of a run that died part-way, of a retry, and of a name nothing in scope claims, the answer printed over it, and the refusals the reader owes.
@Suite(.temporaryDirectories)
struct RunReconciliationTests {
    // MARK: - What the index declares

    /// Three ordinary XCTest methods in one bundle, which is the whole of what a run of this package is supposed to report.
    private static var palletTests: (path: String, source: String) {
        (
            "GizmoTests/PalletTests.swift",
            """
            import XCTest

            final class PalletTests: XCTestCase {
                func testOne() {
                    XCTAssertEqual(1, 1)
                }

                func testTwo() {
                    XCTAssertEqual(2, 2)
                }

                func testThree() {
                    XCTAssertEqual(3, 3)
                }
            }
            """
        )
    }

    /// One method switched off by the `XCTFail(…)` opening its body, beside one that runs.
    private static var conveyorBeltTests: (path: String, source: String) {
        (
            "GizmoTests/ConveyorBeltTests.swift",
            """
            import XCTest

            final class ConveyorBeltTests: XCTestCase {
                func testExcludedInSource() {
                    XCTFail("switched off")
                }

                func testRunsOrdinarily() {
                    XCTAssertEqual(2 + 2, 4)
                }
            }
            """
        )
    }

    /// Two suites declaring one function name, which is the shape a Swift Testing log cannot tell apart: its lines carry the function and no suite at all.
    private static var twoSuitesOneFunction: (path: String, source: String) {
        (
            "GizmoTests/HopperGaugeTests.swift",
            """
            import Testing

            struct HopperGaugeTests {
                @Test func shoutingWorks() {}
            }

            struct PalletTests {
                @Test func shoutingWorks() {}
            }
            """
        )
    }

    /// A second test target, which the scope below does not admit.
    private static var depotKitTests: (path: String, source: String) {
        (
            "DepotKitTests/DepotKitTests.swift",
            """
            import XCTest

            final class DepotKitTests: XCTestCase {
                func testOne() {}

                func testTwo() {}
            }
            """
        )
    }

    private static var manifest: String {
        """
        // swift-tools-version: 6.0
        import PackageDescription

        let package = Package(
            name: "gizmo",
            targets: [
                .target(name: "GizmoCore"),
                .testTarget(name: "GizmoTests", dependencies: ["GizmoCore"]),
            ]
        )
        """
    }

    // MARK: - Fixtures

    /// The inventory of a set of fixture files, written at their repo-relative paths so the body reader has something to read, with each file's target taken from its first path component.
    private static func inventory(_ files: [(path: String, source: String)]) throws -> TestInventory {
        let root = try TemporaryDirectory.make("reconciliation")
        let store = try TestSources.makeStore()
        let parsed = try files.map { try TestSources.parsed($0.source, path: $0.path, in: root) }
        try store.replaceFiles(parsed) { path in
            (path.split(separator: "/").first.map(String.init) ?? path, false)
        }
        return try TestInventory.read(store: store, repositoryRoot: root)
    }

    private static func outcomes(_ lines: [String]) -> RunTestOutcomes {
        var outcomes = RunTestOutcomes()
        for line in lines {
            outcomes.read(line)
        }
        return outcomes
    }

    /// What the reconciler makes of `lines` over `files`, inside a container that admits one test target.
    private static func reconcile(_ files: [(path: String, source: String)], reporting lines: [String]) throws -> RunReconciliation {
        try RunReconciler.reconcile(
            inventory: inventory(files),
            outcomes: outcomes(lines),
            scope: RunReconciliation.Scope(manifest: "Package.swift", targets: ["GizmoTests"], conditionalTargets: false, logPath: "run.log")
        )
    }

    private static func started(_ name: String) -> String {
        "Test Case '\(name)' started."
    }

    private static func passed(_ name: String) -> String {
        "Test Case '\(name)' passed (0.100 seconds)."
    }

    private static func failed(_ name: String) -> String {
        "Test Case '\(name)' failed (0.100 seconds)."
    }

    /// A run of the three-method bundle in which every one of them reported an ending.
    private static var everyPalletTestPassed: [String] {
        ["testOne", "testTwo", "testThree"].flatMap {
            [started("-[GizmoTests.PalletTests \($0)]"), passed("-[GizmoTests.PalletTests \($0)]")]
        }
    }

    // MARK: - The arithmetic

    /// A tally counts what reported, so a run that died part-way loses the tests that never started; the index holds the other number, and the join is the only place the gap is visible.
    @Test
    func aRunThatEndedPartWayNamesWhatNeverReportedAndIsNotGreenWhateverItsSummarySaid() throws {
        let one = "-[GizmoTests.PalletTests testOne]"
        let two = "-[GizmoTests.PalletTests testTwo]"

        let reconciliation = try Self.reconcile([Self.palletTests], reporting: [
            Self.started(one), Self.passed(one),
            Self.started(two), Self.passed(two),
            "Executed 2 tests, with 0 failures (0 unexpected) in 0.200 (0.204) seconds",
            "** TEST SUCCEEDED **",
        ])

        #expect(reconciliation.missing.map(\.enumerated) == ["GizmoTests/PalletTests/testThree()"])
        #expect(reconciliation.counts.missing == 1)
        #expect(reconciliation.counts.expected == 3)
        #expect(reconciliation.counts.ran == 2)
        #expect(reconciliation.isGreen == false)
    }

    /// One rule in both directions: a retry across iterations is an attempt at one test, and a second ending inside one iteration is a duplicate no retry setting explains.
    @Test
    func aRetryAcrossIterationsCountsOnceAndASecondEndingInsideOneIterationIsDuplicated() throws {
        let retried = "-[GizmoTests.PalletTests testOne]"
        let twice = "-[GizmoTests.PalletTests testTwo]"
        let third = "-[GizmoTests.PalletTests testThree]"

        let reconciliation = try Self.reconcile([Self.palletTests], reporting: [
            "Test Case '\(retried)' started (Iteration 1 of 2).",
            Self.failed(retried),
            "Test Case '\(retried)' started (Iteration 2 of 2).",
            Self.passed(retried),
            Self.started(twice), Self.passed(twice), Self.passed(twice),
            Self.started(third), Self.passed(third),
        ])

        #expect(reconciliation.iterations == 2)
        #expect(reconciliation.counts.ran == 3)
        #expect(reconciliation.counts.passed == 3)
        #expect(reconciliation.counts.missing == 0)
        #expect(reconciliation.failed.isEmpty)
        #expect(reconciliation.duplicated.map(\.test.enumerated) == ["GizmoTests/PalletTests/testTwo()"])
        #expect(reconciliation.duplicated.first?.iteration == 1)
        #expect(reconciliation.duplicated.first?.endings == 2)
        #expect(reconciliation.counts.duplicated == 1)
        #expect(reconciliation.isGreen == false)
    }

    /// A test switched off in source reports as an ordinary failure, so it is lifted out of the arithmetic entirely: counted as a failure where the run reported one, and as missing where the run reported nothing.
    @Test
    func aTestExcludedByAnXCTFailOpeningIsNeitherAFailureNorMissing() throws {
        let excluded = "-[GizmoTests.ConveyorBeltTests testExcludedInSource]"
        let ordinary = "-[GizmoTests.ConveyorBeltTests testRunsOrdinarily]"

        let reported = try Self.reconcile([Self.conveyorBeltTests], reporting: [
            Self.started(excluded), Self.failed(excluded),
            Self.started(ordinary), Self.passed(ordinary),
        ])
        let unreported = try Self.reconcile([Self.conveyorBeltTests], reporting: [
            Self.started(ordinary), Self.passed(ordinary),
        ])

        #expect(reported.excluded.map(\.test.enumerated) == ["GizmoTests/ConveyorBeltTests/testExcludedInSource()"])
        #expect(reported.excluded.first?.ending == .failed)
        #expect(reported.failed.isEmpty)
        #expect(reported.counts.failed == 0)
        #expect(reported.counts.expected == 1)
        #expect(reported.isGreen)

        let onlyExcluded = try #require(unreported.excluded.first)

        #expect(onlyExcluded.ending == nil)
        #expect(unreported.missing.isEmpty)
        #expect(unreported.counts.missing == 0)
    }

    /// An ending that claims no test in scope is stated rather than counted, and a target the run's own container does not hold is named as outside it rather than reported missing over a run it was never part of.
    @Test
    func anUnclaimedEndingIsStatedAndATargetOutsideTheContainerIsNotMissing() throws {
        let ghost = "-[GhostKit.MissingWidget testNothing]"

        let reconciliation = try Self.reconcile(
            [Self.palletTests, Self.depotKitTests],
            reporting: Self.everyPalletTestPassed + [Self.started(ghost), Self.passed(ghost)]
        )

        #expect(reconciliation.unclaimed == [ghost])
        #expect(reconciliation.outsideScope == [RunReconciliation.OutsideScope(target: "DepotKitTests", declared: 2)])
        #expect(reconciliation.missing.isEmpty)
        #expect(reconciliation.counts.expected == 3)
        #expect(reconciliation.isGreen)
    }

    /// An XCTest ending no declaration claims is named on `sift run`'s inventory line, so a reported count short of what ran never reads as the whole run.
    @Test
    func anUnclaimedXCTestEndingIsNamedOnTheInventoryLine() throws {
        let ghost = "-[GhostKit.MissingWidget testNothing]"

        let reconciliation = try Self.reconcile([Self.palletTests], reporting: Self.everyPalletTestPassed + [Self.started(ghost), Self.passed(ghost)])

        #expect(RunInventoryCheck.reconciled(reconciliation).lines == ["inventory: 3 declared, 3 reported (1 more XCTest ending no declared test claims: \(ghost))"])
    }

    /// Where one reported name cannot be told apart between several declared tests, the group is reconciled by count: the answer says how many of how many never reported and names none of them, and that number still adds up in the counts line.
    @Test
    func anAmbiguousGroupReportsAShortfallInsteadOfGuessingWhichTestNeverRan() throws {
        let reconciliation = try Self.reconcile([Self.twoSuitesOneFunction], reporting: [
            "Test shoutingWorks() started.",
            "Test shoutingWorks() passed after 0.001 seconds.",
        ])

        let shortfall = try #require(reconciliation.shortfalls.first)

        #expect(shortfall.function == "shoutingWorks")
        #expect(shortfall.sentence == "1 of these 2 never reported")
        #expect(reconciliation.missing.isEmpty)
        #expect(reconciliation.counts.missing == 1)
        #expect(reconciliation.counts.expected == 2)
        #expect(reconciliation.isGreen == false)
    }

    // MARK: - The printed answer

    /// A pass names what it covered, and the counts line under it is the whole of the arithmetic.
    @Test
    func theRendererLeadsAGreenRunWithWhatItCoveredAndTheCountsLine() throws {
        let reconciliation = try Self.reconcile([Self.palletTests], reporting: Self.everyPalletTestPassed)

        let lines = RunReconciliationRenderer().render(reconciliation).components(separatedBy: "\n")

        #expect(lines.contains("✔ sift test --analyse --against — 3 tests passed, every expected test accounted for"))
        #expect(lines.contains("  expected 3 · ran 3 · passed 3 · failed 0 · skipped 0 · missing 0 · duplicated 0"))
    }

    /// A run with a test missing leads with the worst thing in it, in the words the caller acts on rather than the ones the runner printed.
    @Test
    func theRendererSaysARunWithATestMissingMayNotBeReportedAsPassing() throws {
        let one = "-[GizmoTests.PalletTests testOne]"
        let two = "-[GizmoTests.PalletTests testTwo]"
        let reconciliation = try Self.reconcile([Self.palletTests], reporting: [
            Self.started(one), Self.passed(one),
            Self.started(two), Self.passed(two),
        ])

        let lines = RunReconciliationRenderer().render(reconciliation).components(separatedBy: "\n")

        #expect(lines.contains("✘ sift test --analyse --against — 1 missing — this run may not be reported as passing, whatever its own summary said"))
        #expect(lines.contains("  expected 3 · ran 2 · passed 2 · failed 0 · skipped 0 · missing 1 · duplicated 0"))
    }

    // MARK: - The refusals

    /// The three ways the question cannot be put: a run that reported no test at all, a file that is not there, and a root with no manifest to bound the expected set with.
    @Test
    func theReaderRefusesALogWithNoTestsAPathThatIsNotThereAndARootWithNoManifest() throws {
        let store = try TestSources.makeStore()
        let root = try TemporaryDirectory.make("reconciliation-reader")
        try TestSources.write(Self.manifest, to: "Package.swift", in: root)
        try TestSources.write("Building for debugging...\nCompiling GizmoCore Alpha.swift\n", to: "quiet.log", in: root)
        let reader = RunReconciliationReader(store: store, repositoryRoot: root)

        let bare = try TemporaryDirectory.make("reconciliation-bare")
        try TestSources.write("Test Case '-[GizmoTests.PalletTests testOne]' passed (0.100 seconds).\n", to: "run.log", in: bare)
        let readerWithoutAManifest = RunReconciliationReader(store: store, repositoryRoot: bare)

        #expect(Self.refusal { try reader.reconcile(against: root.appending(path: "quiet.log")) } == .noTestsReported)
        #expect(Self.refusal { try reader.reconcile(against: root.appending(path: "nothing.log")) } == .unreadableLog)
        #expect(Self.refusal { try readerWithoutAManifest.reconcile(against: bare.appending(path: "run.log")) } == .noManifest)
    }
}

private extension RunReconciliationTests {
    /// Which refusal a reader gave, so a test asserts the case rather than the sentence it prints.
    enum Refusal: Equatable {
        case answered
        case unreadableLog
        case noManifest
        case noTestTargets
        case noTestsReported
        case somethingElse
    }

    static func refusal(_ body: () throws -> RunReconciliation) -> Refusal {
        do {
            _ = try body()
            return .answered
        } catch let error as RunReconciliationError {
            switch error {
            case .unreadableLog: return .unreadableLog
            case .noManifest: return .noManifest
            case .noTestTargets: return .noTestTargets
            case .noTestsReported: return .noTestsReported
            }
        } catch {
            return .somethingElse
        }
    }
}

// MARK: - The verdict a run may not be given

/// Covers the four ways a run that lost a test, failed one, or was checked against nothing at all could still have reached a green verdict.
extension RunReconciliationTests {
    /// A test carrying a `@Test("…")` literal at file scope beside one inside a suite that carries one too.
    private static var displayNamedTests: (path: String, source: String) {
        (
            "GizmoTests/AlphaTests.swift",
            """
            import Testing

            @Test("Alpha") func alpha() {}

            struct AlphaTests {
                @Test("Beta") func beta() {}
            }
            """
        )
    }

    /// What the reconciler makes of `lines` over `files`, inside a container that admits `targets` instead of the one the tests above use.
    private static func reconcile(
        _ files: [(path: String, source: String)],
        reporting lines: [String],
        bounding targets: [String]
    ) throws -> RunReconciliation {
        try RunReconciler.reconcile(
            inventory: inventory(files),
            outcomes: outcomes(lines),
            scope: RunReconciliation.Scope(manifest: "Package.swift", targets: targets, conditionalTargets: false, logPath: "run.log")
        )
    }

    private static func endedSwiftTesting(_ name: String, _ word: String) -> [String] {
        ["Test \(name) started.", "Test \(name) \(word) after 0.001 seconds."]
    }

    /// A quoted ending is the test that declares that literal, and never a test whose declaration carries none: the display name is in the inventory, so the join is made on it rather than by counting one ending onto whichever test reported nothing.
    @Test
    func aQuotedEndingIsJoinedToItsOwnTestAndNeverSpentOnOneThatCouldNotHavePrintedIt() throws {
        let one = "-[GizmoTests.PalletTests testOne]"
        let two = "-[GizmoTests.PalletTests testTwo]"

        let reported = Self.endedSwiftTesting("\"Alpha\"", "passed")
            + Self.endedSwiftTesting("\"Beta\"", "passed")
            + [Self.started(one), Self.passed(one), Self.started(two), Self.passed(two)]
            + ["Fatal error: precondition failed"]

        let reconciliation = try Self.reconcile([Self.displayNamedTests, Self.palletTests], reporting: reported)

        #expect(reconciliation.missing.map(\.enumerated) == ["GizmoTests/PalletTests/testThree()"])
        #expect(reconciliation.counts.missing == 1)
        #expect(reconciliation.counts.expected == 5)
        #expect(reconciliation.counts.ran == 4)
        #expect(reconciliation.unclaimed.isEmpty)
        #expect(reconciliation.isGreen == false)
    }

    /// Where one name cannot be told apart between several tests, the endings are spent worst first — nothing in the log says which of them a failure belonged to — and every ending beyond the tests declaring that name is a duplication no retry explains.
    @Test
    func anAmbiguousGroupCountsItsWorstEndingsAndTheSurplusIsDuplicated() throws {
        let reported = Self.endedSwiftTesting("shoutingWorks()", "passed")
            + ["Test shoutingWorks() passed after 0.001 seconds.", "Test shoutingWorks() failed after 0.001 seconds."]

        let reconciliation = try Self.reconcile([Self.twoSuitesOneFunction], reporting: reported)

        #expect(reconciliation.counts.expected == 2)
        #expect(reconciliation.counts.ran == 2)
        #expect(reconciliation.counts.failed == 1)
        #expect(reconciliation.counts.duplicated == 1)
        #expect(reconciliation.isGreen == false)
    }

    /// A retry re-runs what did not pass, so its endings take the place of the worst that stood before them: a group whose failure passed on the second iteration is a group that passed.
    @Test
    func aGroupWhoseFailureWasRetriedIntoAPassIsGreen() throws {
        let reconciliation = try Self.reconcile([Self.twoSuitesOneFunction], reporting: [
            "Test shoutingWorks() started.",
            "Test shoutingWorks() failed after 0.001 seconds.",
            "Test shoutingWorks() passed after 0.001 seconds.",
            "Test shoutingWorks() started (repetition 2).",
            "Test shoutingWorks() passed after 0.001 seconds.",
        ])

        #expect(reconciliation.iterations == 2)
        #expect(reconciliation.counts.expected == 2)
        #expect(reconciliation.counts.ran == 2)
        #expect(reconciliation.counts.passed == 2)
        #expect(reconciliation.counts.failed == 0)
        #expect(reconciliation.counts.duplicated == 0)
        #expect(reconciliation.isGreen)
    }

    /// A run reconciled against an empty expected set was checked against nothing, which is the one thing a verdict may never be mistaken for a pass: the answer says so instead of leading with what it covered.
    @Test
    func aRunReconciledAgainstNothingIsNotGreenAndTheAnswerSaysSo() throws {
        let reconciliation = try Self.reconcile([Self.palletTests], reporting: Self.everyPalletTestPassed, bounding: ["DepotKitTests"])

        let lines = RunReconciliationRenderer().render(reconciliation).components(separatedBy: "\n")

        #expect(reconciliation.counts.expected == 0)
        #expect(reconciliation.isGreen == false)
        #expect(lines.contains { $0.hasPrefix("✘ sift test --analyse --against — nothing expected — ") })
    }
}

// MARK: - The endings a verdict may not be bought with

/// Covers what an ending is allowed to buy: a quoted ending is spent on the declaration carrying its literal or on nothing at all, it counts a second time inside one iteration like any other, and an expected set emptied by exclusions says so rather than blaming the log.
extension RunReconciliationTests {
    /// Two display-named tests in one suite inside the container, which is what a quoted ending has to be joined to by its literal.
    private static var displayNamedSuite: (path: String, source: String) {
        (
            "GizmoTests/BetaTests.swift",
            """
            import Testing

            struct BetaTests {
                @Test("Gamma") func gamma() {}

                @Test("Delta") func delta() {}
            }
            """
        )
    }

    /// A display-named test in a second test target, which the container does not admit and so judges by nothing.
    private static var depotStoreTests: (path: String, source: String) {
        (
            "DepotKitTests/DepotStoreTests.swift",
            """
            import Testing

            struct DepotStoreTests {
                @Test("Zeta") func zeta() {}
            }
            """
        )
    }

    /// A bundle whose every method is switched off by the `XCTFail(…)` opening its body, so the index declares tests here and the expected set is still empty.
    private static var everyMethodExcludedTests: (path: String, source: String) {
        (
            "GizmoTests/ToteStackTests.swift",
            """
            import XCTest

            final class ToteStackTests: XCTestCase {
                func testOne() {
                    XCTFail("switched off")
                }

                func testTwo() {
                    XCTFail("switched off as well")
                }
            }
            """
        )
    }

    /// An ending printed by a target this container does not admit belongs to no test it judges, so it buys nothing: the test that never ran stays missing rather than leaving on the strength of an ending that was never its.
    @Test
    func aQuotedEndingFromATargetOutsideTheContainerBuysNoTestInIt() throws {
        let reported = Self.endedSwiftTesting("\"Delta\"", "passed")
            + Self.endedSwiftTesting("\"Zeta\"", "passed")
            + ["Fatal error: crash before Gamma"]

        let reconciliation = try Self.reconcile([Self.displayNamedSuite, Self.depotStoreTests], reporting: reported)

        #expect(reconciliation.missing.map(\.enumerated) == ["GizmoTests/BetaTests/gamma()"])
        #expect(reconciliation.counts.expected == 2)
        #expect(reconciliation.counts.ran == 1)
        #expect(reconciliation.counts.missing == 1)
        #expect(reconciliation.unclaimed == ["\"Zeta\""])
        #expect(reconciliation.isGreen == false)
    }

    /// The same rule where the ending came from inside the container: a test declared at file scope claims its own ending by its literal, so that ending is never a spare one to spend on a test that reported nothing.
    @Test
    func aQuotedEndingFromAFileScopeTestBuysNoTestInsideASuite() throws {
        let reported = Self.endedSwiftTesting("\"Alpha\"", "passed") + ["Fatal error: crash before Beta"]

        let reconciliation = try Self.reconcile([Self.displayNamedTests], reporting: reported)

        #expect(reconciliation.missing.map(\.enumerated) == ["GizmoTests/AlphaTests/beta()"])
        #expect(reconciliation.counts.expected == 2)
        #expect(reconciliation.counts.ran == 1)
        #expect(reconciliation.counts.missing == 1)
        #expect(reconciliation.unclaimed.isEmpty)
        #expect(reconciliation.isGreen == false)
    }

    /// One rule for a test whatever the log named it by: a second ending inside one iteration is a duplication that no retry explains, and carrying a display name does not exempt it.
    @Test
    func aDisplayNamedTestThatEndedTwiceInOneIterationIsDuplicated() throws {
        let reported = Self.endedSwiftTesting("\"Gamma\"", "passed")
            + ["Test \"Gamma\" passed after 0.001 seconds."]
            + Self.endedSwiftTesting("\"Delta\"", "passed")

        let reconciliation = try Self.reconcile([Self.displayNamedSuite], reporting: reported)

        #expect(reconciliation.duplicated.map(\.test.enumerated) == ["GizmoTests/BetaTests/gamma()"])
        #expect(reconciliation.counts.duplicated == 1)
        #expect(reconciliation.counts.expected == 2)
        #expect(reconciliation.counts.ran == 2)
        #expect(reconciliation.isGreen == false)
    }

    /// An expected set emptied by what was lifted out of it is not a log from somewhere else, and the headline sends the reader to the exclusions that emptied it rather than to where the log came from.
    @Test
    func aPackageWhoseEveryTestIsExcludedIsToldFromALogOfSomethingElse() throws {
        let reconciliation = try Self.reconcile([Self.everyMethodExcludedTests], reporting: [])

        let rendered = RunReconciliationRenderer().render(reconciliation).components(separatedBy: "\n")
        let headline = try #require(rendered.first { $0.hasPrefix("✘ sift test --analyse --against — nothing expected — ") })

        #expect(reconciliation.counts.expected == 0)
        #expect(reconciliation.isGreen == false)
        #expect(headline.contains("2 excluded by XCTFail"))
        #expect(headline.contains("the index declares no test") == false)
        #expect(headline.contains("Check the log came from this repository") == false)
    }

    /// A later iteration that ended fewer tests than the one before it is stated: the counts stand on each test's last attempt, and nothing in the log says whether a repeat stopped part-way or a retry re-ran only what failed.
    @Test
    func anIterationThatEndedFewerTestsThanTheOneBeforeItIsStatedRatherThanResolved() throws {
        let reconciliation = try Self.reconcile([Self.twoSuitesOneFunction], reporting: [
            "Test shoutingWorks() started.",
            "Test shoutingWorks() failed after 0.001 seconds.",
            "Test shoutingWorks() passed after 0.001 seconds.",
            "Test shoutingWorks() started (repetition 2).",
            "Test shoutingWorks() passed after 0.001 seconds.",
        ])

        #expect(reconciliation.notes.contains { $0.hasPrefix("Iteration 2 ended 1 test where iteration 1 ended 2:") })
    }
}

// MARK: - A literal more than one test declares

/// Covers a `@Test("…")` literal two declarations share: the log prints both tests under it and nothing else, so the group is reconciled by count — as many endings as tests is every one of them run, and fewer is a shortfall with no name to give.
extension RunReconciliationTests {
    /// Two suites in one target whose tests declare the same literal.
    private static var sharedLiteralSuites: (path: String, source: String) {
        (
            "GizmoTests/AlphaTests.swift",
            """
            import Testing

            struct AlphaTests {
                @Test("Alpha") func first() {}
            }

            struct BetaTests {
                @Test("Alpha") func second() {}
            }
            """
        )
    }

    /// A test in a second target declaring the literal the suites above declare, which the log prints no target beside.
    private static var sharedLiteralElsewhere: (path: String, source: String) {
        (
            "DepotKitTests/BetaTests.swift",
            """
            import Testing

            struct BetaTests {
                @Test("Alpha") func third() {}
            }
            """
        )
    }

    /// Both tests ran and both passed, so the run adds up: claiming one of them on the literal would call the other missing although its ending is right there in the log.
    @Test
    func twoTestsSharingALiteralThatBothEndedAreGreenWithNothingMissing() throws {
        let reported = Self.endedSwiftTesting("\"Alpha\"", "passed") + Self.endedSwiftTesting("\"Alpha\"", "passed")

        let reconciliation = try Self.reconcile([Self.sharedLiteralSuites], reporting: reported)

        #expect(reconciliation.missing.isEmpty)
        #expect(reconciliation.shortfalls.isEmpty)
        #expect(reconciliation.unclaimed.isEmpty)
        #expect(reconciliation.counts == ReconciliationCounts(expected: 2, ran: 2, passed: 2, failed: 0, skipped: 0, missing: 0, duplicated: 0))
        #expect(reconciliation.notes.contains { $0.hasPrefix("Reconciled by count only: \"Alpha\".") })
        #expect(reconciliation.isGreen)
    }

    /// One ending for a group of two is one test that never reported, and nothing in the log says which: the answer gives the shortfall rather than a name, and stays red.
    @Test
    func twoTestsSharingALiteralWithOneEndingAreAShortfallWithNoNameAndNotGreen() throws {
        let reported = Self.endedSwiftTesting("\"Alpha\"", "passed") + ["Fatal error: crash before the second"]

        let reconciliation = try Self.reconcile([Self.sharedLiteralSuites], reporting: reported)
        let rendered = RunReconciliationRenderer().render(reconciliation).components(separatedBy: "\n")

        #expect(reconciliation.missing.isEmpty)
        #expect(reconciliation.shortfalls == [ReconciliationShortfall(function: "\"Alpha\"", missing: 1, expected: 2)])
        #expect(reconciliation.counts == ReconciliationCounts(expected: 2, ran: 1, passed: 1, failed: 0, skipped: 0, missing: 1, duplicated: 0))
        #expect(rendered.contains("  \"Alpha\": 1 of these 2 never reported"))
        #expect(reconciliation.isGreen == false)
    }

    /// The log prints a Swift Testing test with no target beside it, so the same literal in two admitted targets is one group, answered by count like any other.
    @Test
    func aLiteralSharedAcrossTwoTargetsIsOneGroupTheLogCannotSplit() throws {
        let files = [Self.sharedLiteralSuites, Self.sharedLiteralElsewhere]
        let every = Self.endedSwiftTesting("\"Alpha\"", "passed") + Self.endedSwiftTesting("\"Alpha\"", "passed")
            + Self.endedSwiftTesting("\"Alpha\"", "passed")

        let ranAll = try Self.reconcile(files, reporting: every, bounding: ["GizmoTests", "DepotKitTests"])
        let lostOne = try Self.reconcile(files, reporting: Array(every.dropLast(2)), bounding: ["GizmoTests", "DepotKitTests"])

        #expect(ranAll.counts.missing == 0)
        #expect(ranAll.isGreen)
        #expect(lostOne.shortfalls == [ReconciliationShortfall(function: "\"Alpha\"", missing: 1, expected: 3)])
        #expect(lostOne.isGreen == false)
    }
}

// MARK: - A literal a conditional test declares

/// Covers a conditional test carrying a `@Test("…")` literal: its ending prints under the literal like any other, so it joins the literal's group, and a group whose endings a conditional test could have supplied is never read green on the assumption that it was the one skipped.
extension RunReconciliationTests {
    /// Two unconditional tests and one conditional one, all declaring the same literal.
    private static var sharedLiteralWithAConditional: (path: String, source: String) {
        (
            "GizmoTests/AlphaTests.swift",
            """
            import Testing

            struct AlphaTests {
                @Test("Alpha") func first() {}
            }

            struct BetaTests {
                @Test("Alpha") func second() {}
                @Test("Alpha", .enabled(if: true)) func third() {}
            }
            """
        )
    }

    /// Two endings over three tests is either the conditional one switched off or an unconditional one lost, and the log cannot say which: the answer says so and stays red, where leaving the conditional test out of the group read `expected 2 · ran 2` and green.
    @Test
    func twoEndingsOverTwoTestsAndAConditionalOneSharingALiteralAreNotGreen() throws {
        let reported = Self.endedSwiftTesting("\"Alpha\"", "passed") + Self.endedSwiftTesting("\"Alpha\"", "passed")

        let reconciliation = try Self.reconcile([Self.sharedLiteralWithAConditional], reporting: reported)
        let rendered = RunReconciliationRenderer().render(reconciliation).components(separatedBy: "\n")

        #expect(reconciliation.shortfalls == [ReconciliationShortfall(function: "\"Alpha\"", missing: 1, expected: 3, conditional: 1)])
        #expect(reconciliation.counts == ReconciliationCounts(expected: 3, ran: 2, passed: 2, failed: 0, skipped: 0, missing: 1, duplicated: 0))
        #expect(rendered.contains("  \"Alpha\": 1 of these 3 never reported, and 1 of the 3 is conditional, so the log cannot say whether a conditional test was skipped or a test was lost"))
        #expect(reconciliation.isGreen == false)
    }

    /// Three endings over three tests is every one of them run, the conditional one included: nothing duplicated, nothing missing, and nothing left undecided.
    @Test
    func threeEndingsOverTwoTestsAndAConditionalOneSharingALiteralAreGreen() throws {
        let reported = Self.endedSwiftTesting("\"Alpha\"", "passed") + Self.endedSwiftTesting("\"Alpha\"", "passed")
            + Self.endedSwiftTesting("\"Alpha\"", "passed")

        let reconciliation = try Self.reconcile([Self.sharedLiteralWithAConditional], reporting: reported)

        #expect(reconciliation.counts == ReconciliationCounts(expected: 3, ran: 3, passed: 3, failed: 0, skipped: 0, missing: 0, duplicated: 0))
        #expect(reconciliation.shortfalls.isEmpty)
        #expect(reconciliation.undecided.isEmpty)
        #expect(reconciliation.unclaimed.isEmpty)
        #expect(reconciliation.isGreen)
    }

    /// Fewer endings than the unconditional tests alone is a loss whatever the conditional test did, and the sentence gives the least the log proves was lost.
    @Test
    func fewerEndingsThanTheUnconditionalTestsSharingALiteralAreAShortfallThatSaysHowManyWereLost() throws {
        let reported = Self.endedSwiftTesting("\"Alpha\"", "passed") + ["Fatal error: crash before the rest"]

        let reconciliation = try Self.reconcile([Self.sharedLiteralWithAConditional], reporting: reported)
        let rendered = RunReconciliationRenderer().render(reconciliation).components(separatedBy: "\n")

        #expect(reconciliation.shortfalls == [ReconciliationShortfall(function: "\"Alpha\"", missing: 2, expected: 3, conditional: 1)])
        #expect(rendered.contains("  \"Alpha\": 2 of these 3 never reported, and 1 of the 3 is conditional, so at least 1 was lost"))
        #expect(reconciliation.isGreen == false)
    }

    /// A lone conditional test with a literal is claimed by its quoted ending, as an unconditional one is, rather than left undecided beside an ending read as unclaimed.
    @Test
    func aConditionalTestIsClaimedByTheEndingItsLiteralPrints() throws {
        let file = (
            path: "GizmoTests/AlphaTests.swift",
            source: """
            import Testing

            struct AlphaTests {
                @Test("Alpha", .enabled(if: true)) func first() {}
            }
            """
        )

        let reconciliation = try Self.reconcile([file], reporting: Self.endedSwiftTesting("\"Alpha\"", "passed"))

        #expect(reconciliation.counts == ReconciliationCounts(expected: 1, ran: 1, passed: 1, failed: 0, skipped: 0, missing: 0, duplicated: 0))
        #expect(reconciliation.undecided.isEmpty)
        #expect(reconciliation.unclaimed.isEmpty)
        #expect(reconciliation.isGreen)
    }

    /// A function name a conditional test shares with an unconditional one is the same group by another name: one ending cannot say which of the two it was, so it is not green.
    @Test
    func oneEndingOverAFunctionNameAConditionalTestSharesIsNotGreen() throws {
        let file = (
            path: "GizmoTests/HopperGaugeTests.swift",
            source: """
            import Testing

            struct HopperGaugeTests {
                @Test func shoutingWorks() {}
            }

            struct PalletTests {
                @Test(.enabled(if: true)) func shoutingWorks() {}
            }
            """
        )

        let reconciliation = try Self.reconcile([file], reporting: Self.endedSwiftTesting("shoutingWorks()", "passed"))

        #expect(reconciliation.shortfalls == [ReconciliationShortfall(function: "shoutingWorks", missing: 1, expected: 2, conditional: 1)])
        #expect(reconciliation.isGreen == false)
    }

    /// A group every member of which is conditional cannot have lost a test, so the run decides it as it decides a lone conditional test: what ended is counted, and what did not is counted in neither direction.
    @Test
    func aLiteralOnlyConditionalTestsShareIsCountedByWhatEnded() throws {
        let file = (
            path: "GizmoTests/AlphaTests.swift",
            source: """
            import Testing

            struct AlphaTests {
                @Test("Alpha", .enabled(if: true)) func first() {}
            }

            struct BetaTests {
                @Test("Alpha", .enabled(if: true)) func second() {}
            }
            """
        )

        let reconciliation = try Self.reconcile([file], reporting: Self.endedSwiftTesting("\"Alpha\"", "passed"))

        #expect(reconciliation.counts == ReconciliationCounts(expected: 1, ran: 1, passed: 1, failed: 0, skipped: 0, missing: 0, duplicated: 0))
        #expect(reconciliation.shortfalls.isEmpty)
        #expect(reconciliation.notes.contains { $0.hasPrefix("\"Alpha\": 1 of the 2 conditional tests this name cannot tell apart reported nothing") })
        #expect(reconciliation.isGreen)
    }
}
