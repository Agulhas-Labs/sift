//
// Copyright © Agulhas Labs
//

/// Which other declarations of a type's name the index reads a qualified use of it as, where the answer asks after only some of the types of the name.
///
/// `M.T` is read as a construction's qualifier is (``SameNamedTypes/Resolver``): through typealiases and supertypes, and the typealiases declared inside them, its first name looked up around the site first. That reading is not sound: Swift also sees names the scan never writes down (an implicit conformance's members, a macro's generated types, a supertype outside the index matched by its simple name, an enclosing scope's generic parameters), and each narrower rule tried still dropped real uses. So it never sets a site apart: a site the index reads as only other types of the name stays a use, noted with their owners. An implicit member's empty qualifier, a qualifier naming anything the index cannot see (a generic parameter, `Self`, a module, a type outside it), one resolving to no type of the name, and a name asked of a declaration that is no struct, class, enum or actor have no owners to note.
struct QualifiedTypeNameScope {
    private let resolver: SameNamedTypes.Resolver
    private let candidates: [SameNamedTypes.Candidate]
    /// The qualified paths of the asked declarations, or `nil` where one of them is no candidate the resolver can name.
    private let asked: Set<String>?

    init(store: IndexStore, resolver: SameNamedTypes.Resolver, name: String, asked rows: [SymbolRow]) throws {
        self.resolver = resolver
        candidates = try SameNamedTypes(store: store).candidates(named: name)
        let ids = Set(rows.map(\.id))
        let named = candidates.filter { ids.contains($0.row.id) }
        asked = named.count == ids.count ? Set(named.map(\.path)) : nil
    }

    /// The owners of the other declarations of the name the index reads `site`'s qualifier as naming, where it reads it as none of those asked for — none where it reads the site as an asked one's or cannot tell.
    func otherOwners(of site: SyntacticCallSite) throws -> [String] {
        guard let asked, let qualifier = site.qualifier, !qualifier.isEmpty else { return [] }
        return try Self.otherOwners(resolver.owners(of: site, among: candidates), among: candidates, asked: asked)
    }

    /// The owners of the other declarations of the name `owners` reads a site as, where it settled on some and none of them is at a path in `asked` — none where it reads the site as an asked one's, as no type's, or cannot tell.
    ///
    /// A top-level declaration's owner is its module.
    static func otherOwners(_ owners: SameNamedTypes.Owners, among candidates: [SameNamedTypes.Candidate], asked: Set<String>) -> [String] {
        guard owners.decided, owners.outside == nil, !owners.paths.isEmpty, owners.paths.isDisjoint(with: asked) else { return [] }
        let others = candidates.filter { owners.paths.contains($0.path) }
        return Set(others.map { $0.parents.isEmpty ? $0.row.module : $0.parents.joined(separator: ".") }).sorted()
    }
}
