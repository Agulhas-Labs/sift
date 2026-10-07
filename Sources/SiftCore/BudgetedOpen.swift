//
// Copyright © Agulhas Labs
//

import Foundation

/// Runs a slow, uncancellable open under a time budget, leaving it warming in the background when it overruns.
///
/// `IndexStoreDB(waitUntilDoneInitializing: true)` ingests the whole store before it returns. On a single-app repo that is about a second; on a large monorepo it can run to minutes. There is nothing to cancel — the call is synchronous and the ingest *is* the work — so the budget aborts nothing. It decides how long a *caller* waits before answering with what it already has, while the open runs on to completion and lands in the cache for the query after it.
///
/// Waiting it out is the failure this avoids, and the cost is not the wait: a minute-long tool call is indistinguishable from a hang, and a caller that gives up on one goes back to grepping and does not ask again.
final class BudgetedOpen<Product: AnyObject & Sendable>: @unchecked Sendable {
    private let condition = NSCondition()
    private var state: State = .idle

    /// The product when it lands inside `budget`, and otherwise a report that it is still warming.
    ///
    /// At most one open runs per key. A caller arriving mid-warm waits out what is left of its own budget on the open already running rather than starting a second one — without that, every query against a cold store would kick off another full ingest of the same store, and the machine would spend the afternoon rebuilding one cache.
    func open(key: Key, budget: TimeInterval, work: @escaping @Sendable () throws -> Product) -> Outcome {
        condition.lock()
        defer { condition.unlock() }

        if let settled = settledOutcome(for: key) {
            return settled
        }

        let since: Date
        if case let .warming(warmingKey, warmingSince) = state, warmingKey == key {
            since = warmingSince
        } else {
            since = Date()
            state = .warming(key: key, since: since)
            launch(key: key, work: work)
        }

        let deadline = Date().addingTimeInterval(budget)
        while Date() < deadline {
            if let settled = settledOutcome(for: key) {
                return settled
            }
            if !condition.wait(until: deadline) {
                break
            }
        }
        if let settled = settledOutcome(for: key) {
            return settled
        }
        return .warming(seconds: Date().timeIntervalSince(since))
    }

    /// Drops the outcome `key` settled on, so the next open of it runs afresh rather than answering with that one.
    ///
    /// For an outcome that says nothing about the store the key names now: an open set aside because its store was replaced while it read, when that store has since come back.
    func forget(_ key: Key) {
        condition.lock()
        defer { condition.unlock() }
        if settledOutcome(for: key) != nil {
            state = .idle
        }
    }

    /// The outcome for a key that has already finished, or `nil` while it has not.
    private func settledOutcome(for key: Key) -> Outcome? {
        switch state {
        case let .ready(readyKey, product) where readyKey == key: .opened(product)
        case let .failed(failedKey, error) where failedKey == key: .failed(error)
        default: nil
        }
    }

    /// Runs the open on a thread of its own rather than a pooled one, which it would hold for minutes.
    private func launch(key: Key, work: @escaping @Sendable () throws -> Product) {
        Thread.detachNewThread { [self] in
            let result = Result(catching: work)
            condition.lock()
            defer { condition.unlock() }
            // A key that moved on while this ran — a build landed, discovery moved — discards the result.
            // Whoever is waiting is waiting on the newer open, and storing this one under their key would
            // answer a question nobody asked.
            guard case let .warming(warmingKey, _) = state, warmingKey == key else {
                condition.broadcast()
                return
            }
            switch result {
            case let .success(product): state = .ready(key: key, product: product)
            case let .failure(error): state = .failed(key: key, error: error)
            }
            condition.broadcast()
        }
    }
}

extension BudgetedOpen {
    /// What an open is keyed on: a different store, or newer units under the same one, is a different open.
    ///
    /// `path` is the store's cache directory, which names the store's own path and its directory's identity both (``SemanticCache``).
    struct Key: Equatable {
        let path: String
        let anchor: Date
    }

    enum Outcome {
        case opened(Product)
        /// Still ingesting after `seconds`, and still going.
        case warming(seconds: TimeInterval)
        case failed(Error)
    }

    private enum State {
        case idle
        case warming(key: Key, since: Date)
        case ready(key: Key, product: Product)
        case failed(key: Key, error: Error)
    }
}
