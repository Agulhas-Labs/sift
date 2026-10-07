//
// Copyright © Agulhas Labs
//

import Foundation

/// What a refused call looked like, captured at the moment it was refused — enough to classify its shape, recognise an identical re-run, and print it back verbatim (redacted) if it lands among the ones a lone re-run followed.
///
/// Held on ``PendingRead`` from the moment the call is made, since the classification the hook applied is gone by the time a refusal is confirmed — only the call's own arguments say what it was asked for.
public struct RefusedCallShape: Sendable, Equatable, Codable {
    /// The tool this was, named the way `LookupTool.rule(for:)` names it: `Read`, `Grep`, `Glob`, `Bash`.
    public let tool: String

    /// The call exactly as it will be shown if listed — verbatim, before redaction.
    public let text: String

    /// The shape this call was judged to be, decided once here rather than re-derived from `text` at render time: `text` is a display string built to be readable, not a canonical one a classifier should parse.
    public let kind: RefusalShape

    /// The identity a re-run is matched against.
    ///
    /// `text` by default, since for `Read` and `Bash` the display string already carries everything that makes one call identical to another. `Grep`/`Glob` override it with the call's whole input in canonical form, because their display text carries only `pattern`/`path`/`glob`/`type`, and a follow-up that changes anything else — `-i`, `output_mode`, `-A`/`-C`, `multiline`, `head_limit` — is a different call that happens to print the same.
    public let key: String

    public init(tool: String, text: String, kind: RefusalShape, key: String? = nil) {
        self.tool = tool
        self.text = text
        self.kind = kind
        self.key = key ?? text
    }
}
