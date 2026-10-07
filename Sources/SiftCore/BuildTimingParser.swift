//
// Copyright © Agulhas Labs
//

import Foundation

/// Reads the lines `-debug-time-function-bodies` and `-debug-time-expression-type-checking` print, and nothing else.
///
/// The shapes are the measured ones in Docs/Design.md, `build --analyse`: an expression is `<ms>ms`, a tab and `<path>:<line>:<column>`; a function body carries a third, tab-separated field describing the declaration. The line must open on the number, so a timing glued to the end of some other line is not read, and a location that is not `<path>:<line>:<column>` makes the line no timing at all.
public struct BuildTimingParser {
    /// The timing `line` carries, or `nil` when it is any other line of the build's output.
    public static func timing(in line: some StringProtocol) -> BuildTiming? {
        let fields = line.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
        guard fields.count >= 2, fields[0].hasSuffix("ms"),
              let milliseconds = Double(fields[0].dropLast(2)), milliseconds >= 0
        else {
            return nil
        }
        let location = fields[1].split(separator: ":", omittingEmptySubsequences: false)
        guard location.count >= 3,
              let lineNumber = Int(location[location.count - 2]), lineNumber > 0,
              let column = Int(location[location.count - 1].trimmingCharacters(in: .whitespacesAndNewlines)), column > 0
        else {
            return nil
        }
        let path = location.dropLast(2).joined(separator: ":")
        guard !path.isEmpty else {
            return nil
        }
        return BuildTiming(
            milliseconds: milliseconds,
            path: path,
            line: lineNumber,
            column: column,
            kind: fields.count == 3 ? .body : .expression,
            declarationDescription: fields.count == 3 ? String(fields[2]) : nil
        )
    }

    /// Every timing in a build's output, in the order it was printed.
    public static func timings(in output: String) -> [BuildTiming] {
        output.split(whereSeparator: \.isNewline).compactMap { timing(in: $0) }
    }
}
