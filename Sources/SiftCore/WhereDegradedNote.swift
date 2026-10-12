//
// Copyright © Agulhas Labs
//

import Foundation

/// Reads the ``DegradedNote`` a `where` answer carries off the semantic state it was rendered under and the declarations it lists.
struct WhereDegradedNote {
    /// The revision an `--at` answer reads, as written, or `nil` for the working tree's.
    let revision: String?
    /// What a list of the declarations in `sample` stands in for the store's callers.
    let standIn: WhereRenderer.StandIn
    /// Whether a declaration's kind is one the store is asked for the callers of.
    let isAskedOfTheStore: (SymbolKind) -> Bool

    /// The note an answer the store's relations are withheld from carries under its header, naming why and what was withheld for the declarations `sample` holds; `nil` where the store answered.
    func line(semantic: SemanticInput, sample: some Collection<SymbolRow>) -> String? {
        guard let cause = cause(of: semantic) else { return nil }
        let isUsed = { (row: SymbolRow) in row.kind.isTypeDeclaration || row.kind == .typealiasKind || row.kind == .associatedType || row.kind == .extensionKind }
        let types = sample.contains(where: isUsed)
        let others = sample.contains { !isUsed($0) && isAskedOfTheStore($0.kind) }
        let withheld: DegradedNote.Withheld = if standIn == .nothing {
            .subscripts
        } else if types {
            others ? .mixed : .uses
        } else {
            .calls
        }
        return DegradedNote(cause: cause, withheld: withheld).line
    }

    /// The one-line pointer to the recipe a no-match answer carries on a checkout with no store, since no written-name list is there to hold the degraded note.
    static func pointer(semantic: SemanticInput) -> [String] {
        guard case let .unavailable(note) = semantic else { return [] }
        return DegradedNote(cause: SiftEngine.whereNoStoreCause(from: note), withheld: .calls).pointer.map { [$0] } ?? []
    }

    private func cause(of semantic: SemanticInput) -> DegradedNote.Cause? {
        switch semantic {
        case .active: nil
        case .inactive: revision.map { .revision($0) } ?? .off
        case let .unavailable(note): SiftEngine.whereNoStoreCause(from: note)
        case .warming: .warming
        case let .openFailed(note): .openFailed(store: SiftEngine.openFailureStore(of: note), why: SiftEngine.openFailureCause(of: note))
        }
    }
}
