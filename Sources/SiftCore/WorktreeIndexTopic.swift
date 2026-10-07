//
// Copyright © Agulhas Labs
//

/// The text `sift help worktree-index` prints: why `where` and `affected` answer thin in a linked worktree, why the checkout's store is never read in its place, and how to build one here.
///
/// A type of its own rather than one more member of ``HelpTopics``, whose file had outgrown the line limit with every topic in it.
struct WorktreeIndexTopic {
    /// The topic's body, quoting the build command and the config key from ``SiftEngine`` so they cannot drift from a per-call note.
    static var body: String {
        """
        **Every linked worktree hits this, because a worktree has no build directory of its own.** \
        `where` and `affected` answer semantically from an index store, and there is never one here \
        until a build creates it in this exact worktree — the same repository's checkout can be \
        building semantically every day and this tree still answers nothing, because the store lives \
        under a `.build` this worktree never wrote.

        **The obvious repair is the one thing this must never do: read the checkout's store instead.** \
        That store describes a *different tree*. At a different commit it would name callers that do \
        not exist here, and miss ones that do — a confidently wrong answer traded for one that merely \
        looks more complete, which is exactly what pinning the root to the caller's own tree exists to \
        prevent. So the checkout's store is never borrowed, on any query, however current it looks.

        **To build one here:** \(SiftEngine.buildCommandNote).

        **A nested package needs one more step:** \(SiftEngine.nestedStoreNote).

        **The other way out is not a build at all.** Running the same query against the repository's \
        own checkout is a perfectly good answer *about that tree* — read it as being about the \
        checkout, not about this worktree.

        **Until either happens, declarations still answer from syntax; callers, overrides and \
        references do not** — the fallback matches a written name over the working tree rather than a \
        resolved symbol, so it finds a call by that name in an unrelated type and misses one reached \
        only through a protocol or a closure. Under `--refs` those name-matched sites are the sweep, \
        headed as matched by written name and paged by file on the `offset` cursor rather than cut to a sample, never a \
        bare "grep instead".

        **A type's "used by" list under this fallback is matched on its written name.** It lists every \
        place the name is written — a construction, a static member reached through it, an annotation, a \
        generic argument, a conformance, a cast — and folds in the uses written through the typealiases of it \
        the index holds, saying how many; but a use under any other name, an alias declared inside a function \
        body or a string literal, is invisible to it. An empty list here is never "nothing uses this" — a \
        rename sweep that trusts it can miss every one of those sites.
        """
    }
}
