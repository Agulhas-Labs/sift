//
// Copyright © Agulhas Labs
//

import Foundation

/// The types a call of a qualified member may be written on, read from the index's declarations and inheritance clauses.
struct MemberReceivers {
    let store: IndexStore

    /// The lookup for a query written under `qualifiers`, or `nil` for an unqualified one, whose calls are not narrowed by receiver.
    static func lookup(qualifiedBy qualifiers: some Collection<String>, in store: IndexStore) -> ((Set<String>) throws -> ((SyntacticCallSite) throws -> ReceiverReach)?)? {
        guard !qualifiers.isEmpty else { return nil }
        return MemberReceivers(store: store).narrowing
    }

    /// Whether a call site may reach a member declared on one of `owners`, and why it is kept, or `nil` where a call on any type may.
    ///
    /// A written receiver is another type's only where it is none of the types reaching the owners, no typealias, associated type, case, function or property the repository declares, no value the site's file binds, written behind no dot, and either a type the repository declares in sight of the site — at the top level, under no `#if`, in the site's module and, where private, its file — whose every supertype the repository declares, or, where none is in sight and no type the repository declares of the name has a supertype outside it, a framework type known to hand on no other type's members; a call with no receiver or on `self` is kept inside those types, their supertypes, an extension or a function constrained to any of them, a protocol that requires `Self` to be one or inherits a protocol that does, and, where a supertype may be declared outside the repository, any type the repository does not declare.
    ///
    /// A type with a `subscript(dynamicMember:)`, which may hand on any member of another type, is never another type's: a site written on it or inside it is kept.
    ///
    /// Nor is a name a scope around the site may supply ahead of the tree's type of it, or one written inside or on a type carrying an attached macro, as `EnclosingScopeNames` reads them.
    func narrowing(_ owners: Set<String>) throws -> ((SyntacticCallSite) throws -> ReceiverReach)? {
        let aliases = try Self.aliasedNames(in: store.everyTypealias())
        var written: Set<String> = []
        for owner in owners {
            guard let reached = try reaching(owner, aliases: aliases) else { return nil }
            written.formUnion(reached)
        }
        let (supertypes, unseen) = try supertypes(of: written, aliases: aliases)
        let enclosing = written.union(supertypes)
        let dynamic = try dynamicMemberTypes(aliases: aliases)
        let scopeNames = EnclosingScopeNames(receivers: self, aliases: aliases)
        return { site in
            switch site.receiver {
            case nil:
                return .untyped
            case let .type(name, mayBeUnseen, isQualified):
                guard !written.contains(name), !dynamic.contains(name) else { return .reaches }
                let declared = try store.symbols(named: name)
                guard !declared.contains(where: \.kind.isTypeStandIn) else { return .reaches }
                // A case, function or property of the name may be what the site writes, and build or hold the owner.
                guard !declared.contains(where: \.kind.namesAValue) else { return .untyped }
                // A qualifier the scan does not resolve may be a module whose type of the name is not the tree's.
                guard !isQualified else { return .outsideTree }
                let isTreeType = try declared.contains { try isSeen($0, from: site) }
                // A name written in an extension may be the extended type's generic parameter, any type where the tree declares none of the name in sight.
                guard isTreeType || !mayBeUnseen else { return .outsideTree }
                // A tree type of the name, in sight or not, may hand on any member through a supertype outside the tree, and a type only a framework declares through a dynamic member subscript the tree cannot show.
                let declaresType = declared.contains(where: \.kind.isTypeDeclaration)
                guard try !declaresType || self.supertypes(of: [name], aliases: aliases).unseen.isEmpty else { return .outsideTree }
                guard isTreeType || PlainFrameworkTypes.contains(name) else { return .outsideTree }
                // A scope around the site may supply the name ahead of the tree's type of it, and a macro may reshape either.
                return try scopeNames.keeping(name, at: site) ?? .another
            case .enclosingSelf:
                let around = site.enclosingTypes + site.enclosingConstraints
                guard !site.enclosingTypes.isEmpty, !around.contains(where: { enclosing.contains($0) || dynamic.contains($0) }) else { return .reaches }
                guard try !around.contains(where: { try requiresSelf($0, toBeOneOf: enclosing, aliases: aliases) }) else { return .reaches }
                var reach = ReceiverReach.another
                for name in site.enclosingTypes {
                    let declared = try store.symbols(named: name)
                    if declared.contains(where: \.kind.isTypeStandIn) {
                        return .reaches
                    }
                    if !unseen.isEmpty, !declared.contains(where: \.kind.isTypeDeclaration) {
                        reach = .outsideTree
                    }
                }
                return reach
            }
        }
    }

    /// Whether `row` is a type declaration a bare name written at `site` finds: at the top level, under no `#if`, in the site's module, and in the site's file where it is private.
    private func isSeen(_ row: SymbolRow, from site: SyntacticCallSite) throws -> Bool {
        guard row.kind.isTypeDeclaration, row.parentID == nil, row.ifConfigCondition == nil else { return false }
        guard row.accessLevel > .fileprivateLevel || row.path == site.path else { return false }
        return try store.fileRow(path: site.path)?.module == row.module
    }

    /// `type` and every type whose inheritance clause names it or a typealias standing for it, followed transitively, or `nil` where a call on any type may reach its members.
    ///
    /// `nil` for a protocol, whose members are reached through conformers and generic parameters the scan cannot see, and for a type the repository does not declare, whose subclasses and conformances may live in a framework. A typealias whose right-hand side names a reached type is reached itself, so a type inheriting from the alias is followed too.
    func reaching(_ type: String, aliases: [String: Set<String>]) throws -> Set<String>? {
        let declared = try store.symbols(named: type).filter(\.kind.isTypeDeclaration)
        guard !declared.isEmpty, !declared.contains(where: { $0.kind == .protocolKind }) else { return nil }
        return try inheriting([type], aliases: aliases)
    }

    /// Every type the repository gives a `subscript(dynamicMember:)`, in its declaration or an extension, with every type inheriting from one, through which a member written on it may be another type's.
    func dynamicMemberTypes(aliases: [String: Set<String>]) throws -> Set<String> {
        var declaring: Set<String> = []
        for row in try store.symbols(named: "subscript") where row.kind == .subscriptKind && row.name.hasPrefix("subscript(dynamicMember:") {
            guard let parentID = row.parentID, let parent = try store.symbol(withID: parentID) else { continue }
            declaring.insert(DeclaredTypeName.last(ofPath: parent.name))
        }
        return try inheriting(declaring, aliases: aliases)
    }

    /// `types` and every type whose inheritance clause names one of them or a typealias standing for one, followed transitively.
    private func inheriting(_ types: Set<String>, aliases: [String: Set<String>]) throws -> Set<String> {
        var reached = types
        var pending = Array(types)
        while let next = pending.popLast() {
            let conformers = try store.conformers(of: next).map { DeclaredTypeName.last(ofPath: $0.name) }
            let standIns = aliases.filter { $0.value.contains(next) }.map(\.key)
            for name in conformers + standIns where reached.insert(name).inserted {
                pending.append(name)
            }
        }
        return reached
    }

    /// Every type `types` inherit from, followed transitively through their declarations' and extensions' inheritance clauses and the typealiases those clauses name, and those among them the repository may not declare, whose own supertypes it cannot show.
    ///
    /// A name counts as declared only where every type, typealias and associated type of that name the repository holds is at the top level: an inheritance clause names a nested one only from inside its parent, so beside a nested type of the name it may name a framework's.
    func supertypes(of types: Set<String>, aliases: [String: Set<String>]) throws -> (names: Set<String>, unseen: Set<String>) {
        var names: Set<String> = []
        var unseen: Set<String> = []
        var visited = types
        var pending = Array(types)
        let modules = try Set(store.moduleNames())
        while let next = pending.popLast() {
            try unseen.formUnion(foreignQualified(by: next, aliases: aliases, modules: modules))
            for name in try inherited(by: next, aliases: aliases) {
                names.insert(name)
                guard visited.insert(name).inserted else { continue }
                if try aliases[name] != nil || !store.typeDeclarations(named: name).isEmpty {
                    pending.append(name)
                    if try hasNestedDeclaration(named: name) {
                        unseen.insert(name)
                    }
                } else {
                    unseen.insert(name)
                }
            }
        }
        return (names, unseen)
    }

    /// The simple names of the supertypes `name`'s inheritance clauses write behind a qualifier that is no module, type or typealias of the repository: a dependency's type, whatever the repository declares under the same simple name.
    private func foreignQualified(by name: String, aliases: [String: Set<String>], modules: Set<String>) throws -> Set<String> {
        var foreign: Set<String> = []
        for row in try store.typeDeclarations(named: name) + store.extensions(ofTypeNamed: name) {
            for entry in try store.inheritedNames(of: row.id) {
                for path in InheritedClause.components(of: entry) {
                    let segments = path.prefix { $0 != "<" }.split(separator: ".").map(String.init)
                    guard segments.count > 1, let qualifier = segments.first, !modules.contains(qualifier), aliases[qualifier] == nil else { continue }
                    if try store.typeDeclarations(named: qualifier).isEmpty {
                        foreign.insert(DeclaredTypeName.last(ofPath: path))
                    }
                }
            }
        }
        return foreign
    }

    /// Whether a type, typealias or associated type the repository declares under `name` sits inside another declaration.
    private func hasNestedDeclaration(named name: String) throws -> Bool {
        try store.symbols(named: name).contains { ($0.kind.isTypeDeclaration || $0.kind.isTypeStandIn) && $0.parentID != nil }
    }

    /// Whether `name` is a protocol, or a typealias for one, whose where clause — or that of a protocol it inherits, followed transitively — names one of `types`, so a call inside an extension of it may run on one of them.
    private func requiresSelf(_ name: String, toBeOneOf types: Set<String>, aliases: [String: Set<String>]) throws -> Bool {
        var visited: Set<String> = [name]
        var pending = [name]
        while let next = pending.popLast() {
            let protocols = try store.typeDeclarations(named: next).filter { $0.kind == .protocolKind }
            guard !protocols.isEmpty || aliases[next] != nil else { continue }
            let required = protocols.flatMap { Self.whereClauseNames(in: $0.signature) }
            guard !required.contains(where: types.contains) else { return true }
            for parent in try required + inherited(by: next, aliases: aliases) where visited.insert(parent).inserted {
                pending.append(parent)
            }
        }
        return false
    }

    /// The simple names `name` inherits from: every component of its declarations' and extensions' inheritance clauses, read by `InheritedClause`, and every name a typealias by that name stands for.
    private func inherited(by name: String, aliases: [String: Set<String>]) throws -> [String] {
        var names = Array(aliases[name] ?? [])
        for row in try store.typeDeclarations(named: name) + store.extensions(ofTypeNamed: name) {
            for entry in try store.inheritedNames(of: row.id) {
                names += InheritedClause.components(of: entry).map { DeclaredTypeName.last(ofPath: $0) }
            }
        }
        return names
    }

    /// Each typealias's name, with every type name its right-hand side writes — both sides of a composition, a generic type's arguments as well as the type — by the last component of a dotted path.
    ///
    /// A superset of what the alias stands for, so following it can only keep more; one whose right-hand side writes no name is left out, so an inheritance clause naming it reads as naming a type the repository does not declare.
    static func aliasedNames(in rows: [SymbolRow]) -> [String: Set<String>] {
        var aliases: [String: Set<String>] = [:]
        for row in rows {
            guard let equals = row.signature.firstIndex(of: "=") else { continue }
            let names = typeNames(in: row.signature[row.signature.index(after: equals)...])
            guard !names.isEmpty else { continue }
            aliases[row.name, default: []].formUnion(names)
        }
        return aliases
    }

    /// Every name a protocol declaration's where clause writes, by the last component of a dotted path — `[]` for one without a where clause.
    private static func whereClauseNames(in signature: String) -> [String] {
        guard let clause = signature.firstRange(of: #/\bwhere\b/#) else { return [] }
        return typeNames(in: signature[clause.upperBound...])
    }

    /// Every identifier path written in `text`, by its last component, leaving out the `any` and `some` keywords.
    private static func typeNames(in text: Substring) -> [String] {
        text.matches(of: #/[A-Za-z_][A-Za-z0-9_]*(?:\.[A-Za-z_][A-Za-z0-9_]*)*/#)
            .map { DeclaredTypeName.last(ofPath: $0.output) }
            .filter { $0 != "any" && $0 != "some" }
    }
}

private extension SymbolKind {
    /// Whether a declaration of this kind names some other type, which a call written on its name may be made on.
    var isTypeStandIn: Bool {
        self == .typealiasKind || self == .associatedType
    }

    /// Whether a declaration of this kind names a value or a function, which a name written like a type may be.
    var namesAValue: Bool {
        self == .function || self == .variable || self == .enumCase
    }
}
