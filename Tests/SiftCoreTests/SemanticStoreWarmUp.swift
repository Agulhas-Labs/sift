//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore

/// Waiting the index store's warm-up out, so an assertion never reads the refusal a store that is still loading answers with.
///
/// `semantic: warming` stays an honest refusal for a real caller — a store exists, it is still being read, and the remedy is to ask again, never to build (``SemanticAxis/warming``). So the wait lives here and not in the query: a query that waited would turn a refusal the freshness contract calls honest into a stall the caller cannot see.
///
/// What a test must not do is *assert* on it. Under load — several builds running in parallel worktrees — a cold open overruns the engine's five-second budget, and a run whose own diff was green in isolation failed 17 assertions across two suites, every one of them reading `warming`. That lands on the pre-push hook, the one gate an agent cannot skip, and its text is indistinguishable from a real staleness bug, so the next move is to go looking through a diff that had nothing to do with it.
struct SemanticStoreWarmUp {
    /// How long a test waits for a store to finish loading before failing.
    ///
    /// Generous, because this is not a timing assertion: a fixture's store opens in well under a second when the machine is quiet, and the number exists only so that a store which will never open fails as a test rather than as a suite that hangs.
    static let deadline: TimeInterval = 120

    /// The name the warm-up asks about.
    ///
    /// Any name does: the answer is thrown away, and only the open it pays for is wanted.
    static var probe: String {
        "GizmoCore"
    }

    /// The header line's verdict while the store is still being read.
    static var refusal: String {
        "semantic: " + SemanticAxis.warming.rendered
    }

    /// Runs `answer` until it comes back from a store that has finished loading, and throws at `deadline` rather than waiting on one that never will.
    ///
    /// `pause` is the wait between retries — a real `Task.sleep` in production, so a genuinely loading store gets a moment before being asked again. A test that drives `answer` itself (no real store behind it) passes a `pause` that returns immediately: the retries it counts are then a statement about `answer`, not about how promptly the machine's scheduler resumes a sleeping task, which is exactly the wall-clock dependency that made this flake under load.
    static func settled(
        within deadline: TimeInterval = Self.deadline,
        pause: @Sendable () async throws -> Void = { try await Task.sleep(for: .milliseconds(100)) },
        _ answer: () async throws -> String
    ) async throws -> String {
        let giveUp = Date().addingTimeInterval(deadline)
        while true {
            let output = try await answer()
            guard output.contains(refusal) else {
                return output
            }
            guard Date() < giveUp else {
                throw StillWarming(seconds: deadline, answer: output)
            }
            try await pause()
        }
    }
}

extension SemanticStoreWarmUp {
    /// A store still loading when the wait ran out — the loud failure that a hang would not be.
    struct StillWarming: Error, CustomStringConvertible {
        let seconds: TimeInterval
        let answer: String

        var description: String {
            "the index store was still warming after \(Int(seconds))s — \(answer)"
        }
    }
}

extension SiftEngine {
    /// Waits for this engine's index store to finish loading, so every query asked of it afterwards resolves instead of refusing.
    ///
    /// Called once, after the last build a test makes and before its first assertion: the opened store is held on the engine, so the queries that follow never see `warming` — `diff` among them, which states what the store resolved in its body rather than in the header and so cannot be waited on by the text of its own answer.
    func awaitSemanticStore(within deadline: TimeInterval = SemanticStoreWarmUp.deadline) async throws {
        let freshness = try await ensureFresh()
        _ = try await SemanticStoreWarmUp.settled(within: deadline) {
            try await lookup(symbol: SemanticStoreWarmUp.probe, freshness: freshness)
        }
    }
}
