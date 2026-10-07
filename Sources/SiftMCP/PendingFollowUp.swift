//
// Copyright © Agulhas Labs
//

import Foundation

/// A solo refusal, already priced, waiting for the next tool call in the same context to say what followed it.
struct PendingFollowUp: Sendable, Equatable, Codable {
    var shape: RefusedCallShape
    var cost: RoundTripCost
}
