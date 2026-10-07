//
// Copyright © Agulhas Labs
//

import Foundation

/// The arithmetic of one group of tests a reported name cannot tell apart, shared by ``RunReconciler`` and ``ShardMerge`` so a sharded run and an unsharded one give one suite the same verdict.
///
/// **A conditional member is owed an ending like the rest**, because its ending cannot be told from an unconditional one's: fewer endings than members is a shortfall. A group with no unconditional member is the exception, since nothing in it can have been lost, so it is owed only what ended.
struct CountedGroup: Equatable {
    /// How many tests the group is reconciled over.
    let members: Int

    /// How many of them are conditional in their declaration.
    let conditional: Int

    /// How many endings the log printed under the group's name.
    let endings: Int

    /// How many members the endings account for.
    var ran: Int {
        min(endings, members)
    }

    /// How many members the group is owed an ending for: every one, unless every one is conditional.
    var owed: Int {
        members > conditional ? members : ran
    }

    /// How many owed endings never arrived.
    var missing: Int {
        owed - ran
    }

    /// The heading both answers name the members of such a group under, apart from a conditional test that reported nothing: some of them reported, and the count cannot say which.
    static var undecidedMembersHeading: String {
        "conditional and sharing a name whose endings cannot say which of them ran — counted in neither direction"
    }

    /// The sentence owed about conditional members that reported nothing and are counted in neither direction, or `nil` where there are none.
    func unowedNote(function: String) -> String? {
        let unowed = members - owed
        guard unowed > 0 else {
            return nil
        }
        return "\(function): \(unowed) of the \(members) conditional tests this name cannot tell apart reported nothing, which is counted in neither direction."
    }
}
