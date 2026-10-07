//
// Copyright © Agulhas Labs
//

import Foundation

/// A subagent transcript named on its own: `<session>/subagents/agent-<id>.jsonl`.
///
/// Audited by itself (`--transcript`), it is that agent of its parent session, not a session called "agent-<id>".
struct SubagentFile {
    /// The parent session transcript's path and the label of agent `url` under it, or nil where `url` is not a subagent file.
    static func identity(of url: URL, home: String) -> (session: String, label: String)? {
        let directory = url.deletingLastPathComponent()
        guard url.lastPathComponent.hasPrefix("agent-"), directory.lastPathComponent == "subagents" else { return nil }
        let folder = directory.deletingLastPathComponent()
        let parent = folder.deletingLastPathComponent().appendingPathComponent(folder.lastPathComponent + ".jsonl")
        return (parent.path, TranscriptAudit.label(for: parent, home: home, agent: url))
    }
}
