//
// Copyright © Agulhas Labs
//

import Foundation
import SiftCore
import SiftMCP

/// What the hook writes to the usage log about one call: a line for each call an answer given in place is made of, and a line taking an earlier answer back when the call reads anyway what that answer stood in for.
struct HookUsage {
    /// The call's payload, in Claude Code's form.
    let payload: [String: Any]
    /// The shell command a probe passed in place of the payload's.
    let command: String?
    let session: String?
    let context: AdviceContext
    let directory: String?
    let ledger: AdviceLedger
    let usage: UsageLog?

    /// Records each call of an answer given in place as the server would have recorded it, marked as the hook's and filed under the command's id, and notes in the ledger the reads it stood in for, so a later read of one anyway is matched back to it.
    ///
    /// A whole file intercepted carries the bytes one `Read` of it returns, which is what `usage` prices its saving against; only a file or a window intercepted is noted in the ledger, being the only answers a read anyway takes a saving back from.
    func record(_ answered: InPlaceAnswerer.Answered, resolvedNothing: Bool) {
        let call = payload["tool_use_id"] as? String
        for answer in answered.calls {
            usage?.record(
                tool: answer.tool,
                target: answer.target,
                root: answered.root,
                milliseconds: answered.milliseconds,
                succeeded: true,
                answer: answer.bytes,
                agent: payload["agent_id"] as? String,
                session: session,
                via: "hook",
                intercepted: answer.intercepted.rawValue,
                call: call,
                readBytes: answer.readBytes,
                // A `where` answered in place locates what it listed, as the server's own answer does.
                located: DigestedFiles.locatedFiles(inAnswer: answered.reason, tool: answer.tool),
                miss: answer.tool == "digest" && resolvedNothing
            )
        }
        guard let call else { return }
        let (toolName, input) = block
        ledger.noteAnswered(
            session: context.key,
            call: call,
            targets: answered.calls.filter { $0.intercepted != .other }.map(\.target),
            toolName: toolName,
            input: input,
            cwd: directory
        )
    }

    /// Writes a read-anyway line for each answer given in place earlier in this context that this call, let through, reads anyway: it re-runs the reading the answer stood in for, or reads its file whole.
    func noteReadAnyway() {
        let (toolName, input) = block
        for answered in ledger.readAnyway(session: context.key, toolName: toolName, input: input, cwd: directory) {
            usage?.recordReadAnyway(call: answered.call, target: answered.target, session: session, agent: payload["agent_id"] as? String)
        }
    }

    /// The tool and input of the call the hook is judging: the shell command a probe passed, or the payload's own.
    private var block: (toolName: String?, input: [String: Any]) {
        if let command {
            return ("Bash", ["command": command])
        }
        return (payload["tool_name"] as? String, payload["tool_input"] as? [String: Any] ?? [:])
    }
}
