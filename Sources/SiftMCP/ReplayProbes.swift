//
// Copyright © Agulhas Labs
//

import Foundation

/// The window the replay reads, and the scan's filesystem and index probes, memoised once for the whole replay.
struct ReplayProbes {
    let since: Date?
    let until: Date?
    let timeZone: TimeZone
    let belowFloor: (String) -> Bool
    let couldAnswer: (String, String?) -> Bool
    let memberExists: (String, String, String?) -> Bool
    /// Where a path under a gone worktree is moved to, read off the session's own transcripts.
    var origins = WorktreeOrigins()
    /// The calls the hook's suppression log records letting run on worth, by the rule it logged, scored not worth as the audit the replay is appended to scores them.
    var loggedLetThrough: [String: InPlaceAnswerer.Withholding] = [:]
    /// The calls the hook's answered log records answering in place, read as the audit beside the replay reads them.
    var answeredCalls: Set<String> = []
    /// The transcripts as the audit beside the replay read them, cut at the sizes they had then, or nil to read each as it is now.
    var snapshot: TranscriptSnapshot?
}
