//
// Copyright © Agulhas Labs
//

/// A `sift run` answer's `totals:` line, with whether every tool tally it states was read and summed.
///
/// The flag is taken from the tallies, not from the words: a lone tally that will not parse is stated `counter 1 unreadable` with no `not summed` beside it, so a reader of the line cannot tell it from a summed one by searching the text. ``RunReportRenderer/shown(_:of:beside:)`` drops the tool's own lines only where this is `true`.
struct RunTotals: Equatable {
    /// The line as printed.
    let line: String

    /// `true` where every Swift Testing tally and XCTest counter the line states was parsed, so each number in it is the tool's own count or a sum of them.
    let everyTallySummed: Bool
}
