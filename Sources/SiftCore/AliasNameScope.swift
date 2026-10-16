//
// Copyright © Agulhas Labs
//

/// Which declaration a typealias's name written at a site means, where the answer folds the alias in as another name for a type.
///
/// Swift looks the name up as it looks up any bare type name: in the body around the site, then the type the site is written in, its supertypes, the types around it, and last the top level. So a nested scope declaring its own of the name hides an alias of it declared further out, and a use written there means that one. A site reads as the alias only where the walk reaches the alias and nothing else of the name; as another declaration only where the first scope out holding the name holds only declarations the walk can be certain of; and as undecided wherever a qualifier, a supertype outside the index, a body's own declaration, two declarations at one level or a capped chain leaves it unsaid.
struct AliasNameScope {
    private let store: IndexStore
    private let name: String
    private let aliases: Set<Int64>
    /// Every declaration of the name the index holds that is not one of the aliases, with the flattened names of the types it is nested in, outermost first.
    private let others: [(row: SymbolRow, parents: [String])]
    /// The aliases, with the same parents.
    private let own: [(row: SymbolRow, parents: [String])]
    private let reachedCap: Bool
    /// Per file, the lines the index holds a declaration of the name on, which tell a declaration a scan of the blocks around a site finds in a type or at the top level from one a body declares.
    private let indexedLines: [String: Set<Int>]
    private var typealiasTargets: [String: Set<String>]?
    private var reached: [[String]: Reach] = [:]

    /// The scope of `name` for `aliases`, the typealiases of that name a chain folded in; `reachedCap` is whether the chain stopped at its cap, so an alias of the name left out of it may still name the type.
    init(store: IndexStore, name: String, aliases: [SymbolRow], reachedCap: Bool) throws {
        self.store = store
        self.name = name
        let ids = Set(aliases.map(\.id))
        self.aliases = ids
        self.reachedCap = reachedCap
        let declared: [(row: SymbolRow, parents: [String])] = try store.symbols(named: name)
            .filter { $0.kind.isTypeDeclaration || $0.kind == .typealiasKind || $0.kind == .associatedType }
            .map { try ($0, QualifiedPath.flattened(chain: store.parentChain(of: $0).map(\.name))) }
        others = declared.filter { !ids.contains($0.row.id) }
        own = declared.filter { ids.contains($0.row.id) }
        indexedLines = declared.reduce(into: [:]) { $0[$1.row.path, default: []].insert($1.row.line) }
    }

    /// What the alias's name written at `site` means.
    mutating func reading(of site: SyntacticCallSite) throws -> Reading {
        if site.meansLocalType {
            return .local
        }
        // A type of this name declared in a body that the site is written inside may be what `Self` or an implied `init` means, though the site never writes the name.
        if site.localEnclosingTypes.contains(name) {
            return .undecided
        }
        // The index holds no row of a body's own declaration, so whether it names another type goes unsaid; one in a type or at the top level is a row, read by the walk below.
        let indexed = indexedLines[site.path] ?? []
        if site.localDeclarations?.contains(where: { !indexed.contains(Int($0.prefix { $0 != ":" }) ?? 0) }) == true {
            return .undecided
        }
        guard !others.isEmpty else { return .alias }
        guard site.qualifier == nil else { return .undecided }
        if site.meansOwnAssociatedType {
            return .another
        }
        return try reading(writtenIn: site.enclosingTypes)
    }

    /// What the name means written bare in a declaration nested in `enclosingTypes`, the flattened names of the types around it, outermost first.
    ///
    /// Never `.local`: a declaration in a type sees no body's own declarations.
    mutating func reading(writtenIn enclosingTypes: [String]) throws -> Reading {
        guard !others.isEmpty else { return .alias }
        return switch try walked(enclosingTypes) {
        case .aliases: .alias
        case .another: .another
        case .undecided: .undecided
        }
    }

    /// Which of the aliases the name written bare in a declaration nested in `enclosingTypes` reaches, the flattened names of the types around it, outermost first.
    ///
    /// The lookup stops at the first scope out holding a declaration of the name, so where several aliases are the name's, a nearer one hides a farther one. The name's only declaration is reached from anywhere.
    mutating func reach(writtenIn enclosingTypes: [String]) throws -> Reach {
        if own.count + others.count == 1 {
            return own.first.map { .aliases([$0.row.id]) } ?? .another
        }
        return try walked(enclosingTypes)
    }

    private mutating func walked(_ enclosingTypes: [String]) throws -> Reach {
        if let known = reached[enclosingTypes] {
            return known
        }
        let reach = try walk(enclosingTypes)
        reached[enclosingTypes] = reach
        return reach
    }

    private mutating func walk(_ chain: [String]) throws -> Reach {
        for level in chain.indices.reversed() {
            let scope = Array(chain[...level])
            let isHere = { (declaration: (row: SymbolRow, parents: [String])) in
                declaration.parents.count >= scope.count && Array(declaration.parents.suffix(scope.count)) == scope
            }
            let ownHere = own.filter(isHere)
            let othersHere = others.filter(isHere)
            if !ownHere.isEmpty || !othersHere.isEmpty {
                // Two types at one path leave which the site is inside unsaid; each must declare one of the name.
                guard try everyType(named: chain[level], at: scope, declaresOneOf: ownHere + othersHere) else { return .undecided }
                if othersHere.isEmpty {
                    return .aliases(Set(ownHere.map(\.row.id)))
                }
                // An alias the capped chain left out may still be another name for the type.
                let certain = ownHere.isEmpty && othersHere.allSatisfy { $0.row.kind != .associatedType && !(reachedCap && $0.row.kind == .typealiasKind) }
                return certain ? .another : .undecided
            }
            // An inherited declaration of the name is found before an outer one, and a supertype outside the index may hold one.
            if typealiasTargets == nil {
                typealiasTargets = try MemberReceivers.aliasedNames(in: store.everyTypealias())
            }
            let supertypes = try MemberReceivers(store: store).supertypes(of: [chain[level]], aliases: typealiasTargets ?? [:])
            let inherited = (own + others).contains { $0.parents.last.map(supertypes.names.contains) == true }
            guard supertypes.unseen.isEmpty, !inherited else { return .undecided }
        }
        let topLevel = (own + others).filter(\.parents.isEmpty)
        return !topLevel.isEmpty && topLevel.allSatisfy { aliases.contains($0.row.id) } ? .aliases(Set(topLevel.map(\.row.id))) : .undecided
    }

    /// Whether every type the index declares by `name` at the path `scope` ends is one of those `here` is declared in.
    private func everyType(named name: String, at scope: [String], declaresOneOf here: [(row: SymbolRow, parents: [String])]) throws -> Bool {
        let declaring = Set(here.map { $0.row.module + ":" + $0.parents.joined(separator: ".") })
        let types = try store.typeDeclarations(named: name).map { row in
            try (row.module, QualifiedPath.flattened(chain: store.parentChain(of: row).map(\.name)) + [row.name])
        }
        return types.filter { $0.1.count >= scope.count && Array($0.1.suffix(scope.count)) == scope }
            .allSatisfy { declaring.contains($0.0 + ":" + $0.1.joined(separator: ".")) }
    }
}

extension AliasNameScope {
    /// What an alias's name written at a site means.
    enum Reading: Equatable {
        /// The alias, or one of the aliases of the name: the site is a use of the type it names.
        case alias
        /// A declaration of the name in a type around the site, or an associated type of the protocol it is written in.
        case another
        /// A struct, class, enum or actor declared in a body around the site.
        case local
        /// Nothing the index holds says which declaration of the name it means.
        case undecided
    }

    /// Which declarations of the name the lookup from a declaration's position reaches.
    enum Reach: Equatable {
        /// These of the aliases, and nothing else of the name.
        case aliases(Set<Int64>)
        /// A declaration of the name that is none of the aliases.
        case another
        /// Nothing the index holds says which declaration of the name it reaches.
        case undecided
    }
}
