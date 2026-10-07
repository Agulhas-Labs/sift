//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// A test inside an `#if` the host provably does not compile is never run here, so the inventory names it apart rather than as never reported; one inside a condition the host cannot decide is owed only what it reports; one in an active clause is owed like any other.
@Suite(.temporaryDirectories)
struct IfConfigInventoryTests {
    private static var source: String {
        """
        import Testing
        import XCTest

        final class PalletTests: XCTestCase {
            func testOne() {}
            #if os(Linux)
            func testTwo() {}
            #else
            func testThree() {}
            #endif
        }

        #if os(Linux)
        @Test func countIsOne() {}
        #endif

        #if DEBUG
        @Test func traps() {}
        #endif
        """
    }

    private static func reconcile(reporting lines: [String]) throws -> RunReconciliation {
        let root = try TemporaryDirectory.make("if-config")
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

    private static func xctest(_ method: String) -> [String] {
        ["Test Case '-[GizmoTests.PalletTests \(method)]' started.", "Test Case '-[GizmoTests.PalletTests \(method)]' passed (0.001 seconds)."]
    }

    private static func states(_ source: String) -> [HostCompilation.State] {
        HostCompilation.regions(in: source).map(\.state)
    }

    /// The host decides a platform condition and its `#else`, and leaves a custom flag undecided rather than false, whichever side of `&&` or `||` it sits.
    @Test
    func theHostDecidesPlatformConditionsAndLeavesFlagsUndecided() {
        #expect(Self.states("#if os(Linux)\nlet a = 1\n#elseif os(macOS)\nlet b = 1\n#else\nlet c = 1\n#endif") == [.inactive, .active, .inactive])
        #expect(Self.states("#if DEBUG\nlet a = 1\n#else\nlet b = 1\n#endif") == [.undecided, .undecided])
        #expect(Self.states("#if os(Linux) && DEBUG\nlet a = 1\n#endif") == [.inactive])
        #expect(Self.states("#if canImport(UIKit) || DEBUG\nlet a = 1\n#endif") == [.undecided])
        #expect(Self.states("#if !os(Linux) && canImport(XCTest)\nlet a = 1\n#endif") == [.active])
        #expect(Self.states("#if swift(>=5.9)\nlet a = 1\n#endif") == [.undecided])
    }

    /// A green run on macOS: the `#if os(Linux)` tests are named as not compiled here, never as never reported, and the line still reads every compiled test reported.
    @Test
    func aTestUnderAnInactiveIfIsNamedApartAndNotNeverReported() throws {
        let reconciliation = try Self.reconcile(reporting: Self.xctest("testOne") + Self.xctest("testThree") + ["◇ Test traps() started.", "✔ Test traps() passed after 0.001 seconds."])

        #expect(reconciliation.compiledOut.map(\.enumerated) == ["GizmoTests/(file scope)/countIsOne()", "GizmoTests/PalletTests/testTwo()"])
        #expect(reconciliation.missing.isEmpty)
        #expect(reconciliation.counts.expected == 3)
        #expect(reconciliation.counts.ran == 3)
        #expect(reconciliation.isGreen)
        let line = try #require(RunInventoryCheck.reconciled(reconciliation).lines.first)
        #expect(line == "inventory: 3 declared, 3 reported (2 more sit under an #if this platform does not compile, not run here: GizmoTests/(file scope)/countIsOne(), GizmoTests/PalletTests/testTwo())")
    }

    /// A test in the active `#else` of that same `#if` that never reported is still never reported: the platform compiles it, so nothing excuses it.
    @Test
    func aTestInAnActiveElseThatNeverReportedIsStillMissing() throws {
        let reconciliation = try Self.reconcile(reporting: Self.xctest("testOne") + ["◇ Test traps() started.", "✔ Test traps() passed after 0.001 seconds."])

        #expect(reconciliation.missing.map(\.enumerated) == ["GizmoTests/PalletTests/testThree()"])
        #expect(reconciliation.isGreen == false)
        #expect(RunInventoryCheck.reconciled(reconciliation).lines.first?.contains("1 never reported: GizmoTests/PalletTests/testThree()") == true)
    }

    /// A test under a flag the host cannot decide that reported nothing is undecided and named, never counted as reported.
    @Test
    func aTestUnderAnUndecidedFlagThatReportedNothingIsNamedUndecided() throws {
        let reconciliation = try Self.reconcile(reporting: Self.xctest("testOne") + Self.xctest("testThree"))

        #expect(reconciliation.undecided.map(\.enumerated) == ["GizmoTests/(file scope)/traps()"])
        #expect(reconciliation.counts.expected == 2)
        #expect(reconciliation.counts.ran == 2)
        #expect(RunInventoryCheck.reconciled(reconciliation).lines.first?.contains("1 conditional test reported nothing") == true)
    }
}
