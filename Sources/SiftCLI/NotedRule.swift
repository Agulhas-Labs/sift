//
// Copyright © Agulhas Labs
//

import Foundation

/// The rule a suppression log last noted while the hook judged one call, so a replay or a `--verdict` probe can name the gate that withheld the call where the hook's own verdict names none.
final class NotedRule: @unchecked Sendable {
    private let lock = NSLock()
    private var rule: String?

    /// The rule noted last, or `nil` where nothing was noted.
    var last: String? {
        lock.lock()
        defer { lock.unlock() }
        return rule
    }

    /// Keeps `rule` as the one noted last.
    func record(_ rule: String) {
        lock.lock()
        defer { lock.unlock() }
        self.rule = rule
    }
}
