//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// A start line in the log proves the clause around a test compiled, whatever the `#if` reading said: a test under a condition the host cannot decide, or one the host judged compiled out, that started and never ended is never reported, and the run is not green.
@Suite(.temporaryDirectories)
struct StartedUnderIfConfigTests {
    private static var source: String {
        """
        import Testing
        import XCTest

        final class PalletTests: XCTestCase {
            func testOne() {}
        }

        @Test func shoutingWorks() {}

        #if DEBUG
        @Test func traps() { fatalError("trapped") }
        @Test("A labelled gizmo") func labelled() {}
        #endif
        """
    }

    /// The same flag around a suite declaring a second `traps()`, so the log's one name cannot tell the two apart.
    private static var sharedNameSource: String {
        source + """

        #if DEBUG
        struct AlphaTests {
            @Test func traps() {}
        }
        #endif
        """
    }

    /// Tests under an `#if` this host proves it does not compile, the shape a log from another platform or architecture runs anyway.
    private static var compiledOutSource: String {
        """
        import Testing
        import XCTest

        final class PalletTests: XCTestCase {
            func testOne() {}
            #if os(Linux)
            func testTwo() {}
            #endif
        }

        #if os(Linux)
        @Test func countIsOne() {}
        #endif
        """
    }

    private static func reconcile(_ source: String = source, reporting lines: [String]) throws -> RunReconciliation {
        let root = try TemporaryDirectory.make("started-under-if")
        let store = try TestSources.makeStore()
        let parsed = try TestSources.parsed(source, path: "Tests/GizmoTests/GizmoTests.swift", in: root)
        try store.replaceFiles([parsed]) { _ in ("GizmoTests", false) }
        var outcomes = RunTestOutcomes()
        for line in lines {
            outcomes.read(line)
        }
        return try RunReconciler.reconcile(
            inventory: TestInventory.read(store: store, repositoryRoot: root),
            outcomes: outcomes,
            scope: RunReconciliation.Scope(manifest: "Package.swift", targets: ["GizmoTests"], conditionalTargets: false, logPath: "run.log")
        )
    }

    /// The tests outside any `#if` ending as a run prints them.
    private static var compiledLines: [String] {
        [
            "Test Case '-[GizmoTests.PalletTests testOne]' started.",
            "Test Case '-[GizmoTests.PalletTests testOne]' passed (0.001 seconds).",
            "◇ Test shoutingWorks() started.",
            "✔ Test shoutingWorks() passed after 0.001 seconds.",
        ]
    }

    private static var trapped: String {
        "Tests/GizmoTests/GizmoTests.swift:10: Fatal error: trapped"
    }

    /// The `--against` answer's verdict line, whose mark is its exit code: `✘` exits 1.
    private static func headline(_ reconciliation: RunReconciliation) -> String? {
        RunReconciliationRenderer().render(reconciliation).split(separator: "\n").map(String.init).first { $0.contains("sift test --analyse --against — ") }
    }

    /// A test under `#if DEBUG` that started and crashed the process is never reported, on the run's line and under `--against`, never a conditional test that reported nothing.
    @Test
    func anUndecidedTestThatStartedAndNeverEndedIsNeverReported() throws {
        let reconciliation = try Self.reconcile(reporting: Self.compiledLines + ["◇ Test traps() started.", Self.trapped])

        #expect(reconciliation.missing.map(\.enumerated) == ["GizmoTests/(file scope)/traps()"])
        #expect(reconciliation.undecided.map(\.enumerated) == ["GizmoTests/(file scope)/labelled()"])
        #expect(reconciliation.counts.expected == 3)
        #expect(reconciliation.counts.ran == 2)
        #expect(reconciliation.isGreen == false)
        #expect(Self.headline(reconciliation)?.hasPrefix("✘ sift test --analyse --against — 1 missing") == true)
        let line = try #require(RunInventoryCheck.reconciled(reconciliation).lines.first)
        #expect(line.hasPrefix("inventory: 3 declared, 2 reported"))
        #expect(line.hasSuffix("— 1 never reported: GizmoTests/(file scope)/traps()"))
    }

    /// One that logs under its literal is read by it: started under the literal and never ended is never reported too.
    @Test
    func anUndecidedTestStartedUnderItsLiteralIsNeverReported() throws {
        let reconciliation = try Self.reconcile(reporting: Self.compiledLines + ["◇ Test \"A labelled gizmo\" started.", Self.trapped])

        #expect(reconciliation.missing.map(\.enumerated) == ["GizmoTests/(file scope)/labelled()"])
        #expect(reconciliation.isGreen == false)
    }

    /// Two undecided tests one name cannot tell apart, one of which started and never ended: the start proves the flag compiled, so the group is owed its endings and falls short.
    @Test
    func anUndecidedGroupWithAStartNoEndingFollowedFallsShort() throws {
        let reconciliation = try Self.reconcile(Self.sharedNameSource, reporting: Self.compiledLines + ["◇ Test traps() started.", Self.trapped])

        #expect(reconciliation.shortfalls.map(\.function) == ["traps"])
        #expect(reconciliation.counts.missing == 2)
        #expect(reconciliation.isGreen == false)
        #expect(Self.headline(reconciliation)?.hasPrefix("✘ sift test --analyse --against — 2 missing") == true)
    }

    /// An undecided test that printed no line at all is still the build's to have left out: named as a conditional test that reported nothing, and the run stays green.
    @Test
    func anUndecidedTestWithNoLineStaysUndecided() throws {
        let reconciliation = try Self.reconcile(reporting: Self.compiledLines)

        #expect(reconciliation.undecided.map(\.enumerated) == ["GizmoTests/(file scope)/labelled()", "GizmoTests/(file scope)/traps()"])
        #expect(reconciliation.missing.isEmpty)
        #expect(reconciliation.isGreen)
    }

    /// The run's line names the conditional tests that reported nothing, as it names the ones never reported, so a reader can see which were left out.
    @Test
    func theRunLineNamesTheConditionalTestsThatReportedNothing() throws {
        let reconciliation = try Self.reconcile(reporting: Self.compiledLines)

        #expect(RunInventoryCheck.reconciled(reconciliation).lines == [
            "inventory: 2 declared, 2 reported (2 conditional tests reported nothing, counted in neither direction: GizmoTests/(file scope)/labelled(), GizmoTests/(file scope)/traps())",
        ])
    }

    /// A test the host judged compiled out that started and crashed the process is never reported, not named apart as not run here.
    @Test
    func aCompiledOutTestThatStartedAndNeverEndedIsNeverReported() throws {
        let lines = Array(Self.compiledLines.prefix(2)) + ["◇ Test countIsOne() started.", Self.trapped]

        let reconciliation = try Self.reconcile(Self.compiledOutSource, reporting: lines)

        #expect(reconciliation.missing.map(\.enumerated) == ["GizmoTests/(file scope)/countIsOne()"])
        #expect(reconciliation.compiledOut.map(\.enumerated) == ["GizmoTests/PalletTests/testTwo()"])
        #expect(reconciliation.isGreen == false)
        #expect(Self.headline(reconciliation)?.hasPrefix("✘ sift test --analyse --against — 1 missing") == true)
        let line = try #require(RunInventoryCheck.reconciled(reconciliation).lines.first)
        #expect(line.hasPrefix("inventory: 2 declared, 1 reported (1 more sits under an #if this platform does not compile, not run here: GizmoTests/PalletTests/testTwo())"))
        #expect(line.hasSuffix("— 1 never reported: GizmoTests/(file scope)/countIsOne()"))
    }

    /// The same for an XCTest method: its start line proves the clause compiled, so a crash in it is never reported.
    @Test
    func aCompiledOutXCTestMethodThatStartedAndNeverEndedIsNeverReported() throws {
        let lines = Array(Self.compiledLines.prefix(2)) + ["Test Case '-[GizmoTests.PalletTests testTwo]' started.", Self.trapped]

        let reconciliation = try Self.reconcile(Self.compiledOutSource, reporting: lines)

        #expect(reconciliation.missing.map(\.enumerated) == ["GizmoTests/PalletTests/testTwo()"])
        #expect(reconciliation.compiledOut.map(\.enumerated) == ["GizmoTests/(file scope)/countIsOne()"])
        #expect(reconciliation.isGreen == false)
    }

    /// Compiled-out tests that ended are counted like any other, and named apart no more.
    @Test
    func compiledOutTestsThatEndedAreCounted() throws {
        let lines = Array(Self.compiledLines.prefix(2)) + [
            "Test Case '-[GizmoTests.PalletTests testTwo]' started.",
            "Test Case '-[GizmoTests.PalletTests testTwo]' passed (0.001 seconds).",
            "◇ Test countIsOne() started.",
            "✔ Test countIsOne() passed after 0.001 seconds.",
        ]

        let reconciliation = try Self.reconcile(Self.compiledOutSource, reporting: lines)

        #expect(reconciliation.compiledOut.isEmpty)
        #expect(reconciliation.counts.expected == 3)
        #expect(reconciliation.counts.ran == 3)
        #expect(reconciliation.isGreen)
    }
}
