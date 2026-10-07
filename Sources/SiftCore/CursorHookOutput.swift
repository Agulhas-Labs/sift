//
// Copyright © Agulhas Labs
//

import Foundation

/// What a hook registered with `--agent cursor` prints, in Cursor's response schema.
///
/// `nil` wherever the object cannot be encoded, as ``HookOutput``'s are: on Cursor a response that does not match the schema can block the call, and silence lets it run.
public struct CursorHookOutput {
    /// What to print so a `preToolUse` hook refuses the call with `message`.
    ///
    /// The model reads `user_message` as the rejection reason, followed by Cursor's own line asking it not to work around the block; `agent_message` was never delivered to the model in a probe of the Cursor CLI. So the message goes in `user_message`, and in `agent_message` as well for whichever build does deliver it.
    public static func preToolUseDenial(message: String) -> String? {
        encoded(["permission": "deny", "user_message": message, "agent_message": message])
    }

    /// What to print so a `preToolUse` hook runs the call with `input`, the whole tool input and not a delta, instead of the one it was made with.
    ///
    /// No `permission`, as with ``HookOutput/preToolUseAmendment(input:)``: the correction does not approve the call.
    public static func preToolUseAmendment(input: [String: Any]) -> String? {
        encoded(["updated_input": input])
    }

    /// What to print so a `sessionStart` or `postToolUse` hook hands `context` to the model.
    ///
    /// One field for both events, `additional_context`: a probe of the Cursor CLI saw the model quote it back from each, a `postToolUse` one arriving as a system reminder after the call's result. The `env` a `sessionStart` hook may also return is not used.
    public static func additionalContext(_ context: String) -> String? {
        encoded(["additional_context": context])
    }

    private static func encoded(_ object: [String: Any]) -> String? {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
        else {
            return nil
        }
        return String(bytes: data, encoding: .utf8)
    }
}
