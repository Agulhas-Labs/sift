//
// Copyright © Agulhas Labs
//

/// What the `answers` help topic says about two header lines whose wording is the same on every answer — the `clean` word standing for the movement fields, and the note a degraded `where` carries — and about the caveats no answer repeats (``StandingCaveats``), in full.
///
/// A type of its own rather than more of ``HelpTopics``, whose file is at the line limit with every topic in it.
struct AnswerHeaderNotes {
    /// The three paragraphs, placed in the `answers` topic ahead of its account of `semantic:`.
    static var body: String {
        """
        **The header says `clean` where no Swift file has changed since `head:` and none failed to parse.** \
        `clean` stands for `dirty: 0  parse_errors: 0`, and is written only where both counts were measured \
        and are zero; any other state prints `dirty:` and `parse_errors:` as before, with the `dirty:` count \
        carrying a `(+N not in git status, …)` addendum where files were reparsed that git did not list.

        **A `where` the store did not answer says so in one note under its header.** Where the store's \
        relations are withheld, the note names why (no store built for this tree, still warming — ask again \
        shortly —, found but failed to open, `--syntactic`, or `--at`), what was withheld (callers, overrides \
        and references; uses, for a type), and the remedy; it says `sites by written name` only where a list \
        matched that way follows. A `where` the store answered carries no note. A `stores:` note appears only \
        when more than one store answered, one is still loading, or a setting was passed over. `affected` keeps \
        its `mode:` line: `syntactic` means tests are matched by written name, `syntactic + semantic` that the \
        index store resolved them. For the worktree case, `sift help worktree-index` has the recipe and why the \
        checkout's store is not borrowed.

        **What every answer leaves unsaid, said here once.** \(StandingCaveats.sentences) In full: the index \
        store holds the code occurrences of this repository's own build, so a sibling repo or an uncompiled target \
        has none here — check those before deleting; a comment or a string is not a missing occurrence, and \
        `where --refs` lists them under `not code`. The store records no read, write or use made by a synthesized \
        conformance (Equatable, Hashable, Codable; for a case CaseIterable and a raw value's init(rawValue:)) or \
        by name at runtime, so a short or empty list of a property's reads and writes or a case's uses is not \
        proof it is unused. `search` is a syntactic shape match over the working tree, never stale and never \
        refusing; its `calls:` and `uses:` match written names, not resolved symbols, so same-named members of \
        unrelated types are included — confirm a hit with `where`. A test-target helper importing neither \
        framework counts as production. A type's lines inside its own declaration or its extensions in its own \
        module are counted apart from its uses, never as use.
        """
    }

    /// The paragraph on what a stale header counts, placed in the `answers` topic ahead of its account of semantic answers.
    static var staleHeader: String {
        """
        **A stale header counts the files the answer cites that differ from their own build, by kind.** \
        Each file an answer cites is judged against its own newest unit in the store, never against the newest \
        build of anything, so a build of one target does not make an edited file of another read as current. A \
        file is changed (written after its newest unit), deleted (gone from the tree) or new (no unit in any \
        store, in a module a build of the project compiles, written after the store's newest unit); a file no \
        build compiles is not counted. The header names the kinds present, in the order changed, deleted, new, \
        and the file's path where it counts exactly one: `stale since last build (1 cited file changed: <path>)`, \
        `(3 cited files changed)`, `(2 new cited files)`, `(4 cited files: 1 changed, 1 deleted, 2 new)`. A refusal after a partial \
        build names the module the build skipped. `affected` and `diff` count by the same rule; `sift status` \
        keeps the store's newest unit as its one anchor, so it reads fresh for a file a partial build skipped, \
        which only a query shows.
        """
    }
}
