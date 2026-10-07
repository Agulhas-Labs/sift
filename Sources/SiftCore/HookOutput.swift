//
// Copyright © Agulhas Labs
//

import Foundation

/// Formats the primer for whichever hook is asking for it.
///
/// Two events deliver it and they take it differently. `SessionStart` injects a hook's stdout into the session directly, so plain text is both what it wants and what makes the command readable when run by hand. `SubagentStart` reads its context out of a JSON payload instead, so the same primer has to be wrapped to arrive at all.
public struct HookOutput {
    /// What to print so `context` reaches the model, for a hook firing on `event`.
    ///
    /// An unrecognised or absent event falls back to plain text. That is the right default because the most likely caller with no event is a person running `sift session-start` in a terminal, and because a printed primer is harmless where a JSON envelope would be noise.
    public static func render(_ context: String, event: String?) -> String {
        guard event == "SubagentStart" else { return context }

        let payload: [String: Any] = [
            "hookSpecificOutput": [
                "hookEventName": "SubagentStart",
                "additionalContext": context,
            ],
        ]
        guard let data = try? JSONSerialization.data(
            withJSONObject: payload,
            options: [.sortedKeys, .withoutEscapingSlashes]
        ), let text = String(bytes: data, encoding: .utf8) else {
            // Encoding cannot realistically fail on a string, but if it did, the primer as bare text is a
            // better outcome than a subagent that gets nothing.
            return context
        }
        return text
    }

    /// What to print so a `PreToolUse` hook refuses the call with `reason`, or `nil` if it cannot be encoded.
    ///
    /// `nil` rather than a fallback string, unlike the primer above: a hook that prints something a `PreToolUse` consumer cannot parse is worse than one that prints nothing, because the thing being decided is whether a tool call happens. Silence means the call proceeds, which is the safe direction.
    ///
    /// Only `permissionDecision` is set. `additionalContext` would arrive *alongside* the command's own output, and a model already holding the answer has no reason to go back for a better one — which is exactly how an advisory delivery fails.
    public static func preToolUseDenial(reason: String) -> String? {
        let payload: [String: Any] = [
            "hookSpecificOutput": [
                "hookEventName": "PreToolUse",
                "permissionDecision": "deny",
                "permissionDecisionReason": reason,
            ],
        ]
        guard let data = try? JSONSerialization.data(
            withJSONObject: payload,
            options: [.sortedKeys, .withoutEscapingSlashes]
        ) else {
            return nil
        }
        return String(bytes: data, encoding: .utf8)
    }

    /// What to print so a `PreToolUse` hook runs the call with `input` instead of the input it was made with, or `nil` if it cannot be encoded.
    ///
    /// **No `permissionDecision`, deliberately.** `updatedInput` is honoured on its own, and the call still goes through whatever permission flow it would have gone through — so a hook that only wanted to add an argument does not also grant the call. Saying `"allow"` here would turn a correction into a blanket approval of every call this server ever sees, which is a much larger thing than the one it is fixing.
    ///
    /// `input` is the **whole** input the call should run with, not the delta: the merge semantics of a partial object are not something this can pin from outside, and sending the complete object is correct under either reading.
    public static func preToolUseAmendment(input: [String: Any]) -> String? {
        let payload: [String: Any] = [
            "hookSpecificOutput": [
                "hookEventName": "PreToolUse",
                "updatedInput": input,
            ],
        ]
        guard JSONSerialization.isValidJSONObject(payload),
              let data = try? JSONSerialization.data(
                  withJSONObject: payload,
                  options: [.sortedKeys, .withoutEscapingSlashes]
              )
        else {
            return nil
        }
        return String(bytes: data, encoding: .utf8)
    }

    /// What to print so a `PreToolUse` hook lets the call run and hands `context` to the model beside its result, or `nil` if it cannot be encoded.
    ///
    /// **No `permissionDecision`, deliberately.** The note only informs: the call goes through whatever permission flow it would have gone through, so a hook that wanted to say a word about the next line does not also approve this one on the user's behalf.
    public static func preToolUseContext(_ context: String) -> String? {
        additionalContext(context, event: "PreToolUse")
    }

    /// The envelope that carries `context` to the model for `event`, and nothing that decides the call.
    private static func additionalContext(_ context: String, event: String) -> String? {
        let payload: [String: Any] = [
            "hookSpecificOutput": [
                "hookEventName": event,
                "additionalContext": context,
            ],
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys, .withoutEscapingSlashes]) else {
            return nil
        }
        return String(bytes: data, encoding: .utf8)
    }

    /// What to print so a `PostToolUse` hook hands `context` to the model, or `nil` if it cannot be encoded.
    ///
    /// The JSON envelope and not plain text: a `PostToolUse` hook's plain stdout reaches the transcript view, never the model.
    public static func postToolUseContext(_ context: String) -> String? {
        additionalContext(context, event: "PostToolUse")
    }

    /// What to print so a `PostToolUse` hook blocks on the edit just made, handing `reason` to the model as feedback on it, or `nil` if it cannot be encoded.
    ///
    /// The edit has already landed, so nothing is undone: Claude Code shows `reason` to the model in place of a plain success, which is what makes it fix the file on the next turn rather than several edits later.
    public static func postToolUseBlock(reason: String) -> String? {
        decisionBlock(reason: reason)
    }

    /// What to print so a `Stop` or `SubagentStop` hook keeps the context working, handing it `reason` as what to do next, or `nil` if it cannot be encoded.
    ///
    /// One envelope for both events: Claude Code reads the same `decision` and `reason` from either, and a context sent back carries on from `reason` rather than ending its turn.
    public static func stopBlock(reason: String) -> String? {
        decisionBlock(reason: reason)
    }

    /// The top-level `decision: block` envelope the `PostToolUse`, `Stop` and `SubagentStop` events share.
    private static func decisionBlock(reason: String) -> String? {
        let payload: [String: Any] = ["decision": "block", "reason": reason]
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys, .withoutEscapingSlashes]) else {
            return nil
        }
        return String(bytes: data, encoding: .utf8)
    }
}
