//
// Copyright © Agulhas Labs
//

import Foundation

/// One line of the usage log a digest question could be answered by, parsed once, with what the question's cheap byte tests would have found in its text.
struct FollowedUsageLine {
    /// Where the line begins in the log.
    let offset: UInt64
    let session: String
    let entry: [String: Any]
    /// Whether the line's text holds the quoted word `digest`.
    let namesDigest: Bool
    /// Whether the line's text holds the quoted word `located`.
    let namesLocated: Bool

    /// The line in `bytes`, or `nil` where no digest question could be answered by it: no quoted word either question looks for, no JSON object, or no session whose id its text spells out.
    init?(_ bytes: Data, at offset: UInt64) {
        let namesDigest = bytes.range(of: Data(#""digest""#.utf8)) != nil
        let namesLocated = bytes.range(of: Data(#""located""#.utf8)) != nil
        guard namesDigest || namesLocated,
              let entry = try? JSONSerialization.jsonObject(with: Data(bytes)) as? [String: Any],
              let session = entry["session"] as? String,
              !session.isEmpty,
              bytes.range(of: Data(session.utf8)) != nil
        else { return nil }
        self.offset = offset
        self.session = session
        self.entry = entry
        self.namesDigest = namesDigest
        self.namesLocated = namesLocated
    }
}
