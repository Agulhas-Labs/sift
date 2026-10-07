//
// Copyright © Agulhas Labs
//

import Foundation

/// A group of tests one reported name could not be told apart by, and how many of them never reported.
///
/// It is missing without being nameable: the arithmetic is sound and the identity is not, so the answer says how many of how many rather than inventing which.
public struct ReconciliationShortfall: Sendable, Equatable {
    /// The function name every test in the group declares.
    public let function: String

    /// How many of the group never reported.
    public let missing: Int

    /// How many tests the group holds.
    public let expected: Int

    /// How many of the group are conditional in their declaration, and so may have been skipped at runtime rather than lost.
    public let conditional: Int

    public init(function: String, missing: Int, expected: Int, conditional: Int = 0) {
        self.function = function
        self.missing = missing
        self.expected = expected
        self.conditional = conditional
    }

    /// `1 of these 2 never reported` — what the answer can honestly say about a group it cannot name into.
    ///
    /// Where the group holds conditional tests the count alone overstates what was lost, since a conditional test that reported nothing may simply have been switched off, so the sentence gives the bound the log does support: how many were lost at least, or that it cannot say whether any was.
    public var sentence: String {
        let count = "\(missing) of these \(expected) never reported"
        guard conditional > 0 else {
            return count
        }
        let lost = missing - conditional
        let bound = lost > 0
            ? "so at least \(lost) \(lost == 1 ? "was" : "were") lost"
            : "so the log cannot say whether a conditional test was skipped or a test was lost"
        return "\(count), and \(conditional) of the \(expected) \(conditional == 1 ? "is" : "are") conditional, \(bound)"
    }
}

public extension ReconciliationShortfall {
    /// The shortfall said as result lines lost rather than tests unreported, for a group whose shortfall is covered by starts in runs that printed a member's suite passing and a passing summary.
    var lostSentence: String {
        "\(missing) of these \(expected) lost their result lines"
    }
}
