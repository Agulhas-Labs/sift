//
// Copyright © Agulhas Labs
//

import Foundation

/// What became of one cold lookup when its call was put to the current hook, with the call that made it where the line carried one.
struct ReplayedLookup {
    let outcome: ReplayOutcome
    let call: ReplayColdCall?
    /// What the other hook made of the same lookup, where a replay puts every call to two.
    var other: ReplayOutcome?
}
