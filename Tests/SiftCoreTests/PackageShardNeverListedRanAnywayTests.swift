//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// A test the listing lost that a shard ran all the same — an XCTest method its class's filter selected — is named once, as having run, and not as one no shard ran.
struct PackageShardNeverListedRanAnywayTests {
    @Test func anXCTestMethodTheListingLostThatItsClassRanIsNamedOnceAsRanButNotListed() throws {
        let listed = try PackageShardPlanner.listed("LibTests.FooTests/testA")
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
            "Test Case '-[LibTests.FooTests testA]' started.",
            "Test Case '-[LibTests.FooTests testA]' passed (0.001 seconds).",
            "Test Case '-[LibTests.FooTests testB]' started.",
            "Test Case '-[LibTests.FooTests testB]' passed (0.001 seconds).",
        ] {
            outcomes.read(line)
        }

        let reconciliation = ShardMerge.reconcile(plan: plan, outcomes: [ShardOutcome(outcomes: outcomes, exitCode: 0, wallSeconds: 1, logPath: "log")])
        let rendered = ShardAnswerRenderer(swiftPackage: true).render(reconciliation, plan: plan)

        #expect(reconciliation.counts.passed == 1)
        #expect(reconciliation.neverListed.isEmpty)
        #expect(reconciliation.unlisted == ["shard 1: \(lost.enumerated)"])
        #expect(!reconciliation.notes.contains { $0.contains("named no test the shard was given") }, "\(reconciliation.notes)")
        #expect(!rendered.contains("so no shard ran it"), "\(rendered)")
        #expect(!reconciliation.isGreen)
    }
}
