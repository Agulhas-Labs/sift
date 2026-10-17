//
// Copyright © Agulhas Labs
//

/// Which declaration a typealias's name written at a site means, where the answer folds the alias in as another name for a type.
///
/// Swift looks the name up as it looks up any bare type name: in the body around the site, then the type the site is written in, its supertypes, the types around it, and last the top level. So a nested scope declaring its own of the name hides an alias of it declared further out, and a use written there means that one. A site reads as the alias only where the walk reaches the alias and nothing else of the name; as another declaration only where the first scope out holding the name holds only declarations the walk can be certain of, one of them compiled in every build its type is; and as undecided wherever a qualifier, a supertype outside the index where the name has a declaration other than the aliases, a body's own declaration, two declarations at one level or a capped chain leaves it unsaid.
struct AliasNameScope {
    private let store: IndexStore
    private let name: String
    private let aliases: Set<Int64>
    /// Every declaration of the name the index holds that is not one of the aliases, with the flattened names of the types it is nested in, outermost first.
    private let others: [(row: SymbolRow, parents: [String])]
    /// The aliases, with the same parents.
    private let own: [(row: SymbolRow, parents: [String])]
    private let reachedCap: Bool
    /// A repo-relative file's current text, which names the `#if` an `#else` clause closes; `nil` leaves a declaration under an `#else` read as conditional.
    private let source: ((String) -> String?)?
    /// Per file, the `line:column` each declaration of the name the index holds starts at, which tells a declaration a scan of the blocks around a site finds in a type or at the top level from one a body declares: a body's may share a row's line, never its start.
    private let indexedStarts: [String: Set<String>]
    private var typealiasTargets: [String: Set<String>]?
    private var reached: [[String]: Reach] = [:]

    /// The scope of `name` for `aliases`, the typealiases of that name a chain folded in; `reachedCap` is whether the chain stopped at its cap, so an alias of the name left out of it may still name the type, and `source` reads a file as it stands.
    init(store: IndexStore, name: String, aliases: [SymbolRow], reachedCap: Bool, source: ((String) -> String?)? = nil) throws {
        self.store = store
        self.name = name
        self.source = source
        let ids = Set(aliases.map(\.id))
        self.aliases = ids
        self.reachedCap = reachedCap
        let declared: [(row: SymbolRow, parents: [String])] = try store.symbols(named: name)
            .filter { $0.kind.isTypeDeclaration || $0.kind == .typealiasKind || $0.kind == .associatedType }
            .map { try ($0, QualifiedPath.flattened(chain: store.parentChain(of: $0).map(\.name))) }
        others = declared.filter { !ids.contains($0.row.id) }
        own = declared.filter { ids.contains($0.row.id) }
        indexedStarts = declared.reduce(into: [:]) { $0[$1.row.path, default: []].insert("\($1.row.line):\($1.row.column)") }
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
        let indexed = indexedStarts[site.path] ?? []
        if site.localDeclarations?.contains(where: { !indexed.contains($0) }) == true {
            return .undecided
        }
        guard !others.isEmpty else { return .alias }
        guard site.qualifier == nil else { return .undecided }
        if site.meansOwnAssociatedType {
            return .another
        }
        return try reading(writtenIn: site.enclosingTypes, at: site)
    }

    /// What the name means written bare in a declaration nested in `enclosingTypes`, the flattened names of the types around it, outermost first.
    ///
    /// Never `.local`: a declaration in a type sees no body's own declarations. `site`, where the name is written, tells which copy of a type declared once per `#if` clause it is written in.
    mutating func reading(writtenIn enclosingTypes: [String], at site: SyntacticCallSite? = nil) throws -> Reading {
        guard !others.isEmpty else { return .alias }
        return switch try walked(enclosingTypes, at: site.map { ($0.path, $0.line) }) {
        case .aliases: .alias
        case .another: .another
        case .undecided: .undecided
        }
    }

    /// Which of the aliases the name written bare in a declaration nested in `enclosingTypes` reaches, the flattened names of the types around it, outermost first.
    ///
    /// The lookup stops at the first scope out holding a declaration of the name, so where several aliases are the name's, a nearer one hides a farther one. The name's only declaration is reached from anywhere. `position`, the file and line the name is written at, tells which copy of a type declared once per `#if` clause it is written in.
    ///
    /// At the top level a module's own declaration of the name hides every imported module's, so where `origin`, the module and file the name is written in, has a top-level declaration of the name certain to be its own module's, the lookup reaches those alone. Certain means its file's module and `origin`'s are both read from the package rather than guessed from the path, it is visible to `origin` (`internal` or wider, or declared in that same file), and it sits in no `#if` clause. Without one the top level reaches the aliases only where every top-level declaration of the name is one of them.
    mutating func reach(writtenIn enclosingTypes: [String], from origin: (module: String, path: String)? = nil, at position: (path: String, line: Int)? = nil) throws -> Reach {
        if own.count + others.count == 1 {
            return own.first.map { .aliases([$0.row.id]) } ?? .another
        }
        return try walked(enclosingTypes, from: origin, at: position)
    }

    private mutating func walked(_ enclosingTypes: [String], from origin: (module: String, path: String)? = nil, at site: (path: String, line: Int)?) throws -> Reach {
        // The top level's answer turns on the module and file the name is written in, so they are part of the key: the chain leads, these two close it.
        let key = enclosingTypes + [origin?.module ?? "", origin?.path ?? ""]
        if let known = reached[key] {
            return known
        }
        var position = SiteClauses(position: site)
        let reach = try walk(enclosingTypes, from: origin, at: &position)
        // A reach that read the site's own `#if` clauses holds for that site alone.
        if !position.wasRead {
            reached[key] = reach
        }
        return reach
    }

    private mutating func walk(_ chain: [String], from origin: (module: String, path: String)?, at site: inout SiteClauses) throws -> Reach {
        for level in chain.indices.reversed() {
            let scope = Array(chain[...level])
            let isHere = { (declaration: (row: SymbolRow, parents: [String])) in
                declaration.parents.count >= scope.count && Array(declaration.parents.suffix(scope.count)) == scope
            }
            let ownHere = own.filter(isHere)
            // A declaration in another clause's copy of a type declared once per `#if` clause is none the site sees, so the walk goes on as though this level declared nothing there.
            var othersHere: [(row: SymbolRow, parents: [String])] = []
            for other in others where isHere(other) {
                switch try applies(other.row, at: &site) {
                case true?: othersHere.append(other)
                case false?: continue
                case nil: return .undecided
                }
            }
            if !ownHere.isEmpty || !othersHere.isEmpty {
                // Two types at one path leave which the site is inside unsaid; each must declare one of the name.
                guard try everyType(named: chain[level], at: scope, declaresOneOf: ownHere + othersHere) else { return .undecided }
                if othersHere.isEmpty {
                    return .aliases(Set(ownHere.map(\.row.id)))
                }
                // An alias the capped chain left out may still be another name for the type, and a declaration only some builds compile leaves the name to the alias in the others.
                let certain = try ownHere.isEmpty && othersHere.allSatisfy { $0.row.kind != .associatedType && !(reachedCap && $0.row.kind == .typealiasKind) }
                    && isCompiledAlways(othersHere.map(\.row))
                return certain ? .another : .undecided
            }
            if typealiasTargets == nil {
                typealiasTargets = try MemberReceivers.aliasedNames(in: store.everyTypealias())
            }
            let supertypes = try MemberReceivers(store: store).supertypes(of: [chain[level]], aliases: typealiasTargets ?? [:])
            // A supertype outside the index may hold one of the name nearer; the walk goes past it only where every declaration of the name is one of the aliases, the uncertainty the name's only declaration is reached with.
            let passesUnseen = supertypes.unseen.isEmpty || others.isEmpty
            // An inherited declaration of the name is found before an outer one, so it is the reach where each is one of the aliases and every type of its supertype's name declares one.
            let inherited = (own + others).filter { $0.parents.last.map(supertypes.names.contains) == true }
            if !inherited.isEmpty {
                let declaring = Set(inherited.compactMap(\.parents.last))
                guard passesUnseen, inherited.allSatisfy({ aliases.contains($0.row.id) }),
                      try declaring.allSatisfy({ try everyType(named: $0, at: [$0], declaresOneOf: inherited) }) else { return .undecided }
                return .aliases(Set(inherited.map(\.row.id)))
            }
            guard passesUnseen else { return .undecided }
        }
        var topLevel = (own + others).filter(\.parents.isEmpty)
        if let origin {
            let ownModule = try topLevel.filter { try isCertainlyOwnModule($0.row, from: origin) }
            if !ownModule.isEmpty {
                topLevel = ownModule
            }
        }
        return !topLevel.isEmpty && topLevel.allSatisfy { aliases.contains($0.row.id) } ? .aliases(Set(topLevel.map(\.row.id))) : .undecided
    }

    /// Whether `row`, a top-level declaration of the name, is certainly one `origin`'s module declares and `origin` sees: both files' modules read from the package, `row` visible there and in no `#if` clause.
    private func isCertainlyOwnModule(_ row: SymbolRow, from origin: (module: String, path: String)) throws -> Bool {
        guard row.module == origin.module, row.ifConfigCondition == nil, row.accessLevel >= .internalLevel || row.path == origin.path else { return false }
        return try [row.path, origin.path].allSatisfy { try store.fileRow(path: $0)?.moduleGuessed == false }
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

    /// Whether one of `rows`, declarations of the name in one type, is compiled in every build the type is: one under no `#if` clause inside the type, or one in each clause of an `#if` chain closing with an `#else`.
    private func isCompiledAlways(_ rows: [SymbolRow]) throws -> Bool {
        var clauses: Set<String> = []
        for row in rows {
            let own = try clausesInsideItsType(row)
            if own.isEmpty {
                return true
            }
            if own.count == 1 {
                clauses.insert(own[0])
            }
        }
        let closing = "#else of "
        return clauses.contains { $0.hasPrefix(closing) && Self.holds(clauses, chain: String($0.dropFirst(closing.count))) }
    }

    /// Whether `row`, a declaration of the name in a type, is in the copy of that type the site is written in: the type's `#if` clauses must open the site's own; `nil` where the site's cannot be read, or the type's `#else` cannot be named.
    ///
    /// A site given no position reads every declaration as its own.
    private func applies(_ row: SymbolRow, at site: inout SiteClauses) throws -> Bool? {
        guard let parent = try store.parentChain(of: row).last, parent.kind.isTypeDeclaration else { return true }
        let outer = Self.clauses(of: IfConfigLabel.label(for: parent, source: source))
        guard !outer.isEmpty else { return true }
        let own = site.clauses(source: source)
        guard site.position != nil else { return true }
        // A label falls back to the bare `#else` or `#elseif` the index stored where the file has moved since, which a site's own label never writes.
        guard !outer.contains(where: { $0.hasPrefix("#else") && !$0.contains(" of ") }), let own else { return nil }
        return own.starts(with: outer)
    }

    /// The `#if` clauses `row` sits under inside the type declaring it, outermost first, as ``IfConfigLabel`` names them: a site inside a type is compiled only where the type is, so the type's own clauses say nothing, while an extension's do.
    private func clausesInsideItsType(_ row: SymbolRow) throws -> [String] {
        let clauses = Self.clauses(of: IfConfigLabel.label(for: row, source: source))
        guard let parent = try store.parentChain(of: row).last, parent.kind.isTypeDeclaration else { return clauses }
        let outer = Self.clauses(of: IfConfigLabel.label(for: parent, source: source))
        return clauses.starts(with: outer) ? Array(clauses.dropFirst(outer.count)) : clauses
    }

    /// A label's clauses, outermost first: they are joined by ` && `, and each opens with `#`, which no condition holds.
    private static func clauses(of label: String?) -> [String] {
        guard let label else { return [] }
        let parts = label.components(separatedBy: " && #")
        return [parts[0]] + parts.dropFirst().map { "#" + $0 }
    }

    /// Whether `clauses` holds each clause of the chain an `#else` closes, written as its label names them (`#if A, #elseif B`): the first as itself and each after it as `clause of` those before, `earlier` the part already found.
    private static func holds(_ clauses: Set<String>, chain: String, earlier: String = "") -> Bool {
        clauses.contains { label in
            let suffix = " of " + earlier
            guard earlier.isEmpty ? label.hasPrefix("#if ") : label.hasPrefix("#elseif ") && label.hasSuffix(suffix) else { return false }
            let clause = earlier.isEmpty ? label : String(label.dropLast(suffix.count))
            let found = earlier.isEmpty ? clause : earlier + ", " + clause
            return found == chain || chain.hasPrefix(found + ", ") && holds(clauses, chain: chain, earlier: found)
        }
    }
}

private extension AliasNameScope {
    /// The `#if` clauses a site sits under, outermost first, as ``IfConfigLabel`` names them, read from its file the first time a declaration asks.
    struct SiteClauses {
        /// The file and line the name is written at.
        let position: (path: String, line: Int)?
        /// Whether a declaration in a type under an `#if` clause asked, which makes the walk's reach this site's alone.
        private(set) var wasRead = false
        private var read: [String]?

        init(position: (path: String, line: Int)?) {
            self.position = position
        }

        /// The clauses, or `nil` where the site's file cannot be read.
        mutating func clauses(source: ((String) -> String?)?) -> [String]? {
            if !wasRead {
                wasRead = true
                read = position.flatMap { position in source?(position.path).map { AliasNameScope.clauses(of: IfConfigLabel.label(line: position.line, in: $0)) } }
            }
            return read
        }
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
