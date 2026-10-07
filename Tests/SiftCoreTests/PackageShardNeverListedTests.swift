//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// A test the index declares and `swift test list` lost, set against the plan so a suite the listing dropped whole cannot leave the run green.
struct PackageShardNeverListedTests {
    private static func declaration(_ target: String, _ suite: String, _ function: String) -> DeclaredTest {
        DeclaredTest(
            target: target,
            targetWasGuessed: false,
            suite: suite,
            function: function,
            style: .swiftTesting,
            displayName: nil,
            disposition: .runs,
            path: "Tests/\(target)/Tests.swift",
            line: 1
        )
    }

    /// A stream in which each of `listed` was declared, started and ended, passing.
    private static func stream(_ listed: [String]) -> ShardEventStream {
        ShardEventStream.read(listed.flatMap { listed in
            let id = "\(listed)/Tests.swift:3:6".replacingOccurrences(of: "/", with: #"\/"#)
            return [
                #"{"kind":"test","payload":{"id":"\#(id)","kind":"function","name":"x"},"version":0}"#,
                #"{"kind":"event","payload":{"instant":{"absolute":1},"iteration":1,"kind":"testStarted","messages":[],"testID":"\#(id)"},"version":0}"#,
                #"{"kind":"event","payload":{"instant":{"absolute":2},"iteration":1,"kind":"testEnded","messages":[],"testID":"\#(id)"},"version":0}"#,
            ]
        }.joined(separator: "\n"))
    }

    /// A repository whose one test file still declares `one()`, `two()` and the file-scope `lost()`, and no longer `renamed()`.
    private static func repository() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("never-listed-\(UUID().uuidString)", isDirectory: true)
        let tests = root.appendingPathComponent("Tests/LibTests", isDirectory: true)
        try FileManager.default.createDirectory(at: tests, withIntermediateDirectories: true)
        try "struct AlphaTests {\n    @Test func one() {}\n    @Test func two() {}\n}\n@Test func lost() {}\n"
            .write(to: tests.appendingPathComponent("Tests.swift"), atomically: true, encoding: .utf8)
        return root
    }

    private static let inventory = TestInventory(
        tests: [
            declaration("LibTests", "AlphaTests", "one()"),
            declaration("LibTests", "AlphaTests", "two()"),
            declaration("LibTests", "", "lost()"),
            declaration("LibTests", "AlphaTests", "renamed()"),
            declaration("OtherTests", "OtherTests", "elsewhere()"),
        ],
        guessedTargets: []
    )

    @Test func aFileScopeTestTheListingLostMakesTheRunRedByName() throws {
        let root = try Self.repository()
        defer { try? FileManager.default.removeItem(at: root) }
        let listed = try PackageShardPlanner.listed("LibTests.AlphaTests/one()\nLibTests.AlphaTests/two()")
        let lost = try PackageShardPlanner.listed("LibTests.lost()")

        var plan = PackageShardPlanner.plan(tests: listed, shards: 1) { _ in nil }
        plan.neverListed = PackageShardPlanner.neverListed(declaredIn: Self.inventory, listed: listed, repositoryRoot: root)
        var outcome = ShardOutcome(outcomes: RunTestOutcomes(), exitCode: 0, wallSeconds: 2, logPath: "log")
        outcome.eventStream = Self.stream(["LibTests.AlphaTests/one()", "LibTests.AlphaTests/two()"])
        let reconciliation = ShardMerge.reconcile(plan: plan, outcomes: [outcome])
        let rendered = ShardAnswerRenderer(swiftPackage: true).render(reconciliation, plan: plan)

        // A renamed test the index still holds is not owed, and neither is another package's.
        #expect(plan.neverListed == lost)
        #expect(reconciliation.counts.passed == 2)
        #expect(reconciliation.counts.missing == 0)
        #expect(reconciliation.neverListed == lost)
        #expect(!reconciliation.isGreen)
        #expect(reconciliation.exitCode == 1)
        #expect(rendered.hasPrefix("✘ sift test — 1 declared but never listed"))
        #expect(rendered.contains("declared but never listed — the index declares it and `swift test list` did not name it, so no shard ran it:\n  \(lost[0].enumerated)"))
    }

    @Test func aDeclaredTestAStreamEndedIsNamedOnceAsRanButNotListed() throws {
        let root = try Self.repository()
        defer { try? FileManager.default.removeItem(at: root) }
        let listed = try PackageShardPlanner.listed("LibTests.AlphaTests/one()")
        let two = try PackageShardPlanner.listed("LibTests.AlphaTests/two()")

        var plan = PackageShardPlanner.plan(tests: listed, shards: 1) { _ in nil }
        plan.neverListed = PackageShardPlanner.neverListed(declaredIn: Self.inventory, listed: listed, repositoryRoot: root)
        var outcome = ShardOutcome(outcomes: RunTestOutcomes(), exitCode: 0, wallSeconds: 2, logPath: "log")
        outcome.eventStream = Self.stream(["LibTests.AlphaTests/one()", "LibTests.AlphaTests/two()"])
        let reconciliation = ShardMerge.reconcile(plan: plan, outcomes: [outcome])

        #expect(plan.neverListed.contains(two[0]))
        #expect(reconciliation.unlisted == ["shard 1: \(two[0].enumerated)"])
        #expect(!reconciliation.neverListed.contains(two[0]))
        #expect(!reconciliation.isGreen)
    }

    @Test func aRunWhoseListingNamedEveryDeclaredTestStaysGreen() throws {
        let root = try Self.repository()
        defer { try? FileManager.default.removeItem(at: root) }
        let listed = try PackageShardPlanner.listed("LibTests.AlphaTests/one()\nLibTests.AlphaTests/two()\nLibTests.lost()")

        var plan = PackageShardPlanner.plan(tests: listed, shards: 1) { _ in nil }
        plan.neverListed = PackageShardPlanner.neverListed(declaredIn: Self.inventory, listed: listed, repositoryRoot: root)
        var outcome = ShardOutcome(outcomes: RunTestOutcomes(), exitCode: 0, wallSeconds: 2, logPath: "log")
        outcome.eventStream = Self.stream(["LibTests.AlphaTests/one()", "LibTests.AlphaTests/two()", "LibTests.lost()"])
        let reconciliation = ShardMerge.reconcile(plan: plan, outcomes: [outcome])

        #expect(plan.neverListed.isEmpty)
        #expect(reconciliation.isGreen)
    }
}
