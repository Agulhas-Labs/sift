//
// Copyright © Agulhas Labs
//

import Foundation

/// The usage log's saving as `audit` states it beside the share: gross, over the audit's own window and repository.
struct AuditLoggedSaving {
    /// The usage log's saving over the audit's window and repository, stated gross: what every measured call in the log at `fileURL` claimed, or `nil` where the log holds none.
    ///
    /// Gross because it is: the log prices each answer when it is served and never sees what the context read next, and a join between a transcript's call and its log line was tried and could not be shown right (Docs/Design.md). The whole reads after a digest are counted beside it instead, never priced.
    ///
    /// `transcript` is the one session transcript an audit was narrowed to: the saving is then that session's own calls, matched on the log's `session` field by the transcript's file name, never the whole log under a figure the audit labels as its own.
    static func of(_ fileURL: URL, since: Date?, until: Date?, root: String?, transcript: String? = nil) -> UsageScan.Savings? {
        guard case let .success(scope) = LogScope.resolve(root, inLogsAt: [fileURL]),
              case let .success(scan) = UsageScan.load(fileURL: fileURL, scope: scope)
        else {
            return nil
        }
        let identity = transcript.map(Identity.init)
        let windowed = scan.entries.filter { entry in
            if let identity, entry.session != identity.session || (identity.agent != nil && entry.agent != identity.agent) {
                return false
            }
            guard let instant = TranscriptScan.instant(entry.stamp) else { return false }
            return (since.map { instant >= $0 } ?? true) && (until.map { instant < $0 } ?? true)
        }
        return UsageScan(
            entries: windowed,
            logged: scan.logged,
            malformed: scan.malformed,
            since: nil,
            resolvedRoot: scan.resolvedRoot,
            sweptSubtree: scan.sweptSubtree,
            scratchCalls: 0,
            cliLoggedSince: scan.cliLoggedSince
        ).savings
    }

    /// The audit's `saving` row for the same figure: the gross saving, its baseline, and whether it is the window's or the one session's, or `nil` where the log holds none.
    static func line(_ fileURL: URL, since: Date?, until: Date?, root: String?, transcript: String? = nil) -> String? {
        guard let saving = of(fileURL, since: since, until: until, root: root, transcript: transcript),
              let savedText = saving.savedText, let savedBasis = saving.savedBasis
        else {
            guard let identity = transcript.map(Identity.init), let agent = identity.agent else { return nil }
            return "    saving    none: the usage log holds no measured call for subagent \(agent) of session \(identity.session)"
        }
        return "    saving    \(savedText), \(savedBasis): every measured call the usage log holds for this \(transcript == nil ? "window" : "session")"
    }
}

extension AuditLoggedSaving {
    /// The session and, for a subagent transcript, the agent a `--transcript` path names: `<session>.jsonl`, or `<session>/subagents/agent-<id>.jsonl`, where the log files the subagent's calls under the parent's session and the bare id.
    struct Identity {
        let session: String
        let agent: String?

        init(path: String) {
            let url = URL(fileURLWithPath: path)
            let stem = url.deletingPathExtension().lastPathComponent
            let parent = url.deletingLastPathComponent()
            guard stem.hasPrefix("agent-"), parent.lastPathComponent == "subagents" else {
                session = stem
                agent = nil
                return
            }
            session = parent.deletingLastPathComponent().lastPathComponent
            agent = String(stem.dropFirst("agent-".count))
        }
    }
}
