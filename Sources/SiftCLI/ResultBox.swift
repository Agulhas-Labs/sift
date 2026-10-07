//
// Copyright © Agulhas Labs
//

import Foundation

/// One value a background thread hands back to the thread that waits for it.
final class ResultBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value?

    var value: Value? {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}
