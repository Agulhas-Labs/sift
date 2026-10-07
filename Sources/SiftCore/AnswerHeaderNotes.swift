//
// Copyright © Agulhas Labs
//

/// What the `answers` help topic says about two header lines whose wording is the same on every answer: the `clean` word standing for the movement fields, and the `mode:` line of a degraded answer.
///
/// A type of its own rather than more of ``HelpTopics``, whose file is at the line limit with every topic in it.
struct AnswerHeaderNotes {
    /// The two paragraphs, placed in the `answers` topic ahead of its account of `semantic:`.
    static var body: String {
        """
        **The header says `clean` where no Swift file has changed since `head:` and none failed to parse.** \
        `clean` stands for `dirty: 0  parse_errors: 0`, and is written only where both counts were measured \
        and are zero; any other state prints `dirty:` and `parse_errors:` as before, with the `dirty:` count \
        carrying a `(+N not in git status, …)` addendum where files were reparsed that git did not list.

        **The `mode:` line names how a `where` or `affected` answer was matched.** `syntactic` means \
        declarations come from syntax, and conformers (`where`) or tests (`affected`) are matched by \
        written name rather than resolved by the build; callers, overrides and references are not answered. \
        `syntactic + semantic` means the index store answered them. The clause after `syntactic` says why \
        the answer is syntactic: no store built for this tree, still warming (ask again shortly), found but \
        failed to open, `--syntactic` (semantic disabled), or `--at` (not consulted). For the worktree case, `sift help worktree-index` has the recipe and why the checkout's \
        store is not borrowed.
        """
    }
}
