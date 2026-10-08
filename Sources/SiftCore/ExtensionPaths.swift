//
// Copyright © Agulhas Labs
//

/// The paths an extension is written through, which the index holds as the extension's whole name rather than under its final component.
///
/// `extension Depot.Gizmo` is one row named `Depot.Gizmo`, so a dotted query resolved by its final component and the qualifiers above it never reaches it; and `extension URL` extends a type of the tree only where the tree declares a type at the path `URL`, never because a type nested elsewhere is called `URL` too.
struct ExtensionPaths {
    /// Every extension whose header writes a dotted path ending in `name`, plainly or with generic arguments, each with that path, in file and line order: the one reading of an extension's spelling every rule over extensions starts from.
    static func written(endingIn name: String, in store: IndexStore) throws -> [Written] {
        // A name written inside the generic arguments makes a candidate too, so the path with them set aside decides.
        let candidates = try store.extensions(ofTypeNamed: name) + store.extensions(specializingTypeNamed: name)
        return candidates
            .map { Written(row: $0, path: $0.name.contains("<") ? DeclaredTypeName.path(ofSpelling: $0.name) : $0.name) }
            .filter { $0.path == name || $0.path.hasSuffix("." + name) }
            .sorted { ($0.row.path, $0.row.line) < ($1.row.path, $1.row.line) }
    }

    /// Every extension ``written(endingIn:in:)`` reads for the bare name `name`, whatever its module or the path before the name: the candidates a rule that can tell them apart, the store's or ``ExtensionPlacement``'s, starts from.
    static func extensions(ofTypeNamed name: String, in store: IndexStore) throws -> [SymbolRow] {
        try written(endingIn: name, in: store).map(\.row)
    }

    /// The extensions listed under the type `owners` declare, each with whether it may extend another module's type of the name instead.
    ///
    /// Where `owners` are one type, at one path in one module, an extension ``ExtensionPlacement`` places as another type's is left out, and one it cannot place is listed and marked. Where they are several, every candidate is listed under the name, unmarked, as each owner's.
    static func listed(under owners: [SymbolRow], named name: String, in store: IndexStore) throws -> [(row: SymbolRow, mayExtendAnother: Bool)] {
        let candidates = try written(endingIn: name, in: store)
        let placements = try owners.map { try ExtensionPlacement(of: $0, in: store) }
        guard let placement = placements.first, placements.allSatisfy({ $0.module == placement.module && $0.path == placement.path }) else {
            return candidates.map { ($0.row, false) }
        }
        return try candidates.compactMap { written in
            switch try placement.place(written) {
            case .asked: (written.row, false)
            case .unplaced: (written.row, true)
            case .another: nil
            }
        }
    }

    /// `resolved` where the query resolved to anything, else the extensions written through the dotted path the query spells, with or without their module, or, for a bare name, through any dotted path ending in it; either is matched with generic arguments set aside, and a bare `Array`, `Dictionary` or `Optional` also reaches the extensions written with its sugar; where the query resolved to extensions alone, those spellings join the resolved ones.
    ///
    /// A query led by a name the tree neither declares, aliases or extends as a type nor has as a module (`Swift.Dictionary`) is read as led by a module the tree imports, so it also reaches the extensions written without that name, other than one in a module declaring its own type at that path, which extends that type; led by `Swift`, it reaches the sugar as well.
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
        let written = try written(endingIn: DeclaredTypeName.last(ofPath: query), in: store)
        // A bare name is asked of every declaration whose final name it is, and `extension Foundation.JSONDecoder` is the only one of a type known only through it.
        guard query.contains(".") else {
            return try written.map(\.row) + sugared(query, in: store)
        }
        guard let imported = try importedModule(leading: query, in: store) else {
            return written.filter { $0.path == query || query == "\($0.row.module).\($0.path)" }.map(\.row)
        }
        // An extension written without the module extends the module's own type of the path where it has one, which Swift's lookup finds before any import's.
        let owned = try declared(among: store.typeDeclarations(named: DeclaredTypeName.last(ofPath: imported.path)), in: store)
        let matched = written.filter { $0.path == query || ($0.path == imported.path && !owned.contains("\($0.row.module).\(imported.path)")) }
        return try matched.map(\.row) + (imported.module == "Swift" ? sugared(imported.path, in: store) : [])
    }

    /// The leading name of a dotted query and the path after it, where the tree neither declares, aliases nor extends a type of that name at the top level nor has a module of it, and so it is read as a module the tree imports: `Swift` and `Dictionary` for `Swift.Dictionary`.
    private static func importedModule(leading query: String, in store: IndexStore) throws -> (module: String, path: String)? {
        let components = QualifiedPath.components(of: query)
        guard components.count > 1, let module = components.first else { return nil }
        guard try !writesType(named: module, in: store), try !store.moduleNames().contains(module) else { return nil }
        return (module, components.dropFirst().joined(separator: "."))
    }

    /// Whether the tree writes `name` as a type at the top level: declares, aliases or extends one of the name, so a dotted path led by it is that type's, never a module's, and a bare extension at file scope never names a type nested in it.
    static func writesType(named name: String, in store: IndexStore) throws -> Bool {
        try store.symbols(named: name).contains { $0.parentID == nil && ($0.kind.isTypeDeclaration || $0.kind == .typealiasKind) }
            || written(endingIn: name, in: store).contains { $0.path == name }
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

extension ExtensionPaths {
    /// An extension with the dotted path its header writes, generic arguments set aside: `Box` for `extension Box<Int>`, `App.Box` for `extension App.Box<String>`.
    struct Written {
        let row: SymbolRow
        let path: String
    }
}
