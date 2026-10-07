//
// Copyright © Agulhas Labs
//

import Foundation
import Testing

/// Stopping stub children from many tasks at once never leaves a cooperative-pool thread blocked on a child's exit.
struct DeadlineChildReapStressTests {
    /// More concurrent stoppers than there are cooperative threads each launch, kill and reap a child; all of them finish, well inside the limit.
    @Test(.timeLimit(.minutes(1))) func manyConcurrentKillsAreAllReaped() async throws {
        let children = DeadlineChildTests.Children()
        defer { children.stopAll() }
        let count = max(64, ProcessInfo.processInfo.activeProcessorCount * 8)

        let stopped = try await withThrowingTaskGroup(of: Bool.self) { group in
            for _ in 0 ..< count {
                group.addTask {
                    let child = try children.launch("trap '' TERM; exec sleep 100000")
                    await children.stop(child)
                    return !child.isRunning
                }
            }
            return try await group.reduce(0) { $0 + ($1 ? 1 : 0) }
        }

        #expect(stopped == count)
    }
}
