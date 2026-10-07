//
// Copyright © Agulhas Labs
//

/// How many lines a `head` or `tail` keeps: a number of them from its own end, or — a `tail` given `+N` — every line from the `N`th.
enum LineCount: Equatable {
    case lines(Int)
    case fromLine(Int)

    /// A count as written after the flag, or `nil` where it is not a plain number of lines.
    ///
    /// `tail`'s own reading of `+0` is `+1`: both start from the file's first line, so both print the whole file, and `+0` is modelled that way rather than as zero lines kept.
    init?(_ value: String) {
        if value.hasPrefix("+"), let line = Int(value.dropFirst()), line >= 0 {
            self = .fromLine(max(line, 1))
        } else if let lines = Int(value), lines >= 0 {
            self = .lines(lines)
        } else {
            return nil
        }
    }
}
