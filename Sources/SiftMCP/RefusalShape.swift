//
// Copyright © Agulhas Labs
//

import Foundation

/// The shape of a refused call, for the refusals a lone re-run followed — grouping them by what they were actually after, since a count alone says nothing about which of them a fix would touch.
///
/// First match wins, in the order the cases are checked below (`RefusedCallShape.kind`): a call can be more than one of these at once — a fixed-string search under `.build/` is both — and the earlier rule is the one worth fixing first.
public enum RefusalShape: String, Sendable, Equatable, Codable, CaseIterable {
    /// A pattern hunting for `<<<<<<<` or `>>>>>>>` — an unresolved merge, which no index records.
    case conflictMarkers = "conflict markers"

    /// A `git grep`, `git show` or `git log -p` naming another revision than the working tree.
    case anotherRevision = "another revision"

    /// A path outside what this index covers at all — under `.build/`, `DerivedData`, `checkouts/` or `/tmp`, by the one definition the hook and the scan read too (``SwiftTree/isOutsideIndexedSources(_:)``), judged against the call's own working directory.
    case outsideIndexedSources = "outside the indexed sources"

    /// `grep -F`, `fgrep`, or `--fixed-strings` — a literal search, not a pattern.
    case fixedString = "fixed string"

    /// A pattern with a space in it — prose, not an identifier.
    case phrase

    /// A pattern alternating between literal choices — `\|`, or `-E` with an unescaped `|`.
    case alternation

    /// A shell window: `sed -n`, `head`, `tail`, an `awk 'NR…'`.
    case shellWindow = "shell window"

    /// A whole-file read with nothing narrowing it — a `Read` with no `offset`/`limit`, or a `cat` of one file.
    case wholeFileRead = "whole-file read"

    /// None of the above.
    case other
}
