//
// Copyright © Agulhas Labs
//

import Foundation

/// What became of one cold lookup when its call was put to the current hook.
enum ReplayOutcome: Equatable {
    /// Answered in place, under the rule and call named.
    case recovered(String)
    /// Let through, under the rule named.
    case stillCold(String)
    /// Let through under the rule named because no index answer would be smaller than what the command prints, which is not worth answering and out of the share.
    case notWorth(String)
    /// A window or ranged read the hook lets through only because an answer the replay gave in place located its file, which the audit scores guided and out of the share.
    case located
    /// A whole read the hook lets through only because an answer the replay gave in place located its file, which the audit scores as read whole after its digest.
    case readWholeAfterAnswer
    /// The directory it runs in, its own or the one its command opens by moving to, is not on disk now, so it could not be asked.
    case unreplayable
}
