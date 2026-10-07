//
// Copyright © Agulhas Labs
//

import Foundation

/// Lets exactly one caller through, whichever arrives first.
///
/// Two things on the server's shutdown path need this and they are not the same thing. Three signal sources share one *concurrent* queue and their handler ends in `exit`, so two arriving together would run in parallel — two stop lines, and two `exit` calls at once, which Darwin can wedge in static destruction. And a signal racing an ordinary end of input would record a stop from each path: one start with two stops, and `sift status` reading whichever landed second, which is the wrong one exactly when the signal is the interesting half.
public final class OnceGuard: @unchecked Sendable {
    private let mutex = NSLock()
    private var claimed = false

    public init() {}

    public func claim() -> Bool {
        mutex.lock()
        defer { mutex.unlock() }
        guard !claimed else { return false }
        claimed = true
        return true
    }
}
