//
// Copyright © Agulhas Labs
//

import Foundation

/// What a sharded run has before its shards launch — the build's `.xctestrun` and the plan made from it — and when each was done.
struct TestRunPreparation {
    /// When the build began, which is what tells its `.xctestrun` files from an earlier build's.
    let began: Date
    /// When the build exited.
    let built: Date
    /// When the plan was made, the enumeration before it done.
    let planned: Date
    let xctestrun: URL
    let plan: ShardPlan

    /// The run's phases, from these timings and the moments the shards began, ended and were torn down.
    ///
    /// The devices are charged from the plan to the first shard's launch — the rest of the boots and the delete of any device the plan did not need — which is what the run waited on for them beyond the build and the enumeration they overlapped.
    func phases(shardsBegan: Date, shardsEnded: Date, tornDown: Date) -> ShardPhases {
        ShardPhases(
            build: built.timeIntervalSince(began),
            enumerate: planned.timeIntervalSince(built),
            devicesReady: shardsBegan.timeIntervalSince(planned),
            shards: shardsEnded.timeIntervalSince(shardsBegan),
            teardown: tornDown.timeIntervalSince(shardsEnded)
        )
    }
}
