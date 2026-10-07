//
// Copyright © Agulhas Labs
//

import Foundation

/// A solo refusal's call, waiting for the turn after it to say what the round trip cost.
struct PendingRoundTrip: Sendable, Equatable, Codable {
    var turn: String
    var shape: RefusedCallShape
}
