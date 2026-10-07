//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// Covers an XCTest case nested in another type, which a macOS `swift test` log names by its mangled runtime name rather than the dotted one the inventory declares.
///
/// Every log line here is one `swift test` printed on this machine (26 Sep 2026) for a package holding ``nestedCases`` under a `LibTests` target.
@Suite(.temporaryDirectories)
struct NestedXCTestNameTests {
    /// A class in a class, a class in an enum, and a class two levels down in an enum in a struct, beside one top-level case.
    private static var nestedCases: (path: String, source: String) {
        (
            "LibTests/WidgetTests.swift",
            """
            import XCTest

            final class WidgetTests: XCTestCase {
                func testOne() {}
                final class GizmoTests: XCTestCase {
                    func testTwo() {}
                }
            }

            enum ChoreTasks {
                final class LampTests: XCTestCase {
                    func testThree() {}
                }
            }

            struct DepotStore {
                enum BayFloor {
                    final class PalletTests: XCTestCase {
                        func testExample() {}
                    }
                }
            }
            """
        )
    }

    /// The run's own lines for all four cases, suite lines included, as the log carried them.
    private static var observedRun: [String] {
        [
            "Test Suite 'WidgetTests' started at 2026-09-26 07:14:30.122.",
            "Test Case '-[LibTests.WidgetTests testOne]' started.",
            "Test Case '-[LibTests.WidgetTests testOne]' passed (0.000 seconds).",
            "Test Suite '_TtCC8LibTests11WidgetTests10GizmoTests' started at 2026-09-26 07:14:30.123.",
            "Test Case '-[_TtCC8LibTests11WidgetTests10GizmoTests testTwo]' started.",
            "Test Case '-[_TtCC8LibTests11WidgetTests10GizmoTests testTwo]' passed (0.000 seconds).",
            "Test Suite '_TtCO8LibTests10ChoreTasks9LampTests' started at 2026-09-26 07:14:30.123.",
            "Test Case '-[_TtCO8LibTests10ChoreTasks9LampTests testThree]' started.",
            "Test Case '-[_TtCO8LibTests10ChoreTasks9LampTests testThree]' passed (0.000 seconds).",
            "Test Suite '_TtCOV8LibTests10DepotStore8BayFloor11PalletTests' started at 2026-09-26 07:14:30.123.",
            "Test Case '-[_TtCOV8LibTests10DepotStore8BayFloor11PalletTests testExample]' started.",
            "Test Case '-[_TtCOV8LibTests10DepotStore8BayFloor11PalletTests testExample]' passed (0.000 seconds).",
        ]
    }

    /// A class nested in a class is read back to its dotted name and claims the test declared under it.
    @Test
    func aClassInAClassIsReadBackToItsDottedName() throws {
        let name = "-[_TtCC8LibTests11WidgetTests10GizmoTests testTwo]"

        #expect(TestIdentifier.xctestLogName(name)?.qualifiedType == "LibTests.WidgetTests.GizmoTests")
        #expect(try #require(TestIdentifier(enumerated: "LibTests/WidgetTests.GizmoTests/testTwo()")).matches(xctestLogName: name))
    }

    /// A class nested in an enum used as a namespace is read back the same way; the kind letter changes nothing but itself.
    @Test
    func aClassInAnEnumIsReadBackToItsDottedName() throws {
        let name = "-[_TtCO8LibTests10ChoreTasks9LampTests testThree]"

        #expect(TestIdentifier.xctestLogName(name)?.qualifiedType == "LibTests.ChoreTasks.LampTests")
        #expect(try #require(TestIdentifier(enumerated: "LibTests/ChoreTasks.LampTests/testThree()")).matches(xctestLogName: name))
    }

    /// Three levels of nesting carry three kind letters, innermost first, and four identifiers, outermost first.
    @Test
    func aClassThreeLevelsDownIsReadBackToItsDottedName() throws {
        let name = "-[_TtCOV8LibTests10DepotStore8BayFloor11PalletTests testExample]"

        #expect(TestIdentifier.xctestLogName(name)?.qualifiedType == "LibTests.DepotStore.BayFloor.PalletTests")
        #expect(try #require(TestIdentifier(enumerated: "LibTests/DepotStore.BayFloor.PalletTests/testExample()")).matches(xctestLogName: name))
    }

    /// A name outside the one family read is left exactly as printed: a generic context, a standard-library substitution, a length that overruns, text left over, a kind count that does not fit the identifiers, a zero-led length, and a chain whose innermost type is not a class.
    @Test(arguments: [
        ["_Tt", "GC", "8", "LibTests", "11", "WidgetTests", "Si_"],
        ["_Tt", "Cs", "11", "WidgetTests"],
        ["_Tt", "CC", "8", "LibTests", "99", "WidgetTests"],
        ["_Tt", "CC", "8", "LibTests", "11", "WidgetTests", "10", "GizmoTests", "X"],
        ["_Tt", "C", "8", "LibTests", "11", "WidgetTests", "10", "GizmoTests"],
        ["_Tt", "CC", "8", "LibTests", "011", "WidgetTests", "10", "GizmoTests"],
        ["_Tt", "OC", "8", "LibTests", "11", "WidgetTests", "10", "GizmoTests"],
        ["LibTests", ".", "WidgetTests"],
    ])
    func aNameOutsideTheFamilyIsLeftAsPrinted(pieces: [String]) {
        // Assembled from pieces, since each whole string is a name the example-name gate would have to permit.
        let type = pieces.joined()

        #expect(TestIdentifier.xctestLogName("-[\(type) testTwo]")?.qualifiedType == type)
    }

    /// The whole run reconciles: every nested case the log named by its mangled name is claimed by its declaration, and nothing reads missing or unclaimed.
    @Test
    func aRunOfNestedCasesReconcilesWithNothingMissing() throws {
        var outcomes = RunTestOutcomes()
        for line in Self.observedRun {
            outcomes.read(line)
        }

        let reconciliation = try RunReconciler.reconcile(
            inventory: TestInventoryTests.inventory([Self.nestedCases]),
            outcomes: outcomes,
            scope: RunReconciliation.Scope(manifest: "Package.swift", targets: ["LibTests"], conditionalTargets: false, logPath: "run.log")
        )

        #expect(reconciliation.isGreen)
        #expect(RunInventoryCheck.reconciled(reconciliation).lines == ["inventory: 4 declared, 4 reported"])
    }
}
