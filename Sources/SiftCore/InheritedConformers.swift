//
// Copyright © Agulhas Labs
//

/// The conformers a grep for a protocol's or class's name does not find: a refining protocol's conformers and refiners, and a conforming class's subclasses, walked to any depth from the rows already listed.
///
/// The index store records an inheritance only as a clause writes it (`Zed: PS`, `Sub2: Sub`), and so does the scan by written name, so the closure is walked here, by written name, in both modes, and each row it reaches is checked against the index store before it is added or walked further, where one can speak for the row; where none can, the row is kept, since a row too many is the cheaper error than one left out. A row seeded through one of the asked type's own typealiases is the exception: the store records its clause against the alias rather than the asked type, so it is not checked as a reached row is, but judged through the alias, as `init` describes, and no row walked from it is put to the store, since the store vouches for no seeded row. Each row is added once, so a cycle of clauses ends; a row already listed, or a declaration of the asked type itself, is never added again.
struct InheritedConformers {
    /// The rows the walk reached, nearest first, each depth in file and line order, so every row's `through` names a row listed above it.
    let rows: [Row]

    /// The clause a caption defines `inherited` with.
    static var definition: String {
        "inherited is reached through a listed protocol or class, so a grep for the name does not find it"
    }

    /// Walks the inheritors of every protocol or class among `listed` and of every class an extension among them extends, leaving out `listed` and the `asked` declarations, and never walking `name` itself again.
    ///
    /// Where `seedsOwnAliases` is set, the types whose clause writes one of its own typealiases come first, each marked with the alias, and are walked like `listed`: the store records such a clause against the alias, and a grep for the class's name does not find it. They are never put to the store, which records them inheriting from the alias rather than the class, so they are kept, and so is every row walked from them.
    ///
    /// The closure taking an alias is the index store's word on such an alias: `false`, where it records the alias naming another type of the name, leaves the alias and the types written through it out; `true`, and `nil` where the store cannot speak for the alias, keep it, and with no such closure every alias is kept.
    ///
    /// The closure taking a type and an admitted alias is the index store's word on a type whose clause writes the alias's name: `true` where its reference to that alias sits at a head of the type's own clause, `false` where it records the type, in a file unchanged since the build, with no such reference, so the clause writes another alias of the name and the type is left to an alias that claims it, or, where none does and `confirm` records it inheriting from the asked type all the same, kept as inherited through the name, and `nil`, where it cannot speak for the type, keeps it, as with no such closure. A type kept without the store's `true` is marked with the alias of the name its source settles, where several are seeded: the one its clause writes behind a qualifier, or, written bare, the one declared in its own module; failing that, the first.
    ///
    /// `confirm` is the index store's word on a reached row: `true` keeps it, `false` leaves it out, and `nil`, where the store cannot speak for the row, keeps it, as with no store at all. The store is asked only of a row reached through a parent it vouches for, one of `vouched` among `listed` (which may include a listed row it refutes, where its record of that row is fresh) or a row it confirmed: through any other, its record of the step itself may be stale, and the row is kept, even where the store refuted it through another parent.
    init(
        of name: String,
        listed: [SymbolRow],
        asked: [SymbolRow],
        store: IndexStore,
        vouched listedVouched: Set<Int64> = [],
        confirm: ((SymbolRow) throws -> Bool?)? = nil,
        seedsOwnAliases: Bool = false,
        admitsAlias: ((SymbolRow) throws -> Bool?)? = nil,
        seedFor: ((SymbolRow, SymbolRow) throws -> Bool?)? = nil
    ) throws {
        var seen = Set(listed.map(\.id) + asked.map(\.id))
        var vouched = listedVouched
        var refuted: Set<Int64> = []
        var conformers: [String: [SymbolRow]] = [:]
        var aliases = Aliases(store: store)
        var found: [Row] = []
        if seedsOwnAliases {
            // A type whose clause writes another alias of the name may still inherit from the asked type through what
            // that alias names; where the store records it doing so it is kept, as inherited, once no admitted alias claims it.
            var inheriting: [Row] = []
            let seeds = try aliases.seeds(for: name, admits: admitsAlias)
            for seed in seeds where seed.alias.name != name {
                for row in try store.conformers(of: seed.alias.name) where !seen.contains(row.id) {
                    let verdict = try seedFor?(row, seed.alias)
                    if verdict == false {
                        if try confirm?(row) == true {
                            inheriting.append(Row(row: row, through: seed.alias.name))
                        }
                        continue
                    }
                    seen.insert(row.id)
                    // Where the store cannot speak for the row, its source may still name which alias of the name it writes.
                    let mark = try verdict == true ? seed.mark : aliases.mark(of: row, writing: seed.alias.name, among: seeds) ?? seed.mark
                    found.append(Row(row: row, through: seed.alias.name, alias: mark))
                }
            }
            for row in inheriting where seen.insert(row.row.id).inserted {
                found.append(row)
            }
            found.sort { ($0.row.path, $0.row.line) < ($1.row.path, $1.row.line) }
        }
        var frontier = listed + found.map(\.row)
        while !frontier.isEmpty {
            var reached: [Row] = []
            for parent in frontier {
                guard let walk = try Self.walk(of: parent, store: store), walk.name != name else { continue }
                let asks = confirm.flatMap { vouched.contains(parent.id) ? $0 : nil }
                for step in try [walk] + aliases.standing(for: walk) where step.name != name {
                    if conformers[step.name] == nil {
                        conformers[step.name] = try store.conformers(of: step.name)
                    }
                    for row in conformers[step.name] ?? [] where !seen.contains(row.id) && !(asks != nil && refuted.contains(row.id)) {
                        guard try step.reaches(row, store: store) else { continue }
                        let verdict = try asks?(row)
                        if verdict == false {
                            refuted.insert(row.id)
                            continue
                        }
                        if verdict == true {
                            vouched.insert(row.id)
                        }
                        seen.insert(row.id)
                        reached.append(Row(row: row, through: step.name))
                    }
                }
            }
            reached.sort { ($0.row.path, $0.row.line) < ($1.row.path, $1.row.line) }
            found += reached
            frontier = reached.map(\.row)
        }
        rows = found
    }

    /// The name a row's inheritors write, and which of the types writing it inherit from it; `nil` for a type nothing inherits from.
    ///
    /// A protocol's or class's inheritors write its own name, and an extension of a class the tree declares the class's. An extension of a type the tree declares nowhere can only add a conformance to a class from outside the tree, and only a class writing that name first, as its superclass, inherits it, so a raw-value enum writing `String` is never reached.
    private static func walk(of row: SymbolRow, store: IndexStore) throws -> Walk? {
        let name = DeclaredTypeName.last(ofPath: row.name)
        switch row.kind {
        case .protocolKind, .classKind:
            return Walk(name: name, superclassOnly: false)
        case .extensionKind:
            let declared = try store.typeDeclarations(named: name)
            if declared.isEmpty {
                return Walk(name: name, superclassOnly: true)
            }
            return declared.contains { $0.kind == .classKind } ? Walk(name: name, superclassOnly: false) : nil
        default:
            return nil
        }
    }
}

extension InheritedConformers {
    /// One conformer the walk reached, and the simple name of the listed protocol or class it was reached through.
    struct Row {
        let row: SymbolRow
        let through: String
        /// The asked class's own typealias the row's clause writes, as the row's mark names it, for a row reached through one: its qualified spelling, followed by what it writes where that reaches the name behind a qualifier; `nil` for a row inherited through a listed or walked type.
        var alias: String?
    }

    /// The tree's typealiases, read once a walk first asks.
    private struct Aliases {
        let store: IndexStore
        private var rows: [SymbolRow]?

        init(store: IndexStore) {
            self.store = store
        }

        /// A walk of each typealias whose right-hand side writes the name `walk` is of, behind any qualifier, and of each alias of such an alias in turn, each alias once, so a cycle of aliases ends.
        ///
        /// A qualifier is not checked against the tree: the walk is by written name, so a row too many is the cheaper error than one left out, and the store's check on each row stands wherever it can speak. An alias is walked again from every parent, since a row the store refuted through a parent it vouches for may be true through another.
        mutating func standing(for walk: Walk) throws -> [Walk] {
            try standing(for: walk.name).map { Walk(name: $0.name, superclassOnly: walk.superclassOnly) }
        }

        /// Each typealias whose right-hand side writes `name`, behind any qualifier, and each alias of such an alias in turn, each alias once, so a cycle of aliases ends.
        mutating func standing(for name: String) throws -> [SymbolRow] {
            let rows = try rows ?? store.everyTypealias()
            self.rows = rows
            var walked: Set<Int64> = []
            var found: [SymbolRow] = []
            var pending = [name]
            while let target = pending.popLast() {
                for alias in rows where !walked.contains(alias.id) && Self.writes(target, in: alias) {
                    walked.insert(alias.id)
                    found.append(alias)
                    pending.append(alias.name)
                }
            }
            return found
        }

        /// The typealiases `standing(for:)` finds for `name`, less each one `admits` refutes, each with the mark a type written through it carries.
        ///
        /// An alias `admits` refutes is not followed, but one written through an alias the store does not vouch for is kept whatever the store says of it, since its record of what it names is no fresher than its record of the alias it writes.
        mutating func seeds(for name: String, admits: ((SymbolRow) throws -> Bool?)?) throws -> [(alias: SymbolRow, mark: String)] {
            let rows = try rows ?? store.everyTypealias()
            self.rows = rows
            var walked: Set<Int64> = []
            var found: [(alias: SymbolRow, mark: String)] = []
            var pending = [(name: name, unsure: false)]
            while let target = pending.popLast() {
                for alias in rows where !walked.contains(alias.id) {
                    guard let member = Self.member(writing: target.name, in: alias) else { continue }
                    let verdict = try admits?(alias)
                    guard verdict != false || target.unsure else { continue }
                    walked.insert(alias.id)
                    let spelling = try store.qualifiedName(of: alias)
                    let qualified = QualifiedPath.components(of: DeclaredTypeName.path(ofSpelling: member)).count > 1
                    found.append((alias, qualified ? "\(spelling) = \(Self.underlying(of: alias))" : spelling))
                    pending.append((alias.name, verdict != true))
                }
            }
            return found
        }

        /// The mark of the one alias among `seeds` named `name` that `row`'s source attributes its clause to: the alias the clause writes behind a qualifier spelling its owner, or, where it writes the name bare, the alias declared in the row's own module; `nil` where the source names no single one of several.
        ///
        /// Swift resolves a bare name to its own module's declaration before an imported one, so the source settles the alias without the store.
        func mark(of row: SymbolRow, writing name: String, among seeds: [(alias: SymbolRow, mark: String)]) throws -> String? {
            let named = seeds.filter { $0.alias.name == name }
            guard named.count > 1 else { return nil }
            let written = try Set(InheritedClause.components(of: store.inheritedNames(of: row.id), naming: name))
            guard written.count == 1, let spelling = written.first else { return nil }
            let claiming = try named.filter { seed in
                guard spelling.contains(".") else { return seed.alias.module == row.module }
                return try ("." + store.qualifiedName(of: seed.alias)).hasSuffix("." + spelling)
            }
            return claiming.count == 1 ? claiming[0].mark : nil
        }

        /// Whether the right-hand side of `alias`, or a member of the composition it writes, is `name`, bare or behind any qualifier.
        private static func writes(_ name: String, in alias: SymbolRow) -> Bool {
            member(writing: name, in: alias) != nil
        }

        /// The member of the right-hand side of `alias` that is `name`, bare or behind any qualifier, as written: the whole of it, or a member of the composition it writes.
        private static func member(writing name: String, in alias: SymbolRow) -> String? {
            // Most aliases never write the name, so they are passed over before any spelling is parsed.
            guard let equals = alias.signature.firstIndex(of: "="), alias.signature[equals...].contains(name) else { return nil }
            return alias.signature[alias.signature.index(after: equals)...].split(separator: "&").lazy.map { member in
                let spelling = member.trimmingCharacters(in: .whitespaces)
                return spelling.hasPrefix("any ") ? spelling.dropFirst(4).trimmingCharacters(in: .whitespaces) : spelling
            }.first { QualifiedPath.components(of: DeclaredTypeName.path(ofSpelling: $0)).last == name }
        }

        /// The right-hand side of `alias` as written.
        private static func underlying(of alias: SymbolRow) -> String {
            guard let equals = alias.signature.firstIndex(of: "=") else { return "" }
            return alias.signature[alias.signature.index(after: equals)...].trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    /// The name a parent's inheritors write, and whether only a class writing it first inherits from the parent.
    private struct Walk {
        let name: String
        let superclassOnly: Bool

        /// Whether `row`, a declaration whose clause writes `name`, inherits from the parent this walk is of.
        func reaches(_ row: SymbolRow, store: IndexStore) throws -> Bool {
            guard superclassOnly else { return true }
            guard row.kind == .classKind, let first = try store.inheritedNames(of: row.id).first else { return false }
            return InheritedClause.names(name, in: [first])
        }
    }
}
