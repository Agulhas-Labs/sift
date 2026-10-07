//
// Copyright © Agulhas Labs
//

/// The paths an extension is written through, which the index holds as the extension's whole name rather than under its final component.
///
/// `extension Depot.Gizmo` is one row named `Depot.Gizmo`, so a dotted query resolved by its final component and the qualifiers above it never reaches it; and `extension URL` extends a type of the tree only where the tree declares a type at the path `URL`, never because a type nested elsewhere is called `URL` too.
struct ExtensionPaths {
    /// `resolved` where the query resolved to anything, else the extensions written through the dotted path the query spells, with or without their module, or, for a bare name, through any dotted path ending in it; either is matched with generic arguments set aside, and a bare `Array`, `Dictionary` or `Optional` also reaches the extensions written with its sugar; where the query resolved to extensions alone, those spellings join the resolved ones.
    ///
    /// A bare name reaching `extension Foundation.JSONDecoder` proves nothing of the leading name: an alias writing the path without it is kept, never folded in (``SyntacticTypeUsage``).
    static func orSpelled(_ query: String, resolved: [SymbolRow], in store: IndexStore) throws -> [SymbolRow] {
        guard !query.hasPrefix(".") else { return resolved }
        guard resolved.isEmpty else {
            // Where the query resolved to extensions alone, the tree declares no type of the name, so the extensions written through it with generic arguments, a dotted path or sugar extend the same framework type they do.
            guard resolved.allSatisfy({ $0.kind == .extensionKind }) else { return resolved }
            let held = Set(resolved.map(\.id))
            return try resolved + spelled(query, in: store).filter { !held.contains($0.id) }
        }
        return try spelled(query, in: store)
    }

    /// The extensions the query is written through, as ``orSpelled(_:resolved:in:)`` reads them.
    private static func spelled(_ query: String, in store: IndexStore) throws -> [SymbolRow] {
        let name = DeclaredTypeName.last(ofPath: query)
        // An extension written with generic arguments is matched by its path with them set aside, so a name written inside the arguments never reaches it.
        let specialized = try store.extensions(specializingTypeNamed: name).filter { row in
            let path = DeclaredTypeName.path(ofSpelling: row.name)
            return query.contains(".") ? path == query || query == "\(row.module).\(path)" : path == query || path.hasSuffix("." + query)
        }
        // A bare name is asked of every declaration whose final name it is, and `extension Foundation.JSONDecoder` is the only one of a type known only through it.
        guard query.contains(".") else {
            return try store.extensions(ofTypeNamed: query).filter { $0.name.hasSuffix("." + query) } + specialized + sugared(query, in: store)
        }
        return try store.extensions(ofTypeNamed: name).filter { $0.name == query || query == "\($0.module).\($0.name)" } + specialized
    }

    /// The extensions written with the sugar that stands for `query` — `[Gizmo]` for `Array`, `[String: Gizmo]` for `Dictionary`, `Gizmo?` for `Optional` — read by the outermost sugar, so `extension [Gizmo]?` is `Optional`'s and a name inside the brackets never reaches one.
    private static func sugared(_ query: String, in store: IndexStore) throws -> [SymbolRow] {
        guard ["Array", "Dictionary", "Optional"].contains(query) else { return [] }
        return try store.sugaredExtensions().filter { DeclaredTypeName.last(ofPath: $0.name) == query }
    }

    /// The path of every type declaration among `declarations`, with and without its module, which is what an extension of it writes.
    static func declared(among declarations: [SymbolRow], in store: IndexStore) throws -> Set<String> {
        var paths: Set<String> = []
        for row in declarations where row.kind.isTypeDeclaration {
            let path = try (store.parentChain(of: row).map(\.name) + [row.name]).joined(separator: ".")
            paths.formUnion([path, "\(row.module).\(path)"])
        }
        return paths
    }
}
