//
// Copyright © Agulhas Labs
//

import Foundation

/// Whether this server's tools are in a context now, read off the transcript the harness keeps for it.
///
/// The MCP face can leave a session while the binary on disk goes on answering, and the harness writes that into the context's transcript: a tool-list change naming the server as failed, or taking its tools away, and another bringing them back if it returns. From the first until the second the context holds none of the tools a refusal names, and a refusal that goes on naming them costs a round trip for an instruction nothing in the context can follow. So where the transcript's latest word on this server is that it went away, a refusal names the CLI form instead (``IndexSuggestion/cliCall``), which the binary that refused the call answers from Bash.
///
/// Read whole on every refusal rather than cached, because a refusal is the rare path — a lookup the hook is about to interrupt — and what is read is a byte search for the one key every tool-list change carries, with only the few lines it lands on parsed.
public struct ServerPresence {
    /// The transcript holding the tool list of the context `agent` names: a subagent's own, under the session's `subagents/`, or the session's where there is no agent or no such file.
    ///
    /// A subagent's hook payload carries its parent's transcript path, and the parent's tool list is not the subagent's — an allowlist can leave the server out of one and not the other — so the subagent's own file is the one that answers for it.
    public static func transcript(ofSession sessionTranscript: String?, agent: String?) -> String? {
        guard let sessionTranscript, !sessionTranscript.isEmpty else { return nil }
        return subagentTranscript(ofSession: sessionTranscript, agent: agent) ?? sessionTranscript
    }

    /// The transcript holding the context `agent` names and no other: the session's where there is no agent, the subagent's own under the session's `subagents/` where that file is there, and `nil` where a subagent's is not — never the session's, which is its parent's context and not its own.
    public static func subagentTranscript(ofSession sessionTranscript: String?, agent: String?) -> String? {
        guard let sessionTranscript, !sessionTranscript.isEmpty else { return nil }
        guard let agent, !agent.isEmpty else { return sessionTranscript }
        let own = URL(fileURLWithPath: sessionTranscript)
            .deletingPathExtension()
            .appendingPathComponent("subagents", isDirectory: true)
            .appendingPathComponent("agent-\(agent).jsonl")
            .path
        return FileManager.default.fileExists(atPath: own) ? own : nil
    }

    /// Whether the context `agent` names in the session whose transcript is at `sessionTranscript` last recorded this server leaving it, read from the transcript that context writes (``ServerPresence``).
    public static func isGone(ofSession sessionTranscript: String?, agent: String?) -> Bool {
        isGone(inTranscript: transcript(ofSession: sessionTranscript, agent: agent))
    }

    /// Whether the transcript at `path` last recorded this server leaving the context — `false` where it recorded nothing about it, recorded it arriving again, or cannot be read.
    ///
    /// Silent is present: a transcript that never mentions the server is a context the hook knows nothing about, and naming the MCP tools there is what it has always done.
    public static func isGone(inTranscript path: String?) -> Bool {
        guard let path, let data = try? Data(contentsOf: URL(fileURLWithPath: path), options: .alwaysMapped) else {
            return false
        }
        let marker = Array(toolListMarker.utf8)
        var gone = false
        data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
            guard let base = buffer.baseAddress else { return }
            var offset = 0
            while offset < buffer.count, let hit = memmem(base + offset, buffer.count - offset, marker, marker.count) {
                let position = base.distance(to: hit)
                var start = position
                while start > 0, buffer[start - 1] != 0x0A {
                    start -= 1
                }
                var end = position + marker.count
                while end < buffer.count, buffer[end] != 0x0A {
                    end += 1
                }
                let line = Data(bytes: base + start, count: end - start)
                if let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                   let verdict = verdict(of: object)
                {
                    gone = verdict
                }
                offset = end + 1
            }
        }
        return gone
    }

    /// Whether this session's server is proven not to be running: the session transcript's latest word on it is that it went away, and no server the lifecycle log records is still running for this session — started with its id, or spawned by a process this one descends from.
    ///
    /// **Both halves, because each alone can say "absent" about a server that is there.** The log alone would: its session id goes stale after a `/clear`, a server pointed at another log by `SIFT_SERVER_LOG` writes none of its lines here, and a log trimmed past its cap can drop the start line of a server running for days. The transcript alone could too, in a way the log catches: a server that came back without the harness writing its tools back in. So a claim needs the harness to have written the server off *and* no live process to contradict it, and anything unreadable — no transcript, a transcript that never mentions the server — is not proof. The process tree is checked as well as the id because the host is an ancestor of both this process and its own server, whatever the session is called by now; a recorded parent that happens to be further up the tree only ever makes this say "not proven".
    ///
    /// Cheap enough for a hook that runs at every subagent's start: a byte search of the transcript first, and the log — a few hundred lines at most — read only when that search says the server went away.
    public static func isProvenAbsent(
        session: String?,
        transcript: String?,
        lifecycleLog: URL,
        callerTree: Set<Int32> = ServerRoster.processTree(),
        isRunning: (ServerLifecycleEntry) -> Bool = ServerLifecycleReport.isStillRunning
    ) -> Bool {
        guard isGone(inTranscript: transcript) else { return false }
        let entries = ServerLifecycleReport.entries(in: lifecycleLog)
        let live = ServerLifecycleReport.unclosedStarts(in: entries).filter(isRunning)
        return !live.contains { entry in
            if let session, !session.isEmpty, entry.session == session {
                return true
            }
            return entry.parent.map(callerTree.contains) ?? false
        }
    }

    /// What one transcript line says about this server: `true` for gone, `false` for present, `nil` for nothing.
    ///
    /// A change that brings any of its tools in says present, whatever else it lists; one naming the server among the failed ones, or taking any of its tools out, says gone — unless the same change also lists it under `pendingMcpServers`, which means it is still connecting: neither gone nor present, so a refusal keeps naming the MCP tools rather than sending a call the server is about to be able to answer anyway.
    static func verdict(of object: [String: Any]) -> Bool? {
        guard let attachment = object["attachment"] as? [String: Any] else { return nil }
        let names = { (key: String) in attachment[key] as? [String] ?? [] }
        let ours = { (name: String) in IndexToolName.tool(named: name) != nil }
        let namesTheServer = { (key: String) in
            (attachment[key] as? [[String: Any]] ?? []).contains { $0["name"] as? String == IndexToolName.server }
        }
        if (names("addedNames") + names("readdedNames")).contains(where: ours) {
            return false
        }
        if namesTheServer("pendingMcpServers") {
            return nil
        }
        return namesTheServer("failedMcpServers") || names("removedNames").contains(where: ours) ? true : nil
    }

    /// The key every tool-list change the harness writes carries, empty or not — the byte pre-filter this reads the transcript with.
    static var toolListMarker: String {
        #""addedNames""#
    }
}
