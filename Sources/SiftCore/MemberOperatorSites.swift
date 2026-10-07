//
// Copyright © Agulhas Labs
//

/// What the scan by written name can say of a member operator's sites.
///
/// An applied operator (`a == b`, `-a`, `reduce(x, +)`) writes no receiver, so nothing at a site tells which type's operator it applies: `where Session.==` would list every `==` in the tree as that one type's. Every site is kept, since any of them may be a real use, and the count beside the name says whose they are.
struct MemberOperatorSites {
    /// `any type's ==, as an applied operator writes no receiver to tell Session's apart`, where `base` is an operator some of `declarations` declare as a member of a type, named by `owner`; `nil` for any other name, or an operator declared outside every type, which has no owner to tell apart.
    static func clause(base: String, declarations: [SymbolRow], owner: (SymbolRow) throws -> String?) rethrows -> String? {
        guard SymbolNaming.isOperator(base) else { return nil }
        // A free operator's qualified name ends in its module, which is no type it could be told apart from.
        let owners = try Set(declarations.filter { $0.parentID != nil }.compactMap(owner))
        guard !owners.isEmpty else { return nil }
        let named = owners.sorted().map { $0 + "'s" }.joined(separator: " or ")
        return "any type's \(base), as an applied operator writes no receiver to tell \(named) apart"
    }
}
