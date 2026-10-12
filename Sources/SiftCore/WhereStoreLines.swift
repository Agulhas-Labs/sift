//
// Copyright © Agulhas Labs
//

/// What a `where` answer says about the stores beside the primary: the `stores:` note naming each that answered, and the line naming the project that builds a file none covers.
struct WhereStoreLines {
    /// How the `stores:` note opens.
    static var storesOpening: String {
        "stores: "
    }

    /// The note of an answer read from an open store that has something to say about its stores: each in-tree store that answered beside the primary, each one still loading or failed, and any setting passed over; `nil` where one store answered and nothing was passed over, since `semantic:` in the header already says the store answered (Docs/Design.md §2, *The degraded note*).
    static func storesNote(_ context: SemanticContext, answeredBy inTree: [String]) -> String? {
        guard !inTree.isEmpty || !context.pendingInTree.isEmpty || !context.rejectedSettings.isEmpty else { return nil }
        // With no primary store, the first in-tree store stands in its place and is named as what it is.
        let primary = if case .inTree = context.store.provenance {
            "in-tree store"
        } else {
            "index store"
        }
        let sources = ["\(primary) via \(DiscoveredStore.label(provenance: context.store.provenance, package: context.store.package))"] + inTree.map { "in-tree store via \($0)" }
        let pending = context.pendingInTree.map { "; " + $0 }.joined()
        let passedOver = context.rejectedSettings.isEmpty ? "" : "; passed over: " + context.rejectedSettings.joined(separator: "; ")
        return "\(storesOpening)\(sources.joined(separator: "; "))\(pending)\(passedOver)"
    }

    /// Puts the `stores:` note for `inTree` at the top of `lines`, in place of the one already there; whether it added a line, so the caller can move the slots it holds below it.
    static func placeStoresNote(_ context: SemanticContext, answeredBy inTree: [String], in lines: inout [String]) -> Bool {
        guard let note = storesNote(context, answeredBy: inTree) else { return false }
        if lines.first?.hasPrefix(storesOpening) == true {
            lines[0] = note
            return false
        }
        lines.insert(note, at: 0)
        return true
    }

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

    /// Appends the project-build hint for `rows`, taking the degraded note's build remedy out first when a hint is going to print beside it: one piece of build advice rather than two that can disagree.
    static func appendNoStoreProjectHints(to lines: inout [String], for rows: [SymbolRow], owner: ((String) -> String?)?) {
        let hints = projectHints(for: rows, owner: owner)
        if !hints.isEmpty, let noteIndex = lines.firstIndex(where: { DegradedNote.withoutRemedy($0) != $0 }) {
            lines[noteIndex] = DegradedNote.withoutRemedy(lines[noteIndex])
        }
        lines.append(contentsOf: hints)
    }
}
