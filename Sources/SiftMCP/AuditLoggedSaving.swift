//
// Copyright © Agulhas Labs
//

import Foundation

/// The usage log's saving as `audit` states it beside the share: gross, over the audit's own window and repository.
struct AuditLoggedSaving {
    /// The usage log narrowed to the audit's window and repository, whose ``UsageScan/savings`` is the saving stated gross (the reads the hook intercepted and answered in place) and whose ``UsageScan/markdown`` is the outlines beside it, or `nil` where the log cannot be read.
    ///
    /// Gross because it is: the log prices each answer when it is served and never sees what the context read next, and a join between a transcript's call and its log line was tried and could not be shown right (Docs/Design.md). The whole reads after a digest are counted beside it instead, never priced.
    ///
    /// `includeScratch` is as it is for `usage`: with it `false` the calls against scratch roots are not in the saving.
    ///
    /// `transcript` is the one session transcript an audit was narrowed to: the saving is then that session's own calls, matched on the log's `session` field by the transcript's file name, never the whole log under a figure the audit labels as its own.
    static func of(_ fileURL: URL, since: Date?, until: Date?, root: String?, transcript: String? = nil, includeScratch: Bool = true) -> UsageScan? {
        guard case let .success(scope) = LogScope.resolve(root, inLogsAt: [fileURL]),
              case let .success(scan) = UsageScan.load(fileURL: fileURL, scope: scope, includeScratch: includeScratch)
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
        )
    }

    /// The audit's `saving` row for the same figure: the gross saving, its baseline, and whether it is the window's or the one session's, then a row for the Markdown outlines the saving leaves out, or `nil` where the log holds neither.
    static func line(_ fileURL: URL, since: Date?, until: Date?, root: String?, transcript: String? = nil, includeScratch: Bool = true) -> String? {
        let scan = of(fileURL, since: since, until: until, root: root, transcript: transcript, includeScratch: includeScratch)
        let identity = transcript.map(Identity.init)
        let subject = transcript == nil ? "window" : "session"
        let markdown = scan?.markdown.map { "    markdown  \($0.note)" }
        let saving: String
        if let savings = scan?.savings, let savedText = savings.savedText, let savedBasis = savings.savedBasis {
            saving = "    saving    \(savedText), \(savedBasis): the \(savings.measured) intercepted read\(savings.measured == 1 ? "" : "s") the usage log priced for this \(subject)"
                + (markdown == nil ? "" : ", Markdown outlines apart")
        } else if markdown != nil {
            let whose = identity?.agent.map { "subagent \($0) of session \(identity?.session ?? "")" } ?? "this \(subject)"
            saving = "    saving    none: the usage log prices no call for \(whose), and holds Markdown outlines beside"
        } else if let identity, let agent = identity.agent {
            saving = "    saving    none: the usage log prices no call for subagent \(agent) of session \(identity.session)"
        } else {
            return nil
        }
        return [saving, markdown].compactMap(\.self).joined(separator: "\n")
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
