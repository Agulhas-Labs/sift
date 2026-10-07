//
// Copyright © Agulhas Labs
//

import Foundation

/// The advice hook as `audit --replay` drives it: the transcript's calls handed over in order, one context at a time, so what the hook reads about a context is only what that context's transcript shows.
public protocol ReplayHook {
    /// The hook's decision on one call, given the payload the harness would have sent with `cwd` already mapped to a directory on disk, or `nil` for a tool the hook is not registered for.
    ///
    /// `decides` is false for a call before `--since`: a lookup is still judged, so a denial, an in-place answer's digests, and a nudge all land the way the live hook would land them, but the verdict handed back is `outsideWindow` rather than what the judgment found, so a call outside the window is never itself counted.
    ///
    /// A call at or after `--until` is never handed over at all: nothing it lands on the ledger can reach a call inside the window.
    func verdict(payload: [String: Any], cwd: String, at instant: Date?, decides: Bool) -> ReplayVerdict?

    /// Records that an index call this context made came back answered, which is the moment a digest starts excusing a later whole read, and a `where` or `search` answer starts locating the files it listed.
    ///
    /// `payload` carries the answer's text under ``TranscriptReplay/answerKey``.
    func answered(payload: [String: Any], cwd: String, at instant: Date?)

    /// Whether the file at `path` is located for the context `payload` speaks for only by digests the hook answered in place during this replay, and by none of the index calls the context itself made.
    func locatedOnlyByAnswers(_ path: String, payload: [String: Any]) -> Bool
}
