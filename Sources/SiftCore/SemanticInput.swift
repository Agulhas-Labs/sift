//
// Copyright © Agulhas Labs
//

import Foundation

/// Whether and how the index store participates in one query.
///
/// A type of its own rather than part of `WhereRenderer`, because `affected` reads it too: the engine's lazy open, the "still warming" note and the no-store note are one decision the engine makes per query, and two renderers consume it. Nesting it under one of them would make the other read as a `where` implementation detail.
enum SemanticInput {
    /// Semantics deliberately off (flag) — the note says why.
    case inactive(note: String)
    /// A semantic query was wanted but no store exists.
    case unavailable(note: String)
    /// A store exists but failed to open — kept apart from `unavailable` so the header does not advise a build that cannot fix it.
    case openFailed(note: String)
    /// A store exists and its open is still running past this query's budget — a separate case from `unavailable` because the header's verdict differs: wait, not build.
    case warming(note: String)
    /// The store is open; relations and staleness checks run.
    case active(SemanticContext)

    /// The open store's context, or `nil` where no store is in use.
    var context: SemanticContext? {
        if case let .active(context) = self {
            return context
        }
        return nil
    }

    /// Whether store-backed relations can be resolved at all in this query.
    var isActive: Bool {
        if case .active = self {
            return true
        }
        return false
    }

    /// Whether the caller turned semantics off (`--syntactic`) rather than merely lacking a store — distinguishes "did not ask for callers/overrides" from "asked, but nothing is there to answer with".
    var isInactive: Bool {
        if case .inactive = self {
            return true
        }
        return false
    }
}
