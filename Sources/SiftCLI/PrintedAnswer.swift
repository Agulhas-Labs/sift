//
// Copyright © Agulhas Labs
//

import Foundation
import SiftMCP

/// What the `pre-tool-use` hook is about to print, recorded where it is an answer in place.
struct PrintedAnswer {
    /// The output to print, after recording it in the answered log and as a marker where it is an answer in place.
    ///
    /// Asked of the outcome that is printed rather than of the one built, and before it is printed, so a result the harness delivers is never ahead of the record that it was an answer. A denial or amendment that is no answer, a withheld answer and a call the harness gave no id for have nothing to name in the log, and a probe (`--verdict`) prints nothing and never reaches here.
    static func recorded(_ outcome: (json: String?, verdict: PreToolUseCommand.Verdict), payload: [String: Any], in log: AnsweredLog = .standard()) -> String? {
        guard let json = outcome.json, outcome.verdict.token == "in-place",
              let call = payload["tool_use_id"] as? String, !call.isEmpty,
              let reason = outcome.verdict.reason
        else { return outcome.json }
        log.note(call: call, opening: String(reason.prefix { $0 != "\n" }))
        return json
    }
}
