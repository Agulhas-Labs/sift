//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// Covers the tests a negative gate names as guards: expected to pass both ways, listed as held, and kept out of the count of tests that pin.
struct RunWithoutGuardTests {
    /// Two tests that pin and a named guard that passes both ways read as a proof, with the guard counted apart.
    @Test
    func aGuardThatHoldsLeavesTheProofStanding() {
        let answer = Self.judged(
            without: ["shoutingWorks()": false, "sizeIsCarried()": false, "theGridReflows()": true],
            with: ["shoutingWorks()": true, "sizeIsCarried()": true, "theGridReflows()": true],
            guards: ["theGridReflows()"]
        )

        #expect(Self.lines(answer.render()).first == "✔ 2 of 2 fail without Sources/ and pass with it; 1 named guard passes both ways")
        #expect(Self.lines(answer.render()).contains("  ✔ theGridReflows() — a named guard: passes without the change and with it"))
        #expect(answer.proven)
    }

    /// A guard that fails without the change pins it, which a guard must not: it is a failure of the gate.
    @Test
    func aGuardThatFailsWithoutTheChangeIsAFailure() {
        let answer = Self.judged(
            without: ["shoutingWorks()": false, "sizeIsCarried()": false, "theGridReflows()": false],
            with: ["shoutingWorks()": true, "sizeIsCarried()": true, "theGridReflows()": true],
            guards: ["theGridReflows()"]
        )
        let lines = Self.lines(answer.render())

        #expect(lines.first == "✘ 2 of 2 fail without Sources/ and pass with it; 0 of 1 named guards pass both ways")
        #expect(lines.contains("  ✘ theGridReflows() — named as a guard, but failed without the change and passed with it"))
        #expect(!answer.proven)
    }

    /// A guard that fails with the change shows the failure beside its line.
    @Test
    func aGuardThatFailsWithTheChangeIsAFailure() {
        let answer = Self.judged(
            without: ["shoutingWorks()": false, "sizeIsCarried()": false, "theGridReflows()": true],
            with: ["shoutingWorks()": true, "sizeIsCarried()": true, "theGridReflows()": false],
            guards: ["theGridReflows()"]
        )
        let lines = Self.lines(answer.render())

        #expect(lines.first == "✘ 2 of 2 fail without Sources/ and pass with it; 0 of 1 named guards pass both ways")
        #expect(lines.contains { $0.hasPrefix("  ✘ theGridReflows() — named as a guard, but passed without the change and failed with it — with it: WidgetTests.swift:7:9") })
        #expect(!answer.proven)
    }

    /// A guard that names no test either run printed draws its own line and an unproven answer.
    @Test
    func aGuardThatNamesNoTestIsNotProven() {
        let answer = Self.judged(
            without: ["shoutingWorks()": false, "sizeIsCarried()": false],
            with: ["shoutingWorks()": true, "sizeIsCarried()": true],
            guards: ["ghost()"]
        )
        let lines = Self.lines(answer.render())

        #expect(lines.first == "⚠ 2 of 2 fail without Sources/ and pass with it; 0 of 1 named guards pass both ways")
        #expect(lines.contains("  ⚠ ghost() — named by --guard, but no test of that name ran"))
        #expect(!answer.proven)
    }

    /// A guard is an exact name, so a prefix of a test's name matches nothing.
    @Test
    func aGuardIsNotAPattern() {
        let answer = Self.judged(
            without: ["shoutingWorks()": false, "theGridReflows()": true],
            with: ["shoutingWorks()": true, "theGridReflows()": true],
            guards: ["reflows"]
        )

        #expect(Self.lines(answer.render()).contains("  ⚠ reflows — named by --guard, but no test of that name ran"))
        #expect(!answer.proven)
    }

    /// A guard written as a bare name matches the test the run printed with its suite.
    @Test
    func aGuardMatchesATestByItsBareIdentifier() {
        let answer = Self.judged(
            without: ["WidgetTests.shoutingWorks()": false, "WidgetTests.theGridReflows()": true],
            with: ["WidgetTests.shoutingWorks()": true, "WidgetTests.theGridReflows()": true],
            guards: ["theGridReflows"]
        )

        #expect(Self.lines(answer.render()).contains("  ✔ WidgetTests.theGridReflows() — a named guard: passes without the change and with it"))
        #expect(Self.lines(answer.render()).first == "✔ 1 of 1 fails without Sources/ and passes with it; 1 named guard passes both ways")
        #expect(answer.proven)
    }

    /// A guard written as words matches only the display name it spells, not another test ending in the same word.
    @Test
    func aGuardDoesNotMatchADisplayNameByItsLastWord() {
        let answer = Self.judged(
            without: ["\"fix sets the heading\"": true, "\"guard keeps the heading\"": true, "pinner()": false],
            with: ["\"fix sets the heading\"": true, "\"guard keeps the heading\"": true, "pinner()": true],
            guards: ["guard keeps the heading"]
        )
        let lines = Self.lines(answer.render())

        #expect(lines.first == "✘ 1 of 2 fails without Sources/ and passes with it; 1 named guard passes both ways")
        #expect(lines.contains("  ✘ \"fix sets the heading\" — passes without the change too, so it pins nothing"))
        #expect(lines.contains("  ✔ \"guard keeps the heading\" — a named guard: passes without the change and with it"))
        #expect(!answer.proven)
    }

    /// A bare word names no display-named test.
    @Test
    func aBareWordMatchesNoDisplayName() {
        let answer = Self.judged(
            without: ["\"fix sets the heading\"": false, "\"guard keeps the heading\"": true],
            with: ["\"fix sets the heading\"": true, "\"guard keeps the heading\"": true],
            guards: ["heading"]
        )

        #expect(Self.lines(answer.render()).contains("  ⚠ heading — named by --guard, but no test of that name ran"))
        #expect(!answer.proven)
    }

    /// A guard matching two tests holds for neither, and says which.
    @Test
    func aGuardMatchingTwoTestsIsAmbiguous() {
        let answer = Self.judged(
            without: ["WidgetTests.testNaming": true, "GadgetTests.testNaming": true, "pinner()": false],
            with: ["WidgetTests.testNaming": true, "GadgetTests.testNaming": true, "pinner()": true],
            guards: ["testNaming"]
        )
        let lines = Self.lines(answer.render())

        #expect(lines.first == "✘ 1 of 3 fails without Sources/ and passes with it; 0 of 1 named guards pass both ways")
        #expect(lines.contains("  ⚠ testNaming — named by --guard, but it matches 2 tests (GadgetTests.testNaming, WidgetTests.testNaming); name the one meant as the run printed it"))
        #expect(lines.contains("  ✘ WidgetTests.testNaming — passes without the change too, so it pins nothing"))
        #expect(lines.contains("  ✘ GadgetTests.testNaming — passes without the change too, so it pins nothing"))
        #expect(!answer.proven)
    }

    /// A display name guarded by its text with its quotes matches.
    @Test
    func aQuotedGuardMatchesADisplayName() {
        let answer = Self.judged(
            without: ["\"fix sets the heading\"": false, "\"guard keeps the heading\"": true],
            with: ["\"fix sets the heading\"": true, "\"guard keeps the heading\"": true],
            guards: ["\"guard keeps the heading\""]
        )

        #expect(Self.lines(answer.render()).contains("  ✔ \"guard keeps the heading\" — a named guard: passes without the change and with it"))
        #expect(answer.proven)
    }

    /// A guard the change did not write stays listed rather than folded into the untouched count.
    @Test
    func aGuardTheChangeDidNotWriteIsListedNotFolded() {
        let without = ["shoutingWorks()": false, "theGridReflows()": true]
        let with = ["shoutingWorks()": true, "theGridReflows()": true]
        let folded = Self.judged(without: without, with: with, changedTests: ["shoutingWorks"]).render()
        let guarded = Self.judged(without: without, with: with, changedTests: ["shoutingWorks"], guards: ["theGridReflows()"])

        #expect(Self.lines(folded).contains { $0.contains("does not touch") })
        #expect(Self.lines(guarded.render()).contains("  ✔ theGridReflows() — a named guard: passes without the change and with it"))
        #expect(!Self.lines(guarded.render()).contains { $0.contains("does not touch") })
        #expect(guarded.proven)
    }

    /// With only guards left there is nothing the change pinned, so the headline says nothing was proven.
    @Test
    func onlyGuardsRanProvesNothing() {
        let answer = Self.judged(without: ["theGridReflows()": true], with: ["theGridReflows()": true], guards: ["theGridReflows()"])

        #expect(Self.lines(answer.render()).first == "⚠ no test but the named guards ran — 1 of 1 named guards pass both ways; nothing was proven")
        #expect(!answer.proven)
    }

    /// Guards that held past the line cap are counted apart from the tests that did not.
    @Test
    func heldGuardsPastTheLineCapAreCountedApart() {
        var without = ["theGridReflows()": true]
        var with = ["theGridReflows()": true]
        for number in 0 ..< RunWithoutAnswer.testLineCap {
            without["pin\(String(format: "%02d", number))()"] = false
            with["pin\(String(format: "%02d", number))()"] = true
        }
        let answer = Self.judged(without: without, with: with, guards: ["theGridReflows()"])

        #expect(Self.lines(answer.render()).contains("  +1 more: 0 fail without the change and pass with it, 1 named guard passes both ways, 0 do not — see the raw logs"))
    }

    /// Without a guard named, a test that passes both ways reads as it always did.
    @Test
    func withoutAGuardATestPassingBothWaysPinsNothing() {
        let answer = Self.judged(
            without: ["shoutingWorks()": false, "theGridReflows()": true],
            with: ["shoutingWorks()": true, "theGridReflows()": true]
        )
        let lines = Self.lines(answer.render())

        #expect(lines.first == "✘ 1 of 2 fails without Sources/ and passes with it")
        #expect(lines.contains("  ✘ theGridReflows() — passes without the change too, so it pins nothing"))
        #expect(!answer.proven)
    }

    private static func judged(
        without: [String: Bool],
        with: [String: Bool],
        changedTests: Set<String>? = nil,
        guards: [String] = []
    ) -> RunWithoutAnswer {
        RunWithoutAnswerTests.judged(
            without: RunWithoutAnswerTests.run(without),
            with: RunWithoutAnswerTests.run(with),
            changedTests: changedTests,
            guards: guards
        )
    }

    private static func lines(_ answer: RunOutcome.Answer) -> [String] {
        answer.text.split(separator: "\n").map(String.init)
    }
}
