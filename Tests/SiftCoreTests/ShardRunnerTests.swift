//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// Covers running a plan's shards side by side: what comes back, in what order, and what happens to a shard that will not stop.
///
/// Every case but the last runs no process at all — the launch is a seam precisely so that the ordering, the bound and the cancellation are provable in milliseconds. The last one drives two real children, because none of the others would notice if the wiring to the launcher were wrong.
@Suite(.temporaryDirectories)
struct ShardRunnerTests {
    /// `--shard-timeout` lowers the floor a bound is never allowed under, and never raises it above three times the prediction: `bound(forPredicted:minimumSeconds:)` is what `sift test --shard-timeout` reaches.
    @Test
    func minimumSecondsLowersTheFloorBelowTheDefaultTenMinutes() {
        #expect(ShardRunner.bound(forPredicted: 20, minimumSeconds: 30) == 60)
        #expect(ShardRunner.bound(forPredicted: 5, minimumSeconds: 30) == 30)
        #expect(ShardRunner.bound(forPredicted: 5) == 600)
    }

    /// The merge reads a shard's outcome by the position it stands in, so the answer has to be in the plan's order and not in the order the shards happened to finish.
    ///
    /// Out of order, every count downstream is attributed to the wrong shard while looking entirely healthy: the fast shard's passes are read against the slow shard's tests, and the tests it never had are reported missing.
    @Test
    func outcomesComeBackInShardOrderHoweverTheShardsFinish() throws {
        let root = try TemporaryDirectory.make("shard-runner")
        // Shard 1 cannot finish until shard 2 has, so the finishing order is the reverse of the plan's.
        let secondIsDone = DispatchSemaphore(value: 0)
        let runner = ShardRunner(
            workingDirectory: root,
            repositoryRoot: nil,
            children: SetAsideChildren(),
            launch: { assignment, _ in
                if assignment.index == 1 {
                    _ = secondIsDone.wait(timeout: .now() + 10)
                } else {
                    secondIsDone.signal()
                }
                return Self.outcome(shard: assignment.index)
            }
        )

        let outcomes = runner.run([Self.assignment(2), Self.assignment(1)])

        #expect(outcomes.map(\.logPath) == ["/tmp/shard-1.log", "/tmp/shard-2.log"])
    }

    /// A shard that fails, however it fails, is one shard's news: the run is sharded to get an answer about the whole suite, and a runner that gave up on the first failure would report the others as missing.
    @Test
    func aFailingShardDoesNotStopTheOthers() throws {
        let root = try TemporaryDirectory.make("shard-runner")
        let runner = ShardRunner(
            workingDirectory: root,
            repositoryRoot: nil,
            children: SetAsideChildren(),
            launch: { assignment, _ in
                // Two kinds of failure at once: a shard whose tests failed, and a shard that never ran at all.
                if assignment.index == 3 {
                    throw RunError.nothingToRun
                }
                return Self.outcome(shard: assignment.index, exitCode: assignment.index == 2 ? 65 : 0)
            }
        )

        let outcomes = runner.run([Self.assignment(1), Self.assignment(2), Self.assignment(3)])

        #expect(outcomes.map(\.exitCode) == [0, 65, 127])
        #expect(outcomes.map(\.logPath) == ["/tmp/shard-1.log", "/tmp/shard-2.log", ""])
        #expect(outcomes[0].launchFailure == nil)
        #expect(outcomes[2].launchFailure == RunError.nothingToRun.description)
    }

    /// A shard past its bound is ended and says so, so that the tests it never reached read as unreached rather than as a suite that hung the run.
    ///
    /// The bound is the whole reason a sharded run can be trusted unattended: one wedged simulator otherwise holds every other shard's answer for as long as the harness allows.
    @Test
    func aShardPastItsBoundIsEndedAndMarkedTimedOut() throws {
        let root = try TemporaryDirectory.make("shard-runner")
        let stuck = DispatchSemaphore(value: 0)
        defer { stuck.signal() }
        let runner = ShardRunner(
            workingDirectory: root,
            repositoryRoot: nil,
            children: SetAsideChildren(),
            launch: { assignment, _ in
                guard assignment.index == 2 else {
                    return Self.outcome(shard: assignment.index)
                }
                _ = stuck.wait(timeout: .now() + 30)
                return Self.outcome(shard: 2)
            },
            patience: 0.1
        )

        let outcomes = runner.run([Self.assignment(1), Self.assignment(2, bound: 0.1)])

        #expect(outcomes.map(\.timedOut) == [false, true])
        #expect(outcomes[1].exitCode == 128 + SIGTERM)
        #expect(outcomes[1].outcomes.isEmpty)
        // The shard that answered in time keeps its own answer whatever became of its neighbour.
        #expect(outcomes[0].logPath == "/tmp/shard-1.log")
    }

    /// A cancelled run starts nothing more: the signal that cancels it is the last moment anything can be cleaned up, and a shard started after it is a child and a simulator nobody is left to delete.
    @Test
    func aCancelledRunStartsNoShardThatHasNotStarted() throws {
        let root = try TemporaryDirectory.make("shard-runner")
        let starts = Starts()
        let runner = ShardRunner(
            workingDirectory: root,
            repositoryRoot: nil,
            children: SetAsideChildren(),
            launch: { assignment, _ in
                starts.record()
                return Self.outcome(shard: assignment.index)
            }
        )
        runner.cancel()

        let outcomes = runner.run([Self.assignment(1), Self.assignment(2)])

        #expect(starts.total == 0)
        #expect(outcomes.count == 2)
        #expect(outcomes.allSatisfy { $0.outcomes.isEmpty && $0.exitCode == 128 + SIGTERM })
    }

    /// The live launcher, two children at once: each shard keeps its own transcript, and the one past its bound is ended rather than waited on.
    ///
    /// The only case here that touches a process, and the only one that would notice the launcher being called in a way that cannot be called twice at once — a shared log name, a shared handle — which is the failure a sharded run would meet on its first real invocation.
    @Test
    func liveShardsEachKeepTheirOwnLogAndTheOnePastItsBoundIsEnded() throws {
        let root = try TemporaryDirectory.make("shard-runner")
        let runner = ShardRunner(workingDirectory: root, repositoryRoot: nil, children: SetAsideChildren())
        let started = Date()

        let outcomes = runner.run([
            ShardRunner.Assignment(index: 1, argv: ["/bin/sh", "-c", "echo one; sleep 1"], bound: 60),
            ShardRunner.Assignment(index: 2, argv: ["/bin/sh", "-c", "echo two; sleep 30"], bound: 3),
        ])
        let elapsed = Date().timeIntervalSince(started)

        #expect(outcomes[0].exitCode == 0)
        #expect(!outcomes[0].timedOut)
        #expect(outcomes[1].timedOut)
        #expect(outcomes[1].exitCode >= 128)
        // Ended at its bound, not waited out: the second child asked for thirty seconds.
        #expect(elapsed < 10)
        #expect(outcomes[0].logPath != outcomes[1].logPath)
        #expect(try String(contentsOfFile: outcomes[0].logPath, encoding: .utf8) == "one\n")
        #expect(try String(contentsOfFile: outcomes[1].logPath, encoding: .utf8) == "two\n")
    }

    private static func assignment(_ index: Int, bound: TimeInterval = 60) -> ShardRunner.Assignment {
        ShardRunner.Assignment(index: index, argv: ["/usr/bin/true"], bound: bound)
    }

    private static func outcome(shard index: Int, exitCode: Int32 = 0) -> ShardOutcome {
        ShardOutcome(
            outcomes: RunTestOutcomes(),
            exitCode: exitCode,
            wallSeconds: Double(index),
            logPath: "/tmp/shard-\(index).log"
        )
    }
}

private extension ShardRunnerTests {
    /// How many shards were started, counted where several threads may be starting one at the same moment.
    final class Starts: @unchecked Sendable {
        private let gate = NSLock()
        private var started = 0

        var total: Int {
            gate.withLock { started }
        }

        func record() {
            gate.withLock { started += 1 }
        }
    }
}
