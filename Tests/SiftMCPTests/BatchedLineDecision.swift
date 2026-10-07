//
// Copyright © Agulhas Labs
//

/// What the hook printed for a line, its `--verdict` line, and the withholdings its suppression log recorded against the call.
struct BatchedLineDecision {
    let json: String?
    let verdict: String
    let logged: [String]
}
