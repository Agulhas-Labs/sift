//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// A shard's loss line names which of its Swift Testing processes printed no `Test run with …` line.
struct ShardLossLineProcessTests {
    private static let alpha = test("LibTests.AlphaTests/testOne()")
    private static let beta = test("LibTests.BetaTests/testTwo()")

    private static func test(_ listed: String) -> TestIdentifier {
        ((try? PackageShardPlanner.listed(listed)) ?? []).first ?? ((try? PackageShardPlanner.listed("Invalid.Invalid/invalid()")) ?? [])[0]
    }

    /// The answer for a one-shard run whose log carries `lines`, which lost `beta`.
    private static func answer(_ lines: [String], closed: Bool) -> String {
        let plan = PackageShardPlanner.plan(tests: [alpha, beta], shards: 1) { _ in nil }
        var read = RunTestOutcomes()
        for line in lines {
            read.read(line)
        }
        var outcome = ShardOutcome(outcomes: read, exitCode: 139, wallSeconds: 1, logPath: "/runs/kept.log")
        outcome.closedWithRunSummary = closed
        return ShardAnswerRenderer(swiftPackage: true).render(ShardMerge.reconcile(plan: plan, outcomes: [outcome]), plan: plan)
    }

    private static var opened: String {
        "◇ Test run started."
    }

    private static var closing: String {
        "✔ Test run with 1 test in 1 suite passed after 0.001 seconds."
    }

    private static var passed: String {
        "✔ Test testOne() passed after 0.1 seconds."
    }

    @Test func theProcessThatPrintedNoClosingLineIsNamedByPosition() {
        let second = Self.answer([Self.opened, Self.passed, Self.closing, Self.opened], closed: false)
        let first = Self.answer([Self.opened, Self.passed, Self.opened, Self.closing], closed: false)

        #expect(second.contains("the 2nd of 2 Swift Testing processes printed no `Test run with …` line"))
        #expect(first.contains("the 1st of 2 Swift Testing processes printed no `Test run with …` line"))
    }

    @Test func aLogTheRendererCannotNameAProcessOfKeepsTheGeneralWording() {
        let single = Self.answer([Self.opened, Self.passed], closed: false)
        let both = Self.answer([Self.opened, Self.opened], closed: false)

        #expect(single.contains("no Swift Testing `Test run with …` line in its log"))
        #expect(both.contains("no Swift Testing `Test run with …` line in its log"))
    }
}
