//
// Copyright © Agulhas Labs
//

import Foundation

/// What followed a lone refusal — the next tool call in the same context, whichever it turned out to be, classified without regard to what that call itself went on to do.
///
/// Read off the *next* `tool_use` block the transcript writes after the refused one, wherever it falls — the same turn's round trip if that turn made a call, or a later one if it opened on text first.
///
/// A solo refusal with nothing after it in the transcript is ``ended``, never guessed at.
public enum RefusalFollowUp: Sendable, Equatable, Codable {
    /// The identical call, re-run — same tool, same input, so the refusal bought nothing.
    case reRun(shape: RefusalShape, call: String)

    /// An `mcp__sift__*` tool, or a Bash command invoking `sift digest`/`where`/`search`/`strings` — the refusal redirected.
    case index

    /// Anything else.
    case other

    /// No further tool call in this context — the transcript ends on the refusal's round trip.
    case ended
}
