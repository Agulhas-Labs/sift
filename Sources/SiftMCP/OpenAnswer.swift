//
// Copyright © Agulhas Labs
//

import Foundation

/// A call of this context that read one or more files, or an answer the hook gave to such a call, held by the tool call it was made at.
///
/// Held as a call while its result is awaited, so an in-place answer to it can be matched to the files it read, and held as an answer for ``AnswerThenRead/window`` calls from the first call of the turn after its own, so a whole read of its file, or the identical re-run of the call, in that span is paired with it.
struct OpenAnswer: Sendable, Equatable, Codable {
    /// The files the call read, spelled out in full wherever its working directory allows — one for an answer.
    var paths: [String]

    /// What a re-run of the call is recognised by, one for each of `paths` in its order: the file and the call's own reading of it (``AnswerThenRead``).
    var rereads: [String] = []

    /// The context's tool-call count at the call, itself included.
    var call: Int

    /// The assistant turn the call was made in, whose other calls went out before the answer was seen.
    var turn: String?

    /// The context's tool-call count at the first call of a later turn than the call's own, where the answer's span begins — `nil` until one is made.
    var opens: Int?

    /// Whether the call fell inside the scan's window, so its answer and any miss it becomes are reported.
    var counted: Bool

    /// What the answer handed back, `nil` while this is still a call awaiting its result.
    var shape: AnswerShape?

    /// The bytes of saving the answer's closing line claimed for this file.
    var saving = 0
}
