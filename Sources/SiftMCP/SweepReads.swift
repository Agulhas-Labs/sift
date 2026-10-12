//
// Copyright © Agulhas Labs
//

import Foundation

/// The transcripts one sweep scans, each read where the tally cache does not hold it, several at once, and handed back in the order the sweep planned them.
struct SweepReads {
    /// Each transcript's blank scan, in the order the sweep reports them: each in-scope session, then its subagents.
    let jobs: [TranscriptAudit.Scan]

    /// The position among the sweep's sessions of the session each job belongs to.
    let jobSession: [Int]

    /// For each of the sweep's sessions, the job that scans the session itself, where it is in scope.
    let ownJob: [Int?]

    /// Every job's scan, recalled or read, in job order, each carrying what its session's own transcript says of the session.
    ///
    /// A scan the cache holds for this file, window and build stands in for reading it; the rest are read on several threads at once, largest first, and each read is stored back. `advance` hears each session as its last transcript is done.
    func scans(options: TranscriptAudit.ScanOptions, snapshot: TranscriptSnapshot, since: Date?, cache: TranscriptTallyCache.Store?, advance: SweepProgress) -> [TranscriptAudit.Scan] {
        let sessions = ownJob.count
        var held = jobs.map { cache?.scan(of: $0, in: snapshot, since: since) }
        var remaining = Array(repeating: 0, count: sessions)
        for (job, index) in jobSession.enumerated() where held[job] == nil {
            remaining[index] += 1
        }
        var sessionsDone = 0
        func sessionDone() {
            sessionsDone += 1
            if sessionsDone < sessions {
                advance.reached(sessionsDone, of: sessions)
            }
        }
        for count in remaining where count == 0 {
            sessionDone()
        }
        let unread = held.indices.filter { held[$0] == nil }
        let read = ConcurrentScans<TranscriptAudit.Scan>.results(
            count: unread.count,
            order: unread.indices.sorted { snapshot.sizes[jobs[unread[$0]].transcript] ?? 0 > snapshot.sizes[jobs[unread[$1]].transcript] ?? 0 }
        ) { position in
            let blank = jobs[unread[position]]
            return TranscriptAudit.scan(URL(fileURLWithPath: blank.transcript), label: blank.label, session: blank.session, isSubagent: blank.isSubagent, options: options, snapshot: snapshot)
        } finished: { position in
            let index = jobSession[unread[position]]
            remaining[index] -= 1
            if remaining[index] == 0 {
                sessionDone()
            }
        }
        for (position, job) in unread.enumerated() {
            cache?.store(read[position], in: snapshot, since: since)
            held[job] = read[position]
        }

        // The session's own context answers for its subagents as well as for itself: their MCP tools come from
        // the session's servers, so a session that never held sift's explains why none of its agents did. Read
        // only where it is in scope — which is every session `render` sweeps, the one caller that names causes;
        // outside it, its subagents are explained by their own transcripts alone.
        var scans = held.compactMap(\.self)
        for (job, index) in jobSession.enumerated() {
            let own = ownJob[index].map { scans[$0] }
            scans[job].sessionHeldNoIndexTools = own?.heldNoIndexTools ?? false
            scans[job].sessionBinaryMissing = own?.binaryMissingAtStart ?? false
        }
        return scans
    }
}
