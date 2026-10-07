//
// Copyright © Agulhas Labs
//

/// Whether the scopes around a site may hand it a type name the tree cannot show, so a name written there need not be the tree's type of that name.
///
/// Swift looks a bare name up in the members of the types around it, inherited ones included, before the module's top level: inside `final class Bin: Holder<Depot>` an `Item` may be the dependency superclass's typealias, inside `struct Shelf: Sequence` an `Element` the inferred element type, inside `extension Box where Item == Depot` the generic parameter `Item`, and inside a type carrying an attached macro anything the macro adds.
final class EnclosingScopeNames {
    private let receivers: MemberReceivers
    private let aliases: [String: Set<String>]
    private var facts: [String: Facts] = [:]

    init(receivers: MemberReceivers, aliases: [String: Set<String>]) {
        self.receivers = receivers
        self.aliases = aliases
    }

    /// How a site written on `name` is kept because a scope around it, or the receiver's own type, may supply or reshape the name, or `nil` where none may.
    ///
    /// A generic parameter of a type around the site, or a name a where clause around the site writes that a type around it the tree does not declare may own, is kept as a generic parameter written in a type's own body is; a name a supertype outside the tree may supply, or one written inside or on a type carrying an attached macro, is kept and counted outside the tree.
    func keeping(_ name: String, at site: SyntacticCallSite) throws -> ReceiverReach? {
        for (depth, type) in site.enclosingTypes.enumerated() {
            // A type declared inside a function has supertypes, generic parameters and members no top-level type of its name shows.
            guard !site.localEnclosingTypes.contains(type) else { return .outsideTree }
            let around = try facts(of: type)
            // An extension written as no declaration of the name it can see is (`extension Label` beside only `Theme.Label`, `extension UIKit.UILabel`) extends a type outside the tree; one written `Theme.Label` extends the tree's.
            if depth == 0, around.isDeclared, FrameworkProtocolNames.mayName(name, from: type), try isInExtensionOfAnother(type, site) {
                return .outsideTree
            }
            guard !around.generics.contains(name) else { return .untyped }
            // The clauses around the site, an extension's and a function's own, written either way round and behind `Self.` or not; only a name the extended type may own is its parameter, so the concrete type on the other side stays the tree's.
            if !around.isDeclared, site.enclosingConstraints.contains(name), FrameworkProtocolNames.mayName(name, from: type) {
                return .untyped
            }
            if around.carriesMacro || around.unseenSelves.contains(where: { FrameworkProtocolNames.mayName(name, from: $0) }) {
                return .outsideTree
            }
            if around.unseen.contains(where: { FrameworkProtocolNames.mayName(name, inheriting: $0) }) {
                return .outsideTree
            }
        }
        return try facts(of: name).carriesMacro ? .outsideTree : nil
    }

    /// What `type`'s declarations, extensions and supertypes say about the names its scope may supply.
    private func facts(of type: String) throws -> Facts {
        if let known = facts[type] {
            return known
        }
        let (supertypes, unseen) = try receivers.supertypes(of: [type], aliases: aliases)
        let store = receivers.store
        let declared = try store.typeDeclarations(named: type)
        var carriesMacro = false
        for name in supertypes.union([type]) where !carriesMacro {
            let rows = try store.typeDeclarations(named: name) + store.extensions(ofTypeNamed: name)
            carriesMacro = try rows.contains { try Self.mayBeMacros(AttributeScanner.customAttributeNames(in: $0.signature), in: store) }
        }
        // A typealias's scope is that of each type it stands for, so it holds their generic parameters too.
        let standsFor = aliased(by: type)
        let aliasedRows = try standsFor.flatMap { try store.typeDeclarations(named: $0) }
        let generics = Set((declared + aliasedRows).flatMap(SameNamedTypes.Resolver.genericParameters))
        let isDeclared = !declared.isEmpty || aliases[type] != nil
        // A type the tree does not declare, or one a typealias spells with sugar the alias's names leave out (`[Depot]` an `Array`), may supply names as a supertype outside the tree does; so may one the alias stands for.
        let isOwnScopeUnseen = try !isDeclared || standsForSugar(type)
        let selves = unseen.intersection(standsFor).union(isOwnScopeUnseen ? [type] : [])
        let found = Facts(unseen: unseen.subtracting(standsFor), unseenSelves: selves, generics: generics, carriesMacro: carriesMacro, isDeclared: isDeclared)
        facts[type] = found
        return found
    }

    /// Whether `site` is written in an extension of `type` that names no declaration of `type` the extension can see by that declaration's path or its module and path, so it extends a type outside the tree.
    ///
    /// A declaration is out of the extension's sight where it, or a type it is nested in, is in another module, private to another file, or under an `#if` the extension does not share: the extension may extend another type of the name, so the site is kept.
    private func isInExtensionOfAnother(_ type: String, _ site: SyntacticCallSite) throws -> Bool {
        let store = receivers.store
        let around = try store.extensions(ofTypeNamed: type).filter { $0.path == site.path && ($0.line ... $0.endLine).contains(site.line) }
        guard !around.isEmpty else { return false }
        let declared = try store.symbols(named: type).filter { $0.kind.isTypeDeclaration || $0.kind == .typealiasKind }
        let chains = try declared.map { try store.parentChain(of: $0) + [$0] }
        return around.contains { extended in
            !chains.contains { chain in
                let path = chain.map(\.name).joined(separator: ".")
                let isVisible = chain.allSatisfy { row in
                    row.module == extended.module && (row.accessLevel >= .internalLevel || row.path == extended.path)
                        && (row.ifConfigCondition == nil || row.ifConfigCondition == extended.ifConfigCondition)
                }
                return isVisible && (extended.name == path || extended.name == "\(extended.module).\(path)")
            }
        }
    }

    /// Every name the typealias `type` stands for, followed through typealiases standing for others, or none where `type` is no typealias.
    private func aliased(by type: String) -> Set<String> {
        var visited: Set<String> = [type]
        var pending = Array(aliases[type] ?? [])
        while let next = pending.popLast() {
            if visited.insert(next).inserted {
                pending += aliases[next] ?? []
            }
        }
        return visited.subtracting([type])
    }

    /// Whether a typealias named `type` writes an array, dictionary or optional with sugar on its right-hand side, whose type the alias's names do not hold.
    private func standsForSugar(_ type: String) throws -> Bool {
        try receivers.store.symbols(named: type).contains { row in
            guard row.kind == .typealiasKind, let equals = row.signature.firstIndex(of: "=") else { return false }
            return row.signature[equals...].contains { "[?!".contains($0) }
        }
    }

    /// Whether any of `attributes`, written on a type or an extension, may be an attached macro: one the language does not define and that names no type the tree declares, which would make it a global actor.
    private static func mayBeMacros(_ attributes: [String], in store: IndexStore) throws -> Bool {
        try attributes.contains { name in
            guard !name.hasPrefix("_") else { return false }
            return try store.typeDeclarations(named: name).isEmpty
        }
    }
}

private extension EnclosingScopeNames {
    /// The names a type's scope may supply, read once per type.
    struct Facts {
        /// The supertypes, followed transitively, that the tree does not declare, read as written in an inheritance clause.
        let unseen: Set<String>
        /// The type itself where the tree does not declare it or a typealias spells it with sugar, and the types a typealias of its name stands for that the tree does not declare, read as the type the scope is.
        let unseenSelves: Set<String>
        /// The generic parameters its declarations write.
        let generics: Set<String>
        /// Whether it, an extension of it or a supertype the tree declares carries an attribute that may be an attached macro.
        let carriesMacro: Bool
        /// Whether the tree declares a type or a typealias of its name, whose own declaration says what its scope holds.
        let isDeclared: Bool
    }
}
