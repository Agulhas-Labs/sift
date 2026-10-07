//
// Copyright © Agulhas Labs
//

import Foundation
import SiftCore

/// What `audit --scan-diff` hands another build's `sift scan-dump` on stdin, so both scan the same bytes over the same window: the snapshot's transcripts and their sizes, the window's two instants, and the suppression log the audit reads with its size.
///
/// Its fields are the contract between two builds, so they are plain values — paths, byte counts, seconds since 1970 — and never another type's own coding, which can change under a later build.
public struct ScanDumpRequest: Sendable, Equatable, Codable {
    /// The session transcripts, in the order the snapshot holds them.
    public let sessions: [String]
    /// Each session's subagent transcripts, by the session's path.
    public let subagents: [String: [String]]
    /// Each transcript's size in bytes when the snapshot was taken, by path.
    public let sizes: [String: Int]
    /// The window's start and end, in seconds since 1970, `nil` where the window is open that way.
    public let since: Double?
    public let until: Double?
    /// The suppression log whose logged-on-worth calls the scan scores as not worth, `nil` for none.
    public let suppressionLog: String?
    /// The log's size in bytes when the snapshot was taken, the prefix both scans read — `0` for a log named but not there yet, so one the hook writes between the two scans is read by neither; `nil` reads it whole.
    public let suppressionLogSize: Int?

    /// The request for `snapshot` over `since`..<`until`, reading `suppressionLog` as it stands now.
    public init(snapshot: TranscriptSnapshot, since: Date?, until: Date?, suppressionLog: URL?) {
        sessions = snapshot.sessions.map(\.path)
        subagents = snapshot.agents.mapValues { $0.map(\.path) }
        sizes = snapshot.sizes
        self.since = since?.timeIntervalSince1970
        self.until = until?.timeIntervalSince1970
        self.suppressionLog = suppressionLog?.path
        suppressionLogSize = suppressionLog.map { (try? $0.resolvingSymlinksInPath().resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0 }
    }

    /// Every window the audit's own sweep scores over the request's snapshot, session by session and each session before its subagents, each keyed by its session's id.
    ///
    /// Taken from the sweep the audit's text is rendered from, contexts it drops included, so the two cannot count apart: a context the audit leaves out contributes no window, and a context that could not reach the index has its cold windows classed `unreachable`, as the audit scores them.
    public func windows() -> [ScoredWindow] {
        let snapshot = TranscriptSnapshot(
            sessions: sessions.map { URL(fileURLWithPath: $0) },
            agents: subagents.mapValues { $0.map { URL(fileURLWithPath: $0) } },
            sizes: sizes,
            indexes: RunIndexState()
        )
        defer { snapshot.indexes.close() }
        let sweep = TranscriptAudit.sweep(
            snapshot,
            since: since.map(Date.init(timeIntervalSince1970:)),
            until: until.map(Date.init(timeIntervalSince1970:)),
            timeZone: .current,
            suppressionLog: suppressionLog.map { URL(fileURLWithPath: $0) },
            suppressionLogSize: suppressionLogSize,
            keepsWindows: true
        )
        return sweep.active.flatMap { scan in
            let id = TranscriptSnapshot.id(of: URL(fileURLWithPath: scan.session))
            let unreachable = scan.tally.couldNotReachTheIndex
            return scan.windows.map { window in
                var keyed = window
                keyed.session = id
                if unreachable, keyed.classification == "cold" {
                    keyed.classification = "unreachable"
                }
                return keyed
            }
        }
    }
}
