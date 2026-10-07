//
// Copyright © Agulhas Labs
//

import Foundation

/// What one sweep amounted to: the scans that carried Swift lookups, and the two numbers read off them.
///
/// Derived here rather than at the call site so the counting rule cannot drift from the scans it counts. **`sessions` is deliberately not `scans.count`**: a session contributes one scan per context, so a parent and its subagents are one session — and a parent that dispatched an Explore agent and made no Swift lookups of its own contributes no scan at all, so counting parents would head a report "0 sessions" above a populated table naming that session.
struct AuditFindings {
    let scans: [TranscriptAudit.Scan]

    /// The contexts that could reach the index, which are the only ones with a habit worth naming.
    ///
    /// Every section below the bucket list draws on these rather than on `scans`: the files a context read cold because it held no `digest` to call are not a digest habit that failed to form, and listing them under "the files worth a digest habit" would put work in front of a reader that reading the file differently could not have avoided. The count of them is still stated, on its own bucket row — they are named apart, not dropped.
    let reached: [TranscriptAudit.Scan]
    let totals: TranscriptTally
    let sessions: Int

    init(scans: [TranscriptAudit.Scan]) {
        self.scans = scans
        reached = scans.filter { !$0.tally.couldNotReachTheIndex }
        totals = TranscriptTally.pooled(scans.map(\.tally))
        sessions = Set(scans.map(\.session)).count
    }
}
