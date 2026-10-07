//
// Copyright © Agulhas Labs
//

import Foundation

/// Waits for an async operation with a deadline, for a test that must fail rather than hang when an answer never comes.
///
/// For the operations a task group cannot race: a group waits for every child before it returns, and a line reader's wait or a server's run loop cannot be cancelled, so a group would hang exactly where the deadline was meant to end it. Here the operation runs in a task of its own and the wait polls for its result, so a deadline that passes leaves that task behind and returns — which is only acceptable in test-only code: the leaked task outlives the test that gave up on it, not the process, and the run carries on with whatever else is in the suite.
struct Deadline {
    /// What `operation` produced, or `nil` when it had not finished within `seconds`.
    static func within<T: Sendable>(seconds: Int, _ operation: @escaping @Sendable () async -> T) async -> T? {
        let result = Result<T>()
        Task { await result.set(operation()) }
        for _ in 0 ..< (seconds * 100) {
            if let value = result.value {
                return value
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return result.value
    }
}

private extension Deadline {
    /// The operation's result, handed from the task that produced it to the one polling for it.
    final class Result<T: Sendable>: @unchecked Sendable {
        private let mutex = NSLock()
        private var stored: T?

        var value: T? {
            mutex.lock()
            defer { mutex.unlock() }
            return stored
        }

        func set(_ value: T) {
            mutex.lock()
            defer { mutex.unlock() }
            stored = value
        }
    }
}
