//
// Copyright © Agulhas Labs
//

import Foundation

/// Which conversation a piece of advice belongs to — the parent session, or one subagent inside it.
///
/// A subagent's hook payload carries its *parent's* `session_id`: a sidechain transcript records its own `agentId`, `isSidechain: true`, and a `sessionId` that is the parent's. Keying the advice ledger on that alone makes every subagent share the parent's budget — and the parent's quiet spell with it, so a parent that had waved off a run of suggestions would spawn subagents that were mute before their first tool call.
///
/// The `agent_id` payload field is the discriminator. The transcript path looks like one, on the docs' claim that a hook is pointed at the transcript of the context it fired in — but a subagent's `PreToolUse` payload can carry the *parent's* transcript path, with `agent_id`/`agent_type` present exactly and only for subagent calls. Keyed on the path alone, such a host writes not one agent-keyed ledger file, so the path sniff is kept solely as a fallback for versions where it does discriminate.
public struct AdviceContext: Equatable, Sendable {
    /// What the ledger is keyed on.
    public let key: String
    /// Whether this is a subagent rather than the session itself.
    public let isSubagent: Bool

    /// The context a hook payload is speaking for.
    ///
    /// Falls back to the session id whenever neither discriminator is present — one ledger for the whole session. That matters more than being clever here: a payload shape that changes under us degrades to one shared budget rather than to a key that changes per call, which would make every command a first sighting and refuse all of them.
    public static func resolve(sessionID: String, transcriptPath: String?, agentID: String? = nil) -> AdviceContext {
        if let agentID, !agentID.isEmpty {
            // The same `agent-` spelling the transcript filenames use, so a ledger file remains traceable
            // to the `subagents/agent-<id>.jsonl` it speaks for whichever discriminator produced it.
            return AdviceContext(key: "\(sessionID)-agent-\(agentID)", isSubagent: true)
        }
        guard let transcriptPath, !transcriptPath.isEmpty else {
            return AdviceContext(key: sessionID, isSubagent: false)
        }
        let name = URL(fileURLWithPath: transcriptPath).deletingPathExtension().lastPathComponent
        guard name.hasPrefix("agent-"), name.count > "agent-".count else {
            return AdviceContext(key: sessionID, isSubagent: false)
        }
        // Qualified by the session so two runs that reuse an agent id cannot share a ledger, and so the
        // file is traceable back to the conversation it came from.
        return AdviceContext(key: "\(sessionID)-\(name)", isSubagent: true)
    }
}
