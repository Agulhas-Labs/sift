//
// Copyright © Agulhas Labs
//

/// What holds of every `where` and `search` answer, said once per session instead of on each answer (Docs/Design.md §2, *One header line, standing caveats said once per session*).
///
/// One text in every place that says it — the primer's bullet, the `where` and `search` tool descriptions for a client the primer never reaches, and `sift help answers` — so a reader is told the same whichever one reached them, and a rewording cannot leave one of them saying the old thing.
public struct StandingCaveats {
    /// The clause the `search` tool description carries on its own: what its `calls:` and `uses:` match.
    public static var searchClause: String {
        "`calls:`/`uses:` match written names, so same-named symbols may appear and an empty list is not proof it is unused."
    }

    /// The sentences, word for word as each place carries them.
    public static var sentences: String {
        "`where`'s callers and references are code this build compiled "
            + "(not a sibling repo, an uncompiled target or a synthesized conformance, so a short list is not \"unused\"; "
            + "`--refs` adds comments, strings and Markdown under `not code`); written-name matches (`search` `calls:`/`uses:`, "
            + "a no-store `where`) may include same-named symbols and may miss protocol, closure, unfolded-typealias uses and unapplied instance-method references, "
            + "so an empty list is not proof it is unused; property and case uses by name at runtime (key paths, `Mirror`, "
            + "`rawValue` lookups) are not seen; tests are split on the XCTest or Testing "
            + "import, never the path."
    }
}
