//
// Copyright © Agulhas Labs
//

/// The one line a paged answer prints in place of its page when the caller's offset is at or beyond the last item.
///
/// A bare "skipped" note under an empty page reads as an answer, and an offset carried over from another query is how a caller gets there; this line says the page is empty because of the offset.
struct PastEndLine {
    /// Whether `offset` skips every one of `count` items, so the page is empty.
    static func applies(offset: Int, count: Int) -> Bool {
        offset > 0 && count > 0 && offset >= count
    }

    /// The line naming the offset, the count and the way back, with `noun` as the plural of what is counted ("matches", "files").
    static func text(offset: Int, count: Int, noun: String) -> String {
        "offset \(offset) is past the last of \(count) \(noun) — drop offset to see them"
    }
}
