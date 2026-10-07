//
// Copyright © Agulhas Labs
//

import Foundation

/// A first-in, first-out async lock that stays held across the awaits of the body it runs, which an actor method does not (an actor lets another call in at every await).
final class AsyncGate: @unchecked Sendable {
    private let lock = NSLock()
    private var held = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    /// Runs `body` once every earlier caller's body has finished, and lets the next caller in when it ends, however it ends.
    func run<T>(_ body: () async throws -> T) async rethrows -> T {
        await enter()
        defer { leave() }
        return try await body()
    }

    private func enter() async {
        await withCheckedContinuation { continuation in
            let admitted = lock.withLock {
                if held {
                    waiters.append(continuation)
                    return false
                }
                held = true
                return true
            }
            if admitted {
                continuation.resume()
            }
        }
    }

    /// Hands the gate straight to the longest-waiting caller, so it is never seen free while one waits.
    private func leave() {
        let next: CheckedContinuation<Void, Never>? = lock.withLock {
            if waiters.isEmpty {
                held = false
                return nil
            }
            return waiters.removeFirst()
        }
        next?.resume()
    }
}
