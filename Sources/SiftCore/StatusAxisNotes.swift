//
// Copyright © Agulhas Labs
//

/// What `sift help answers` says of the header's `semantic:` field: that it is the mode an answer was produced in, what `status`'s counts, and every case only a query shows.
///
/// `status` prints one line naming this topic (`statusAxisNote` on ``SiftEngine``) rather than the list, since a list printed on every run buries the store line it follows. Each gap is one Docs/Design.md §2 leaves this reading, and the two must change together.
struct StatusAxisNotes {
    static var body: String {
        """
        **The header's `semantic:` is the mode that produced this answer, not a property of the tree.** \
        `digest` never opens the store, so its header carries no `semantic:` field; `status` judges from file \
        timestamps, so it can say `stale since last build (2 files changed)` and counts every file; `where` consults the store, so it \
        can say `fresh`. A file counts as changed when its contents or its file status moved past the build, so a \
        copy that preserves modification times still reads as changed. On one tree you can therefore see `status` \
        stale and `where` fresh (it asked about a symbol in a file no edit touched). In a tree with no index store \
        yet, `where` says `\(SemanticAxis.noStore(inWorktree: false).rendered)`, and in a fresh worktree \
        `\(SemanticAxis.noStore(inWorktree: true).rendered)`: it asked and found none. They do not contradict; \
        read the one on the answer you are acting on.

        **What `status`'s `semantic:` counts, and what only a query shows.** It is judged from files, without \
        opening the index store. It counts files changed since the store's last build, and deleted files the \
        store may still cite: ones this index saw go after that build, and ones the store's files on disk still \
        name. A build keeps a deleted file's record until a clean build, so a file renamed or deleted before a \
        build stays counted, and stays marked in every query citing it, through each build that does not clean. \
        It also counts files git showed as deleted when this index first started keeping that count. Only a query \
        shows a declaration the store has no record of, unbuilt test files, a file a partial build skipped, a \
        store that fails to open, or one still loading. So do three deletions: a file git never tracked, whose \
        only record here was lost to a reset or an older binary; a file deleted by a commit older than the \
        build, reached later without a commit of its own (a fast-forward, checkout, hard reset, or rebase onto \
        older work); and a deletion an older sift binary drops once this index has started counting them, \
        since that counting starts only once.
        """
    }
}
