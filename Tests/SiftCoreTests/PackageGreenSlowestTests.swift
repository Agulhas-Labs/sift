//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// A green package run keeps the `slowest:` listing, because its per-test timing is the part of the answer a SwiftPM caller has no other route to.
struct PackageGreenSlowestTests {
    @Test
    func aGreenPackageRunNamesItsSlowestTests() throws {
        let first = try #require(TestIdentifier(enumerated: "GizmoTests/PalletTests/testAddition()"))
        let second = try #require(TestIdentifier(enumerated: "GizmoTests/PalletTests/testSubtraction()"))
        let counts = ShardReconciliation.Counts(expected: 2, ran: 2, passed: 2, failed: 0, skipped: 0, missing: 0, duplicated: 0)
        let shard = ShardReconciliation.Shard(
            index: 1, testCount: 2, iterations: 1, wallSeconds: 5, executionSeconds: 3, predictedSeconds: 6, exitCode: 0,
            logPath: "/tmp/shard.log", recording: TestDurationStore.Recording(observations: [], retried: false, missing: 0)
        )
        let reconciliation = ShardReconciliation(
            counts: counts, shards: [shard], missing: [], shortfalls: [], duplicated: [],
            failed: [], timings: [
                ShardReconciliation.Timing(shard: 1, test: first, seconds: 2),
                ShardReconciliation.Timing(shard: 1, test: second, seconds: 1),
            ], failures: [], notes: []
        )
        let plan = ShardPlan(
            shards: [ShardPlan.Shard(index: 1, tests: [first, second], predictedSeconds: 22)],
            requestedShards: 1, overheadSeconds: 20, estimatedTests: 0, estimatedSeconds: 1, lowering: nil
        )

        let rendered = ShardAnswerRenderer(swiftPackage: true).render(reconciliation, plan: plan)

        #expect(rendered == """
        ✔ sift test — 2 tests passed across 1 shard
          expected 2 · ran 2 · passed 2 · failed 0 · skipped 0 · missing 0 · duplicated 0
          shards: 1 — 2 tests, wall 5s (predicted 6s)
        slowest:
          2s  GizmoTests/PalletTests/testAddition()
          1s  GizmoTests/PalletTests/testSubtraction()
        """)
    }
}
