//
// Copyright © Agulhas Labs
//

import Foundation

/// The transcript's clock: the instant of the call being replayed, which is what the ledger's quiet spells and the back-off's window are measured against.
final class ReplayClock: @unchecked Sendable {
    private let lock = NSLock()
    private var instant = Date()

    var now: Date {
        lock.lock()
        defer { lock.unlock() }
        return instant
    }

    /// Moves the clock to `date`, where the line carried one.
    func advance(to date: Date?) {
        guard let date else { return }
        lock.lock()
        defer { lock.unlock() }
        instant = date
    }
}
