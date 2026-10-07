//
// Copyright © Agulhas Labs
//

/// Which declaration a type's name written bare means, where the answer asks after only some of the types of the name.
///
/// Swift looks a bare type name up in the type the site is written in first, then its supertypes, then the types around it, so `Site` written inside a type that declares its own `Site` is that type and never a same-named type nested elsewhere. A site is said to mean another only where the walk is certain: the first scope out from it holding a declaration of the name holds only type declarations none of which is asked for, and every type the index declares at that path declares one. A typealias of the name, an associated type declared anywhere but the body of the protocol the site is written in, a supertype declaring one or lying outside the index, or a path two types share keeps the site a use.
///
/// A bare name in a protocol's body that declares an associated type of the name, outside any `#if`, means that associated type (``ProtocolBodyScope``), unless an associated type is among those asked for.
struct BareTypeNameScope {
    private let store: IndexStore
    private let aliases: [String: Set<String>]
    /// Every declaration of the name, with the flattened names of the types it is nested in, outermost first.
    private let declared: [(row: SymbolRow, parents: [String])]
    private let asked: Set<Int64>
    private let asksAssociatedType: Bool
    private var decided: [[String]: Bool] = [:]

    init(store: IndexStore, name: String, asked: [SymbolRow]) throws {
        self.store = store
        aliases = try MemberReceivers.aliasedNames(in: store.everyTypealias())
        declared = try store.symbols(named: name)
            .filter { $0.kind.isTypeDeclaration || $0.kind == .typealiasKind || $0.kind == .associatedType }
            .map { try ($0, QualifiedPath.flattened(chain: store.parentChain(of: $0).map(\.name))) }
        self.asked = Set(asked.map(\.id))
        asksAssociatedType = asked.contains { $0.kind == .associatedType }
    }

    /// Whether `site` writes the name bare inside a type where it can only mean a declaration of the name other than those asked for.
    mutating func meansAnother(_ site: SyntacticCallSite) throws -> Bool {
        guard site.qualifier == nil else { return false }
        if site.meansOwnAssociatedType {
            return !asksAssociatedType
        }
        guard !site.enclosingTypes.isEmpty else { return false }
        if let known = decided[site.enclosingTypes] {
            return known
        }
        let verdict = try walk(site.enclosingTypes)
        decided[site.enclosingTypes] = verdict
        return verdict
    }

    private func walk(_ chain: [String]) throws -> Bool {
        for level in chain.indices.reversed() {
            let scope = Array(chain[...level])
            let here = declared.filter { $0.parents.count >= scope.count && Array($0.parents.suffix(scope.count)) == scope }
            if !here.isEmpty {
                guard here.allSatisfy({ !asked.contains($0.row.id) && $0.row.kind.isTypeDeclaration }) else { return false }
                // Two types at one path leave which the site is inside unsaid; each must declare one of the name.
                let declaring = Set(here.map { $0.row.module + ":" + $0.parents.joined(separator: ".") })
                let types = try store.typeDeclarations(named: chain[level]).map { row in
                    try (row.module, QualifiedPath.flattened(chain: store.parentChain(of: row).map(\.name)) + [row.name])
                }
                return types.filter { $0.1.count >= scope.count && Array($0.1.suffix(scope.count)) == scope }
                    .allSatisfy { declaring.contains($0.0 + ":" + $0.1.joined(separator: ".")) }
            }
            // An inherited declaration of the name is found before an outer one, and a supertype outside the index may hold one.
            let supertypes = try MemberReceivers(store: store).supertypes(of: [chain[level]], aliases: aliases)
            guard supertypes.unseen.isEmpty, !declared.contains(where: { $0.parents.last.map(supertypes.names.contains) == true }) else { return false }
        }
        return false
    }
}
