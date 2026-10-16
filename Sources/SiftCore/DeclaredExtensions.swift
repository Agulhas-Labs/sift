//
// Copyright © Agulhas Labs
//

/// What the `declarations` section says of an extension it prints, so the `extensions of` block need not print it again.
struct DeclaredExtensions {
    /// The extensions listed under each type's name, each with whether it may extend another module's type of the name.
    typealias Listings = [String: [(row: SymbolRow, mayExtendAnother: Bool)]]

    /// The member count an extension row carries, and the mark on a row that may not be its type's.
    ///
    /// The mark reads `may extend another module's Gizmo` where the block would have said so, and `extends another module's Gizmo` where ``ExtensionPlacement`` places the row on another type. Only a name a type of the answer declares is marked.
    static func annotation(of row: SymbolRow, listings: Listings, in store: IndexStore) throws -> (memberCount: Int?, mark: String?) {
        guard row.kind == .extensionKind else { return (nil, nil) }
        let memberCount = try store.childCount(of: row.id)
        guard let extensions = listings[row.name] else { return (memberCount, nil) }
        guard let entry = extensions.first(where: { $0.row.id == row.id }) else {
            return (memberCount, "extends another module's \(row.name)")
        }
        return (memberCount, entry.mayExtendAnother ? "may extend another module's \(row.name)" : nil)
    }

    /// The clause a cut declarations list ends with: how many of its cut rows each type's block lists, or nothing where none.
    static func truncationTail(cut: some Sequence<SymbolRow>, listings: Listings, printed: Set<Int64>, blockCap: Int) -> String {
        let cutIDs = Set(cut.map(\.id))
        let clauses = listings.keys.sorted().compactMap { typeName -> String? in
            let shown = (listings[typeName] ?? []).filter { !printed.contains($0.row.id) }.prefix(blockCap)
            let count = shown.count { cutIDs.contains($0.row.id) }
            return count > 0 ? "\(count) of them under extensions of \(typeName)" : nil
        }
        return clauses.isEmpty ? "" : ", " + clauses.joined(separator: ", ")
    }
}
