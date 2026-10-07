//
// Copyright © Agulhas Labs
//

import Foundation
import SiftCore

/// The session transcripts an audit reads, their subagents, and each one's size, fixed once so the audit and its replay read the same bytes however the live files grow.
///
/// A live session keeps appending to its transcript while the audit runs, and the replay is a second pass over the same files that comes minutes later: read afresh, it would count lookups the audit never saw, and the audit's own share it prints beside the replayed one would not be the audit's.
public struct TranscriptSnapshot: Sendable {
    /// The session transcripts in the window, in the order both passes read them.
    let sessions: [URL]
    /// Each session's subagent transcripts, by the session's path.
    let agents: [String: [URL]]
    /// Each transcript's size in bytes when the snapshot was taken, by path.
    let sizes: [String: Int]
    /// Each transcript's modification date, read by the same stat as its size, by path — the tally cache's key beside the size.
    var modified: [String: Date] = [:]
    /// The parent session's id, by transcript id, of each subagent a scope promoted to a session of its own.
    var promoted: [String: String] = [:]
    /// This machine's indexes as the run first reads them, so the audit, its scan and its replay's hook judge every name against one state.
    public let indexes: RunIndexState

    /// `transcript` alone where one is named, otherwise every session under `projectsDirectory` last written on or after `since`, each with its subagents and every file's size now.
    ///
    /// `indexes` is injectable for tests; the default reads this machine's registered roots.
    public static func take(projectsDirectory: URL, since: Date?, transcript: String?, indexes: RunIndexState = RunIndexState()) -> TranscriptSnapshot {
        let sessions = (transcript.map { [URL(fileURLWithPath: $0)] } ?? TranscriptAudit.sessionTranscripts(under: projectsDirectory))
            .filter { url in
                guard let since else { return true }
                return TranscriptAudit.modificationDate(of: url).map { $0 >= since } ?? false
            }
        var agents: [String: [URL]] = [:]
        var sizes: [String: Int] = [:]
        var modified: [String: Date] = [:]
        for session in sessions {
            let found = TranscriptAudit.subagentTranscripts(of: session)
            agents[session.path] = found
            for url in [session] + found {
                let values = try? url.resolvingSymlinksInPath().resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
                sizes[url.path] = values?.fileSize
                modified[url.path] = values?.contentModificationDate
            }
        }
        return TranscriptSnapshot(sessions: sessions, agents: agents, sizes: sizes, modified: modified, indexes: indexes)
    }

    /// The snapshot narrowed to the transcripts the audit's `--root` keeps, each judged by its own recorded working directory as the sweep judges it.
    ///
    /// A subagent in scope under a session out of scope is promoted to a session of its own, which the scan reads as that agent of its parent, so every kept window keeps the session and call it has in the full snapshot.
    public func scoped(to root: String) -> TranscriptSnapshot {
        var kept: [URL] = []
        var keptAgentsByPath: [String: [URL]] = [:]
        var promoted: [String: String] = [:]
        for session in sessions {
            let keptAgents = subagents(of: session).filter { TranscriptAudit.inScope($0, root: root) }
            if TranscriptAudit.inScope(session, root: root) {
                kept.append(session)
                keptAgentsByPath[session.path] = keptAgents
            } else {
                for agent in keptAgents {
                    kept.append(agent)
                    keptAgentsByPath[agent.path] = []
                    if let parent = SubagentFile.identity(of: agent, home: NSHomeDirectory())?.session {
                        promoted[Self.id(of: agent)] = Self.id(of: URL(fileURLWithPath: parent))
                    }
                }
            }
        }
        return TranscriptSnapshot(sessions: kept, agents: keptAgentsByPath, sizes: sizes, modified: modified, promoted: promoted, indexes: indexes)
    }

    /// `windows`, another binary's scan of this snapshot, with each window of a promoted subagent that the binary keyed by the agent's own file name keyed by its parent session instead.
    ///
    /// A binary from before a subagent file was read as that agent of its parent keys a promoted transcript as a session called for its file, so left alone its windows would never join this build's, which keep the parent's id.
    public func attributing(_ windows: [ScoredWindow]) -> [ScoredWindow] {
        guard !promoted.isEmpty else { return windows }
        return windows.map { window in
            guard let parent = promoted[window.session] else { return window }
            var moved = window
            moved.session = parent
            return moved
        }
    }

    /// A transcript's id in a window's key: its file name without the extension.
    static func id(of url: URL) -> String {
        url.deletingPathExtension().lastPathComponent
    }

    /// The subagent transcripts `session` had when the snapshot was taken.
    func subagents(of session: URL) -> [URL] {
        agents[session.path] ?? []
    }

    /// The transcript at `url` as it stood when the snapshot was taken — its bytes up to the size recorded then — or nil where it cannot be read.
    func contents(of url: URL) -> Data? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        guard let size = sizes[url.path] else { return data }
        return data.prefix(size)
    }
}
