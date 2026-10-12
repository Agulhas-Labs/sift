//
// Copyright © Agulhas Labs
//

import Foundation

/// The sessions a count spans and the subagents among their contexts, spelled one way on every face that states them.
///
/// `usage` and `audit` once said "13 calls by 2 subagents" and "1 session" about the same minute's work, which read as two tools disagreeing about what they scanned: one counted a session with its subagents as one session and never named them, the other named the subagents and never the session. Both now say `1 session (+2 subagents)`, a parent and its subagents being one session, with the subagents beside it rather than folded in.
struct SessionCount: Equatable {
    let sessions: Int
    let subagents: Int

    /// `1 session`, or `1 session (+2 subagents)` where any subagent contributed.
    var spelled: String {
        let head = "\(sessions) session\(sessions == 1 ? "" : "s")"
        guard subagents > 0 else { return head }
        return "\(head) (+\(subagents) subagent\(subagents == 1 ? "" : "s"))"
    }
}
