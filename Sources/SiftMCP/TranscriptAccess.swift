//
// Copyright © Agulhas Labs
//

import Foundation
import SiftCore

/// What a transcript line says about the context's access to the index rather than about a lookup: the tool list the harness recorded for it, a server it reported failing, and a session-start hook that could not run the binary.
///
/// Apart from ``TranscriptScan`` because none of it classifies a lookup. It only advances the facts about the whole context that ``TranscriptTally/couldNotReachTheIndex`` and the audit's causes are read from.
struct TranscriptAccess {
    /// Advances `state` by whatever `object` records about the context's access; a line recording none of it leaves `state` as it was.
    static func note(_ object: [String: Any], in state: inout TranscriptScanState) {
        if reportsServerFailure(object) {
            state.serverFailed = true
        }
        noteToolList(object, in: &state)
        if recordsMissingBinary(object) {
            state.binaryMissingAtStart = true
        }
    }

    /// Advances `state` by whatever the raw transcript `line` records about the context's access, parsing it only where it names one of those records.
    ///
    /// For a reader that has stopped classifying a transcript's lines but still owes the context the access facts it reads from the whole transcript.
    static func note(line: Data, in state: inout TranscriptScanState) {
        guard markers.contains(where: { line.range(of: $0) != nil }),
              let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any]
        else {
            return
        }
        note(object, in: &state)
    }

    /// Every record ``note(_:in:)`` reads names one of these, as a key or a value that key-value spacing cannot change.
    private static let markers: [Data] = [
        "\"failedMcpServers\"", "\"prompt_snapshot\"", "\"deferred_tools_delta\"", "\"hook_non_blocking_error\"",
    ].map { Data($0.utf8) }

    /// Whether a transcript line is the harness reporting this server as failed — it did not start, or its connection dropped.
    ///
    /// The harness writes that into the transcript as a tool-list change naming the servers that failed (`failedMcpServers`), on the context whose tool list it is. It is the one record of *why* a context held none of this server's tools that does not have to be inferred, and it points somewhere quite different from an agent definition that left the tools out.
    private static func reportsServerFailure(_ object: [String: Any]) -> Bool {
        guard let attachment = object["attachment"] as? [String: Any],
              let failed = attachment["failedMcpServers"] as? [[String: Any]]
        else {
            return false
        }
        return failed.contains { $0["name"] as? String == IndexToolName.server }
    }

    /// Records what a transcript line says about the context's tool list: whether it listed the tools at all, whether it held some back, and whether any of this server's tools were among them.
    ///
    /// Both records are read, because the harness keeps the two kinds of tool in different places. A tool sent in full with every request is listed in the `prompt_snapshot`; a deferred one — which is how this server's tools usually reach a context, loaded on demand through a tool search — never appears in the snapshot at all, only among a `deferred_tools_delta`'s `addedNames` (or its `readdedNames`, when it comes back). A context that called `mcp__sift__digest` ten times can have snapshots that name none of them, so reading the snapshot alone would count it as never having held the tools. The snapshot says which case it is in: it offers `ToolSearch` only when something is held back.
    ///
    /// Read independently of ``reportsServerFailure(_:)`` and of every call the context goes on to make. Each flag it sets can only ever go from `false` to `true`, so a later line never unsays an earlier one; whether the list was recorded whole and sift was missing from it is decided from all of them together, when it is asked (``TranscriptScanState/recordedToolListWithoutIndex``).
    private static func noteToolList(_ object: [String: Any], in state: inout TranscriptScanState) {
        guard let attachment = object["attachment"] as? [String: Any] else { return }
        let names: [String]
        switch attachment["type"] as? String {
        case "prompt_snapshot":
            guard let tools = attachment["tools"] as? [[String: Any]] else { return }
            names = tools.compactMap { $0["name"] as? String }
            state.listedTools = true
            if names.contains(toolSearch) {
                state.offeredDeferredTools = true
            }
        case "deferred_tools_delta":
            names = (attachment["addedNames"] as? [String] ?? []) + (attachment["readdedNames"] as? [String] ?? [])
            state.listedDeferredTools = true
        default:
            return
        }
        if names.contains(where: { IndexToolName.tool(named: $0) != nil }) {
            state.heldIndexTools = true
        }
    }

    /// The harness's tool for loading a held-back tool on demand, which a context is given only when it has tools held back.
    private static var toolSearch: String {
        "ToolSearch"
    }

    /// Whether a transcript line is the harness recording this tool's `session-start` hook failing at a genuine session start — `startup` or `resume` — because the shell could not find the binary: exit status 127, the shell's own "command not found".
    ///
    /// Matched on the registration's shape (``HookRegistration/isOurs(_:subcommand:)``) and the exit status, never on the wording of the shell's message. A 127 from any other hook says nothing about this binary, and one from `SubagentStart` says only that the binary was missing when that subagent began — the server may have been running since long before. `SessionStart` fires for `clear` and `compact` too, where no server is launched at all, so a 127 there says nothing about whether the binary is missing — only `startup` and `resume` name a moment the server was supposed to come up.
    private static func recordsMissingBinary(_ object: [String: Any]) -> Bool {
        guard let attachment = object["attachment"] as? [String: Any],
              attachment["type"] as? String == "hook_non_blocking_error",
              attachment["hookEvent"] as? String == "SessionStart",
              attachment["exitCode"] as? Int == 127,
              let source = sessionStartSource(attachment),
              source == "startup" || source == "resume"
        else {
            return false
        }
        return HookRegistration.isOurs(attachment["command"] as? String)
    }

    /// The `SessionStart` source a record names — a `source` field if it carries one, otherwise the suffix of `hookName` (`"SessionStart:<source>"`, the shape the harness actually writes).
    ///
    /// `nil` when neither is present, which this hook then treats as not a genuine start.
    private static func sessionStartSource(_ attachment: [String: Any]) -> String? {
        if let source = attachment["source"] as? String {
            return source
        }
        guard let hookName = attachment["hookName"] as? String, hookName.hasPrefix("SessionStart:") else {
            return nil
        }
        return String(hookName.dropFirst("SessionStart:".count))
    }
}
