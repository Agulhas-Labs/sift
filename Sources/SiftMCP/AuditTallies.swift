//
// Copyright © Agulhas Labs
//

import Foundation

/// The audit's own counts for each context it scanned, by transcript, handed to the replay beside it so the share it prints as the audit's is the audit section's.
///
/// The replay walks the same transcripts again to put each call to the hook, and its walk can classify a lookup differently from the audit's: it asks the floor of a gone worktree's path moved onto its repository, and reads the hook's suppression log after each event rather than inside the scan. Counted by that walk, the "audit's own" share would be the replay's count of it, so the audit's counts are carried across instead.
public struct AuditTallies: Sendable {
    /// Each context's counts, by the path of the transcript they were read from.
    let tallies: [String: TranscriptTally]
    /// Each context's counts split by the local day each lookup landed on, by the path of the transcript they were read from.
    let byDay: [String: [String: TranscriptTally]]

    init(tallies: [String: TranscriptTally], byDay: [String: [String: TranscriptTally]] = [:]) {
        self.tallies = tallies
        self.byDay = byDay
    }

    init(_ scans: [TranscriptAudit.Scan]) {
        tallies = Dictionary(scans.map { ($0.transcript, $0.tally) }, uniquingKeysWith: { first, _ in first })
        byDay = Dictionary(scans.map { ($0.transcript, $0.byDay) }, uniquingKeysWith: { first, _ in first })
    }

    /// `context` with the audit's own counts for `transcript` in place of the replay's, or unchanged where the audit read no such transcript — one outside `--root`, which the replay still walks.
    func applied(to context: ContextReplay, of transcript: URL) -> ContextReplay {
        guard let tally = tallies[transcript.path] else { return context }
        var applied = context
        applied.tally = tally
        applied.byDay = byDay[transcript.path] ?? [:]
        return applied
    }
}
