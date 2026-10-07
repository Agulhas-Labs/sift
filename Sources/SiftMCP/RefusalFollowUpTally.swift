//
// Copyright © Agulhas Labs
//

import Foundation

/// One class of lone refusals' follow-up — a count, and what those round trips cost, priced the same way the headline total is: the input-equivalent of what each next turn re-sent.
public struct RefusalFollowUpTally: Sendable, Equatable, Codable {
    public var count: Int
    public var inputEquivalentTokens: Int

    public init(count: Int = 0, inputEquivalentTokens: Int = 0) {
        self.count = count
        self.inputEquivalentTokens = inputEquivalentTokens
    }

    /// `count`'s zero check, spelled to dodge SwiftLint's `empty_count` — a plain `Int` this counts, not a collection, so `isEmpty` is a name and not a rewrite of `count == 0` into something the rule would rather see.
    public var isEmpty: Bool {
        count.signum() == 0
    }

    public static func += (lhs: inout RefusalFollowUpTally, rhs: RefusalFollowUpTally) {
        lhs.count += rhs.count
        lhs.inputEquivalentTokens += rhs.inputEquivalentTokens
    }
}
