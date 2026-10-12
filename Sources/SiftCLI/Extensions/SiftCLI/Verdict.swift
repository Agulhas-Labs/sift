//
// Copyright © Agulhas Labs
//

extension PreToolUseCommand {
    /// The terse fact `--verdict` prints about a decision already made: the token, the call offered (when one was), and the rule that decided it — one line, tab-separated, nothing else.
    ///
    /// The token set and the separator are documented in `Docs/Design.md`, which a gate quotes.
    struct Verdict {
        let token: String
        var call: String?
        var rule: String?
        /// The denial's reason text, exactly as handed to ``HookOutput/preToolUseDenial(reason:)`` — the answer an in-place denial or a bare deny gives, unset for an allow.
        var reason: String?

        init(token: String, call: String? = nil, rule: String? = nil, reason: String? = nil) {
            self.token = token
            self.call = call
            self.rule = rule
            self.reason = reason
        }

        /// The token alone where neither a call nor a rule is known, and otherwise the fields up to the last one that is — tab-separated, empty where a later field is known and an earlier one is not.
        ///
        /// A field keeps its position whatever is missing, so `cut -f2` is always the call and `cut -f3` always the rule: an `allowed` with a rule and no call is `allowed\t\tledger`, never `allowed\tledger`, which would read as a call named `ledger`. Nothing ever ends in a tab.
        var line: String {
            guard call != nil || rule != nil else { return token }
            guard let rule else { return "\(token)\t\(call ?? "")" }
            return "\(token)\t\(call ?? "")\t\(rule)"
        }
    }
}
