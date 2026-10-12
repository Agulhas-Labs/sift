//
// Copyright © Agulhas Labs
//

import Foundation

/// Why the hook let a Swift lookup run unanswered for a reason of its own machinery rather than a judgement of worth.
///
/// It was backing off, or its own answer ran out of time. A failed or oversize answer is not named: those stay plain cold.
///
/// These are still misses, and stay in `cold`: unlike ``InPlaceAnswerer/Withholding/notSmaller`` and its siblings they say nothing about the answer being not worth giving, only that the hook could not give it. Naming the cause under `cold` is what lets a report of a machine's first day point at the hook's time budget (a back-off one overrun arms covers every later answer of that shape) rather than at the agent. Kept apart from ``SuppressionLog/callsLetThrough(in:prefix:)``, whose every entry moves a lookup out of `cold`.
public enum StoodAside: String, Sendable, Equatable, Codable, CaseIterable {
    /// An answer of the shape had run past its time budget in this repository within the back-off window.
    case backingOff
    /// The call's own answer ran out of time.
    case overTime

    /// The cause a logged withholding names, or `nil` for any other.
    init?(logged why: InPlaceAnswerer.Withholding) {
        switch why {
        case .backingOff: self = .backingOff
        case .overTime: self = .overTime
        default: return nil
        }
    }
}
