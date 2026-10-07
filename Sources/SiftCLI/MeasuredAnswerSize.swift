//
// Copyright © Agulhas Labs
//

import Foundation

/// The bytes the last answer withheld over the size budget came to, handed from the in-place answerer to the replayed verdict it decides.
final class MeasuredAnswerSize: @unchecked Sendable {
    private let lock = NSLock()
    private var bytes: Int?

    /// Records `served` as the size of the answer just withheld.
    func record(_ served: Int) {
        lock.withLock { bytes = served }
    }

    /// The size recorded, if an answer was withheld over the budget.
    var value: Int? {
        lock.withLock { bytes }
    }
}
