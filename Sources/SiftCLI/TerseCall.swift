import Foundation
import SiftMCP

/// A call reduced to the one line `--verdict` prints.
struct TerseCall {
    /// A suggestion's call, reduced to the one line `--verdict` prints: multiple lines (one `where` per name of an alternation) joined rather than kept as written, since a probe's answer is one line and nothing else.
    ///
    /// A tab in the caller's own command — quoted in a `--filter` argument, say — would otherwise ride into the verdict line verbatim and shift `cut -f2`/`cut -f3` off the call and the rule they are documented to hold. Every control character that could do the same (a tab included) is folded to a space here, beside the newline fold above, so the line stays the single tab-delimited record `Docs/Design.md` promises.
    static func call(for suggestion: IndexSuggestion, serverGone: Bool) -> String {
        joining((serverGone ? suggestion.cliCall : suggestion.call).split(separator: "\n", omittingEmptySubsequences: true).map(String.init))
    }

    /// A single lookup's verdict line, with how many further calls the same answer also served beyond the one it names.
    ///
    /// A grep matching several declarations in one file is still one lookup, so its offer names only the first — but the digest handed back covers every match, not that one alone, and a probe reading the line as if it named the whole answer would believe the rest went unanswered.
    static func call(naming call: String, moreCalls: Int) -> String {
        guard moreCalls > 0 else { return call }
        return "\(call) (+\(moreCalls) more)"
    }

    /// Several calls — one `where` per name of an alternation, or several reads answered together — folded into the one line `--verdict` prints, exactly as a single call's own lines are.
    ///
    /// Shared with the single-call overload above so a multi-read verdict line folds the same control characters and never skips the fold a probe's `cut -f2`/`cut -f3` relies on.
    static func joining(_ lines: [String]) -> String {
        let joined = lines.joined(separator: "; ")
        return String(joined.map { character -> Character in
            character.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) } ? " " : character
        })
    }
}
