//
// Copyright © Agulhas Labs
//

import Foundation

/// One member line parsed back out of a rendered digest, so a later read can be attributed to it.
///
/// Read from the answer text the transcript recorded rather than re-rendered now: the repo has moved on since, and what the session acted on is what the session was shown.
public struct DigestMember: Sendable, Equatable {
    var name: String
    var low: Int
    var high: Int

    /// Whether the digest gave this nested type a count and no names.
    ///
    /// The distinction the whole report turns on. `— 8 cases/members` is a number standing where the content was; `— 8 cases/members: freestyle backstroke …` is the same line carrying it. Both spellings can appear in the transcripts a report reads, and this is what tells them apart.
    var collapsed: Bool
}
