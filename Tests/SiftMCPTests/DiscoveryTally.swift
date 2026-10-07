//
// Copyright © Agulhas Labs
//

import Foundation

/// Every directory a replay's root discovery asked git about, with how many times it asked.
final class DiscoveryTally: @unchecked Sendable {
    private let lock = NSLock()
    private var counts: [String: Int] = [:]

    var asked: [String: Int] {
        lock.withLock { counts }
    }

    func note(_ directory: URL) {
        lock.withLock { counts[directory.path, default: 0] += 1 }
    }
}
