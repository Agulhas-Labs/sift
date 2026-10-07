//
// Copyright © Agulhas Labs
//

/// What a `where` answer says about the stores beside the primary: the mode line naming each that answered, and the line naming the project that builds a file none covers.
struct WhereStoreLines {
    /// The mode line of an answer read from an open store, naming the primary store, each in-tree store that answered, each one still loading or failed, and any setting passed over.
    static func modeLine(_ context: SemanticContext, answeredBy inTree: [String]) -> String {
        // With no primary store, the first in-tree store stands in its place and is named as what it is.
        let primary = if case .inTree = context.store.provenance {
            "in-tree store"
        } else {
            "index store"
        }
        let sources = ["\(primary) via \(context.store.provenance.name)"] + inTree.map { "in-tree store via \($0)" }
        let pending = context.pendingInTree.map { "; " + $0 }.joined()
        let passedOver = context.rejectedSettings.isEmpty ? "" : "; passed over: " + context.rejectedSettings.joined(separator: "; ")
        return "mode: syntactic + semantic (\(sources.joined(separator: "; ")))\(pending)\(passedOver)"
    }

    /// The `--refs` line of an answer with no index store at all, whose name-matched sites below it are then the whole sweep, paged by file rather than cut to a sample.
    ///
    /// Says what a written-name match cannot be trusted for, since it stands where resolved references would: a sweep that reads the list as complete would miss a use under another name and rename a same-named symbol's site. A type's block folds in the uses written through its typealiases and says so, so the line says a typealias is missed only where no block folded it in. Kept to one short line: the mode line above already names the missing store, and the whole reasoning is in the `worktree-index` help topic.
    static let syntacticSweepLine = "references: all sites by written name, paged by file — may add same-named symbols'; "
        + "may miss protocol, closure, unfolded-typealias uses; skips comments, strings"

    /// One line per Xcode project that builds a file among `rows` no store covers, in the order the files first appear, after a blank line.
    static func projectHints(for rows: [SymbolRow], owner: ((String) -> String?)?) -> [String] {
        guard let owner else { return [] }
        var hints: [String] = []
        for row in rows {
            if let hint = owner(row.path), !hints.contains(hint) {
                hints.append(hint)
            }
        }
        return hints.isEmpty ? [] : [""] + hints
    }

    /// Appends the project-build hint for `rows`, held back while an in-tree store is still loading (it may turn out to cover the file) or when the primary is already a DerivedData store — that already is the best build sift found, and a miss under it is the declaration, not the build.
    static func appendProjectHintsIfAllowed(to lines: inout [String], for rows: [SymbolRow], owner: ((String) -> String?)?, inTreeWarming: Bool, primaryProvenance: DiscoveredStore.Provenance) {
        guard !inTreeWarming, primaryProvenance != .derivedData else { return }
        lines.append(contentsOf: projectHints(for: rows, owner: owner))
    }

    /// Appends the project-build hint for `rows`, folding its generic build command out of the mode line first when a hint is going to print beside it — one piece of build advice rather than two that can disagree.
    static func appendNoStoreProjectHints(to lines: inout [String], for rows: [SymbolRow], owner: ((String) -> String?)?) {
        let hints = projectHints(for: rows, owner: owner)
        if !hints.isEmpty, let modeIndex = lines.firstIndex(where: { $0.hasPrefix("mode: ") }) {
            lines[modeIndex] = lines[modeIndex].replacingOccurrences(
                of: "build one: \(SiftEngine.buildCommandNote). \(SiftEngine.nestedStoreNote). ",
                with: ""
            )
        }
        lines.append(contentsOf: hints)
    }
}
