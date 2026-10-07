//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// A test the listing lost that a console showed running and failing is counted as failed, and its suite is in the re-run hint, as one the event stream named is.
struct PackageShardNeverListedFailedTests {
    @Test func anXCTestMethodTheListingLostThatFailedIsCountedInTheHeadlineAndItsSuiteIsInTheRerunHint() throws {
        let listed = try PackageShardPlanner.listed("LibTests.FooTests/testA\nLibTests.BetaTests/five")
        let lost = try #require(PackageShardPlanner.listedIdentifier(of: DeclaredTest(
            target: "LibTests",
            targetWasGuessed: false,
            suite: "FooTests",
            function: "testB()",
            style: .xcTest,
            displayName: nil,
            disposition: .runs,
            path: "Tests/LibTests/FooTests.swift",
            line: 3
        )))
        var plan = PackageShardPlanner.plan(tests: listed, shards: 1) { _ in nil }
        plan.neverListed = [lost]
        var outcomes = RunTestOutcomes()
        for line in [
            "Test Case '-[LibTests.BetaTests five]' started.",
            "Test Case '-[LibTests.BetaTests five]' passed (0.001 seconds).",
            "Test Case '-[LibTests.FooTests testA]' started.",
            "Test Case '-[LibTests.FooTests testA]' passed (0.001 seconds).",
            "Test Case '-[LibTests.FooTests testB]' started.",
            "Test Case '-[LibTests.FooTests testB]' failed (0.001 seconds).",
        ] {
            outcomes.read(line)
        }

        let reconciliation = ShardMerge.reconcile(plan: plan, outcomes: [ShardOutcome(outcomes: outcomes, exitCode: 1, wallSeconds: 1, logPath: "log")])
        let rendered = ShardAnswerRenderer(swiftPackage: true).render(reconciliation, plan: plan)

        #expect(reconciliation.counts.failed == 1)
        #expect(reconciliation.failed.count == 1)
        #expect(rendered.contains("1 failed"), "\(rendered)")
        let hint = rendered.components(separatedBy: "re-run their suites alone").dropFirst().first ?? ""
        #expect(hint.contains("FooTests"), "\(rendered)")
    }
}
