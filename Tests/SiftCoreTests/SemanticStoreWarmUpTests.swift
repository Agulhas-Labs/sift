//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// The race itself, made deterministic: a zero budget holds a real open in its warming state, so the read a suite used to make refuses every time, and the same read behind the wait resolves.
///
/// Without the determinism there is nothing to pin — the racing read passes in isolation, which is exactly what made the failure look like someone else's bug.
@Suite(.temporaryDirectories)
struct SemanticStoreWarmUpTests {
    /// A query that would have read the store while it loads waits for it instead, and the answer it then asserts on is resolved.
    @Test
    func aQueryThatWouldReadALoadingStoreWaitsForItInstead() async throws {
        let engine = try SiftEngine(directory: SemanticWhereTests.makeBuiltRepo())
        // The open cannot settle while the budget check holds its lock, so the first read is warming every time.
        engine.openBudget = 0
        let freshness = try await engine.ensureFresh()

        let raced = try await engine.lookup(symbol: "helper()", freshness: freshness)
        try await engine.awaitSemanticStore()
        let waited = try await engine.lookup(symbol: "helper()", freshness: freshness)

        #expect(raced.contains(SemanticStoreWarmUp.refusal), "the unwaited read refuses: \(raced)")
        #expect(!raced.contains("callers of Lib.helper()"), "\(raced)")
        #expect(!waited.contains(SemanticStoreWarmUp.refusal), "the waited read never sees warming: \(waited)")
        #expect(waited.contains("callers of Lib.helper() (1):"), "\(waited)")
    }

    /// A store that answers `warming` for a bounded run of reads is asked again until it stops, and the answer the test then asserts on is the resolved one.
    ///
    /// The engine's own warm-up cannot be timed — a fixture's store may well have landed between two reads — so the reads themselves are driven here, which is the only way to state how many refusals the wait sits through. The pause between retries is driven too, with an immediate return: a real sleep's resumption is a statement about how busy the machine's scheduler is, not about the wait-out logic under test, and that dependency is what let this test's run time scale with the load on the machine rather than with the retries it counts.
    @Test
    func aStoreThatRefusesForABoundedRunOfReadsIsWaitedOut() async throws {
        let resolved = "tree: fixture  semantic: fresh"
        let reads = Reads()

        let answer = try await SemanticStoreWarmUp.settled(pause: {}, {
            reads.count += 1
            return reads.count < 3 ? "tree: fixture  " + SemanticStoreWarmUp.refusal : resolved
        })

        #expect(reads.count == 3, "the wait sat through both refusals")
        #expect(answer == resolved)
    }

    /// A wait that runs out fails as a test, with the answer it kept getting, rather than as a suite that never finishes.
    @Test
    func aStoreThatNeverFinishesLoadingFailsAtTheDeadline() async throws {
        await #expect(throws: SemanticStoreWarmUp.StillWarming.self) {
            _ = try await SemanticStoreWarmUp.settled(within: 0.2) {
                "tree: fixture  head: abc1234  " + SemanticStoreWarmUp.refusal
            }
        }
    }
}

extension SemanticStoreWarmUpTests {
    /// How many times the driven store has been read.
    final class Reads {
        var count = 0
    }
}
