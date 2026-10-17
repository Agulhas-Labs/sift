//
// Copyright © Agulhas Labs
//

import Foundation

/// The depth Swift Testing prints a `↳` expansion at, kept so a line from another test can be told from the failure's own.
///
/// Swift Testing prints a failed expectation's expansions as a tree: the whole expression unindented, and each subexpression two spaces deeper per level. Under a parallel run another test's whole expression can land inside a failure's block, and only its depth, back at the left edge, says it is not one of this failure's reads.
struct RunExpansionDepth {
    /// The whitespace between the `↳` of `line` and its text, less the one separating space; empty where `line` has no `↳` or no depth.
    static func printedIndent(of line: String) -> String {
        guard let marker = line.firstIndex(of: "↳") else {
            return ""
        }
        var after = line[line.index(after: marker)...]
        if after.first == " " {
            after = after.dropFirst()
        }
        return String(after.prefix { $0 == " " })
    }

    /// Whether a line of ``RunTestFailure/markedLines`` opens on a space, so it sits beneath a whole expression.
    static func isIndented(_ line: String) -> Bool {
        line.first == " "
    }

    /// Whether any of `lines` is indented, so that the lines carry their depth at all.
    ///
    /// The event stream trims every message and a unit fixture may write its lines flush, so an unindented line is evidence only where some other line of the same block is indented.
    static func areIndented(_ lines: ArraySlice<String>) -> Bool {
        lines.contains(where: isIndented)
    }
}
