//
// Copyright © Agulhas Labs
//

import Foundation

/// Whether an in-place answer has begun the work a cold start makes slow: bringing the repository's index up to date.
///
/// An overrun is charged to a cold start only once this has begun (``InPlaceAnswerer``), because only then is the first build what ran out of time. A document's outline never begins it, and a search runs before it, so an overrun in either says nothing about the index being built and arms the full back-off.
final class InPlaceIndexing: @unchecked Sendable {
    private let lock = NSLock()
    private let coldStart: Bool
    private var begun: Bool

    /// `coldStart` says the repository's index had never completed a build when the answer began, and `begun` whether indexing is under way from the start, for an answer with no work to do before it.
    init(coldStart: Bool, begun: Bool) {
        self.coldStart = coldStart
        self.begun = begun
    }

    /// Whether an overrun now is the first index build's: the index had never completed a build and the answer has reached bringing it up to date.
    var isColdStart: Bool {
        lock.withLock { coldStart && begun }
    }

    /// Records that the answer is about to bring the index up to date.
    func begin() {
        lock.withLock { begun = true }
    }
}
