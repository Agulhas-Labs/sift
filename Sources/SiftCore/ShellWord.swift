//
// Copyright © Agulhas Labs
//

import Foundation

/// A word as a POSIX shell reads it back, for a command an answer hands its reader to run.
public struct ShellWord: Sendable {
    private init() {}
}

public extension ShellWord {
    /// `word` as one shell word: unchanged where it holds only ASCII letters, digits and `_./+-:`, single-quoted otherwise.
    ///
    /// Judged and rewritten by unicode scalar, never by `Character`: a `'` followed by a combining mark is one `Character` that is not `'`, and a shell reads the quote all the same.
    static func quoted(_ word: String) -> String {
        guard word.unicodeScalars.contains(where: { !isSafe($0) }) else { return word }
        var result = "'"
        for scalar in word.unicodeScalars {
            if scalar == "'" {
                result.unicodeScalars.append(contentsOf: #"'\''"#.unicodeScalars)
            } else {
                result.unicodeScalars.append(scalar)
            }
        }
        result.append("'")
        return result
    }

    private static func isSafe(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar {
        case "a" ... "z", "A" ... "Z", "0" ... "9", "_", ".", "/", "+", "-", ":": true
        default: false
        }
    }
}
