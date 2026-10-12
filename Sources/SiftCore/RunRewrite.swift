//
// Copyright © Agulhas Labs
//

import Foundation

/// What tells the model a build was rewritten in place by the `PreToolUse` hook to `sift run -- …`: the note the hook hands it, and the line an older hook's mark makes `sift run` open its answer with.
///
/// The model reads its own command in the tool call and only `sift run`'s answer in the result, so without a note nothing tells it the command was replaced, or how to get the raw log it may have wanted (Docs/Design.md §1: the rewrite is made in the open). A `sift run` anyone typed finds no mark and prints nothing new.
///
/// **The mark is not on the rewritten line.** The hook carries the note in the `additionalContext` of the same output that replaces the command, where no `sift` the shell resolves can reject it and no allow rule can fail to match it: any word on the line would reach whichever `sift` the shell finds, possibly an older build that rejects it, and the allow rules `install-hook` writes (``RunAllowRules``) match the text from `sift run -- ` into the build's own words, so a word before the wrapped command, even an environment assignment, would stop them matching and turn the rewrite into a prompt. ``marker`` is the word earlier hooks appended as the wrapped command's last word; `sift run` still takes it off and treats it as the mark, so a line such a hook rewrote still prints the notice.
public struct RunRewrite {
    /// The word earlier hooks appended to the first statement they wrapped, still accepted so their lines print the notice.
    public static var marker: String {
        "--sift-rewritten"
    }

    /// The notice for the command `original` as its words: that the hook rewrote it, and the exact original command whose piped run, which the hook lets through as written, is the only way to the raw output; the full log is on the answer's `raw:` line.
    public static func notice(for original: [String]) -> String {
        notice(forCommand: original.map(ShellWord.quoted).joined(separator: " "))
    }

    /// The notice for the command written as `original`, in the spelling its author gave it.
    public static func notice(forCommand original: String) -> String {
        "sift: the hook rewrote this to `sift run -- …`. Raw output comes from `\(original) 2>&1 | cat`; full log on the `raw:` line."
    }

    /// `arguments` with the hook's mark taken off its end, and whether it was there.
    public static func unmarked(_ arguments: [String]) -> (arguments: [String], rewritten: Bool) {
        guard arguments.last == marker else { return (arguments, false) }
        return (Array(arguments.dropLast()), true)
    }
}
