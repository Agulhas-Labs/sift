//
// Copyright © Agulhas Labs
//

/// Which declarations of a `where` query semantic relations are resolved for, and the note naming the ones the cap left out.
struct SemanticTargets {
    /// The most declarations one answer resolves, overload sets included: as many as it lists, so no resolved declaration is one the reader cannot see.
    static var ceiling: Int {
        WhereRenderer.listCap
    }

    /// The first `semanticDeclCap` declarations that take a place, then every overload sharing a qualified name with one of them, up to ``ceiling``; and every extension of a type no declaration here declares, outside both counts.
    ///
    /// An extension of a type a listed declaration declares takes a place only once every other declaration has one, since that type answers for it wherever the type's file sorts. An extension of a type no declaration here declares answers for itself, by the lines writing the name it extends, and costs no store query, so however many declarations sort before it, it is always resolved. Overloads differing only in parameter types are one name to the reader, and no query narrows to one of them, so the cap never splits a set it can hold.
    static func of(_ declarations: [SymbolRow], in store: IndexStore) throws -> [SymbolRow] {
        try Pick(declarations, in: store).targets
    }

    /// The overloads past ``ceiling``: declarations of a qualified name an answer resolves, which no query narrows to, so their call sites by written name are the only trace of them there is.
    static func pastCeiling(_ declarations: [SymbolRow], in store: IndexStore) throws -> [SymbolRow] {
        try Pick(declarations, in: store).leftOut(in: store).unreachable
    }

    /// The line naming each declaration that takes a place but was left out, with how to have it resolved; `nil` where none was.
    ///
    /// One whose qualified name an answer can resolve is named by it, with that remedy; one in an overload set too large for ``ceiling`` is given by its file and line, since asking by its qualified name returns the same set and leaves it out again. Its call sites are listed by written name where `includeReferences`, and otherwise `--refs` is named as listing them.
    static func capNote(for declarations: [SymbolRow], includeReferences: Bool, in store: IndexStore) throws -> String? {
        let pick = try Pick(declarations, in: store)
        let (named, unreachable) = try pick.leftOut(in: store)
        guard !named.isEmpty || !unreachable.isEmpty else { return nil }
        let cap = WhereRenderer.semanticDeclCap
        var clauses: [String] = []
        if !named.isEmpty {
            let more = named.count > cap ? " and \(named.count - cap) more" : ""
            clauses.append("not for \(named.prefix(cap).joined(separator: ", "))\(more); ask `where` of one by its qualified name to resolve it")
        }
        if !unreachable.isEmpty {
            let sites = unreachable.map { "\($0.path):\($0.line)" }.joined(separator: ", ")
            let remedy = includeReferences ? "their call sites are listed below by written name" : "`--refs` lists their call sites by written name"
            clauses.append("\(named.isEmpty ? "not" : "nor") for the overloads at \(sites), past the \(ceiling) one answer resolves; they share a qualified name with the rest of their set, so no query narrows to them, but \(remedy)")
        }
        return "(semantic relations resolved for the first \(pick.targets.count) declarations only — \(clauses.joined(separator: "; ")))"
    }
}

extension SemanticTargets {
    /// The declarations in the order they take places, and those picked.
    private struct Pick {
        let ordered: [SymbolRow]
        let targets: [SymbolRow]

        init(_ declarations: [SymbolRow], in store: IndexStore) throws {
            let declaredPaths = try ExtensionPaths.declared(among: declarations, in: store)
            let extensions = declarations.filter { $0.kind == .extensionKind }
            let undeclared = extensions.filter { !declaredPaths.contains($0.name) }
            let ordered = declarations.filter { $0.kind != .extensionKind } + extensions.filter { declaredPaths.contains($0.name) }
            let first = ordered.prefix(WhereRenderer.semanticDeclCap)
            // Only a declaration of a picked one's module and name can share its qualified name, so only those are asked for theirs.
            let overloadable = first.filter { $0.kind != .extensionKind }
            let keys = Set(overloadable.map { "\($0.module)\u{0}\($0.name)" })
            let names = try Set(overloadable.map(store.qualifiedName(of:)))
            var targets = Array(first)
            for row in ordered.dropFirst(first.count) where targets.count < SemanticTargets.ceiling {
                guard row.kind != .extensionKind, keys.contains("\(row.module)\u{0}\(row.name)") else { continue }
                if try names.contains(store.qualifiedName(of: row)) {
                    targets.append(row)
                }
            }
            self.ordered = ordered
            self.targets = targets + undeclared
        }

        /// The qualified names an answer can resolve by asking for them, and the declarations no query reaches: overloads of a resolved name past the ceiling.
        func leftOut(in store: IndexStore) throws -> (named: [String], unreachable: [SymbolRow]) {
            let targetIDs = Set(targets.map(\.id))
            let resolvedNames = try Set(targets.map(store.qualifiedName(of:)))
            var named: [String] = []
            var unreachable: [SymbolRow] = []
            var rankInSet: [String: Int] = [:]
            for row in ordered where row.kind != .extensionKind {
                let name = try store.qualifiedName(of: row)
                let rank = rankInSet[name, default: 0]
                rankInSet[name] = rank + 1
                guard !targetIDs.contains(row.id) else { continue }
                if resolvedNames.contains(name) || rank >= SemanticTargets.ceiling {
                    unreachable.append(row)
                } else if !named.contains(name) {
                    named.append(name)
                }
            }
            return (named, unreachable)
        }
    }
}
