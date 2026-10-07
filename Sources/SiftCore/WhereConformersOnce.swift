//
// Copyright © Agulhas Labs
//

/// A protocol's conformers as one block under a store: each listed once, marked direct where an inheritance clause names the protocol and indirect where only the store has it.
///
/// Two blocks used to answer this — the store's and the scan by written name — listing the same conformers twice under captions that never said which of them conform directly, so a reader asking exactly that went back to grep.
struct ConformersOnce {
    /// The rendered block, a blank line first.
    let lines: [String]
    /// The repo-relative paths of the listed conformers' declarations, for the parse-error banner.
    let citedPaths: [String]
    /// The repo-relative `path:line` of each conformance the store recorded for a listed conformer, in a file unchanged since the build, of a protocol whose own declaration is in a file unchanged since the build too.
    ///
    /// A protocol's usage rows leave these lines out, because the block lists them; a file edited since the build keeps its lines there, since its recorded line may no longer be the clause.
    let clauseLines: Set<String>
}

extension ConformersOnce {
    /// One conformer: its declaration where the index has one, the store's conformance hits on it, and whether an inheritance clause names the protocol.
    struct Entry {
        var row: SymbolRow?
        var hits: [SemanticStore.Hit]
        var direct: Bool
        /// The typealias of the protocol the clause writes, for a conformer the store records only against that alias (`typealias P2 = P; struct S: P2`); `nil` otherwise.
        var alias: String?
        /// The most build units that recorded one of its hits, marked `×N units` on the row as every store block marks it.
        var units = 1
        /// The listed protocol or class a conformer the walk reached was reached through (``InheritedConformers``); `nil` for a row the store or a clause naming the protocol lists.
        var through: String?
    }

    /// Whether a declaration's name is the one the store related the conformance to, allowing for an extension written through its outer type.
    static func names(_ rowName: String, _ hitName: String) -> Bool {
        rowName == hitName || rowName.hasSuffix("." + hitName)
    }

    /// The entry among `entries` declaring `hit`: same file and name, the innermost whose range holds the hit's line, else the first of that name.
    ///
    /// Matched on the name first because a file edited since the build has moved the store's line.
    static func matchIndex(of hit: SemanticStore.Hit, at path: String, in entries: [Entry]) -> Int? {
        let named = entries.indices.filter { index in
            entries[index].row.map { $0.path == path && names($0.name, hit.name) } ?? false
        }
        let containing = named.filter { index in
            entries[index].row.map { ($0.line ... max($0.line, $0.endLine)).contains(hit.line) } ?? false
        }
        return containing.max { (entries[$0].row?.line ?? 0) < (entries[$1].row?.line ?? 0) } ?? named.first
    }

    /// Whether an inheritance clause entry names the protocol `name`: alone, in a composition, qualified, with generic arguments, or after an attribute.
    static func clause(_ inherited: [String], names name: String) -> Bool {
        InheritedClause.names(name, in: inherited)
    }

    /// The mark of a row whose clause writes the protocol's name where the store records no conformance of it there: through another type where the store records the row inheriting from it through a chain of clauses (`Ember: Answer`, where that `Answer` is a class conforming to it), else not had at all.
    static func unrecordedMark(_ inheritsThroughAnotherType: Bool) -> String {
        inheritsThroughAnotherType ? "direct; the index store has it through another type" : "direct; the index store does not have it"
    }

    /// Whether the scan's row is another type's inheritor: the store records no conformance of the asked protocol for it and records one to another protocol or class of the name inside its declaration, in a file unchanged since the build, of a type whose own declaration is in a file unchanged since the build too.
    static func conformsElsewhere(_ entry: Entry, recorded otherHits: [SemanticStore.Hit], context: SemanticContext, occurrences: OccurrenceFreshness) -> Bool {
        guard entry.hits.isEmpty, let row = entry.row else { return false }
        return otherHits.contains { hit in
            context.relativePath(hit.path) == row.path && names(row.name, hit.name)
                && (row.line ... max(row.line, row.endLine)).contains(hit.line) && occurrences.state(of: hit.path).isLive
                && (hit.protocolPath.map { occurrences.state(of: $0).isLive } ?? true)
        }
    }
}

extension WhereRenderer {
    /// The aliases of the protocol `name` that stand for the protocol itself: its underlying type, parsed and never its where clause, is the protocol (possibly qualified), a composition holding it, or another such alias — each head matched by the store's reference at its line and column, so a head that merely shares the name is not.
    ///
    /// The fold also follows an alias that merely names the protocol (`typealias WP = Wrapper<any P>`, `typealias Held<T> = Wrapper<T> where T: P`), and a type inheriting from that conforms to nothing of P. `capped` says the fold stopped at its cap, so an alias of the protocol may be missing.
    func protocolAliases(
        of usr: String,
        named name: String,
        files: inout ConformanceHeads.Files,
        context: SemanticContext
    ) throws -> OwnAliases {
        var sources = SemanticStore.SourceLines()
        let own = context.store.references(ofUSR: usr, sources: &sources)
        let fold = try aliasFold(referencedAt: own, named: name, context: context, sources: &sources)
        var accepted: [(name: String, spelling: String)] = []
        var grew = true
        while grew {
            grew = false
            for alias in fold.aliases where !accepted.contains(where: { $0.spelling == alias.spelling }) {
                let standsFor = Self.written(name, by: own, in: alias.row, files: &files, context: context) != nil
                    || accepted.contains { target in
                        Self.written(target.name, by: fold.hits.filter { $0.writtenAs == target.spelling }, in: alias.row, files: &files, context: context) != nil
                    }
                guard standsFor else { continue }
                accepted.append((alias.name, alias.spelling))
                grew = true
            }
        }
        return OwnAliases(aliases: accepted, hits: fold.hits, capped: fold.reachedCap)
    }

    /// The first of `hits` that is a head `name` of `row`'s own inheritance clause, or of its underlying type where it is a typealias: same file, line and column.
    static func written(_ name: String, by hits: [SemanticStore.Hit], in row: SymbolRow, files: inout ConformanceHeads.Files, context: SemanticContext) -> SemanticStore.Hit? {
        hits.first { hit in
            context.relativePath(hit.path) == row.path && files.declaration(row, writes: name, atLine: hit.line, column: hit.column)
        }
    }

    /// The first of `aliases` the row's own inheritance clause writes, as the store's reference to that alias places it.
    private static func clauseAlias(of row: SymbolRow, among aliases: [(name: String, spelling: String)], hits: [SemanticStore.Hit], files: inout ConformanceHeads.Files, context: SemanticContext) -> String? {
        aliases.first { alias in
            written(alias.name, by: hits.filter { $0.writtenAs == alias.spelling }, in: row, files: &files, context: context) != nil
        }?.spelling
    }

    /// Adds the types whose inheritance clause writes a typealias of the protocol, each marked with the alias; one already listed keeps its own mark.
    ///
    /// The scan by the alias's written name proposes the types; the store's reference to the alias confirms it, and only where that reference is an entry of the declaration's own inheritance clause, read from a parse of the file — a member's type, a nested type's clause or a generic argument writing the alias is not.
    private func appendAliasConformers(to entries: inout [ConformersOnce.Entry], aliases: (aliases: [(name: String, spelling: String)], hits: [SemanticStore.Hit]), files: inout ConformanceHeads.Files, context: SemanticContext) throws {
        for alias in aliases.aliases {
            let references = aliases.hits.filter { $0.writtenAs == alias.spelling }
            for row in try store.conformers(of: alias.name) where !entries.contains(where: { $0.row?.id == row.id }) {
                guard let hit = Self.written(alias.name, by: references, in: row, files: &files, context: context) else { continue }
                entries.append(ConformersOnce.Entry(row: row, hits: [hit], direct: false, alias: alias.spelling))
            }
        }
    }

    /// The typealiases the store's fold accepts as standing for the declaration `row`, with the store's references to them, and the rows of the class's store block, `listed`, with each subclass written through one of them marked with it.
    ///
    /// Only a class or protocol is inherited through its own typealias, so any other declaration has none and its rows come back as they were; a fold that stopped at its cap cannot say which aliases stand for the type, so its aliases are `nil`.
    func ownAliasRows(of row: SymbolRow, usr: String, listed: [ListedRow], context: SemanticContext) throws -> (accepted: OwnAliases?, rows: [ListedRow]) {
        guard row.kind == .classKind || row.kind == .protocolKind else { return (OwnAliases(aliases: [], hits: [], capped: false), listed) }
        var files = ConformanceHeads.Files(root: context.repoRoot)
        let folded = try protocolAliases(of: usr, named: row.name, files: &files, context: context)
        let rows = row.kind == .classKind ? try aliasSubclassRows(through: folded, in: listed, files: &files, context: context) : listed
        return (folded.capped ? nil : folded, rows)
    }

    /// The rows of a class's store block, `listed`, with each subclass written through one of its own typealiases marked with the alias, one the store holds no row for added after them.
    ///
    /// The store records such a clause against the alias, and a row for the class only as an implicit occurrence, which ``SemanticStore/written(_:inheritanceClauses:)`` keeps in a class's subclass rows, since a clause another type writes beside it is no macro expansion's copy of it. A held row, matched by file and line, takes the mark where it has none, and a subclass the store holds no row for, one in an inactive `#if` branch, is added after them; and a clause that writes the class itself is never marked, the store holding no reference to an alias at its head. A row the store holds is only ever marked, never changed.
    ///
    /// The aliases are `folded`, the ones the class's fold accepts, and a row is the store's reference to the alias at a head of the subclass's own inheritance clause, read from a parse of the file.
    func aliasSubclassRows(
        through folded: OwnAliases,
        in listed: [ListedRow],
        files: inout ConformanceHeads.Files,
        context: SemanticContext
    ) throws -> [ListedRow] {
        var rows = listed
        for alias in folded.aliases {
            let references = folded.hits.filter { $0.writtenAs == alias.spelling }
            for row in try store.conformers(of: alias.name) {
                guard let hit = Self.written(alias.name, by: references, in: row, files: &files, context: context) else { continue }
                let mark = "through typealias \(alias.spelling)"
                if let held = rows.firstIndex(where: { $0.hit.path == hit.path && $0.hit.line == hit.line }) {
                    rows[held].access = rows[held].access ?? mark
                    continue
                }
                let subclass = SemanticStore.Hit(name: DeclaredTypeName.last(ofPath: row.name), path: hit.path, line: hit.line, column: hit.column, unit: hit.unit)
                rows.append(ListedRow(hit: subclass, units: 1, access: mark))
            }
        }
        return rows
    }

    /// The one conformers block for the protocol `usr` the store answered, or nil when neither the store nor the scan by written name finds a conformer.
    ///
    /// A conformer the scan finds is direct; one only the store has is direct when its declaration's inheritance clause still names the protocol, else indirect; one only the scan finds says the store has it through another type where the store records it inheriting from the protocol through a chain of clauses — its clause names a type of the same name that does — and else that the store does not have it. Rows the tree no longer backs as built are labelled and sort last, so the cap is spent on the rows that still stand.
    func conformersOnce(
        of protocolRow: SymbolRow,
        usr: String,
        context: SemanticContext,
        occurrences: OccurrenceFreshness,
        qualifiedName: (SymbolRow) throws -> String
    ) throws -> ConformersOnce? {
        let storeHits = context.store.semanticConformers(ofUSR: usr)
        let otherHits = context.store.conformersOfOtherTypes(named: protocolRow.name, besides: usr)
        var files = ConformanceHeads.Files(root: context.repoRoot)
        let folded = try protocolAliases(of: usr, named: protocolRow.name, files: &files, context: context)
        var entries = try store.conformers(of: protocolRow.name).map { ConformersOnce.Entry(row: $0, hits: [], direct: true) }
        for (hit, units) in Self.collapsedIdentical(storeHits) {
            let path = context.relativePath(hit.path)
            if let index = ConformersOnce.matchIndex(of: hit, at: path, in: entries) {
                entries[index].hits.append(hit)
                entries[index].units = max(entries[index].units, units)
                continue
            }
            let declared = try (store.typeDeclarations(named: hit.name) + store.extensions(ofTypeNamed: hit.name))
                .map { ConformersOnce.Entry(row: $0, hits: [], direct: false) }
            guard let found = ConformersOnce.matchIndex(of: hit, at: path, in: declared), let row = declared[found].row else {
                entries.append(ConformersOnce.Entry(row: nil, hits: [hit], direct: false, units: units))
                continue
            }
            if let existing = entries.firstIndex(where: { $0.row?.id == row.id }) {
                entries[existing].hits.append(hit)
                entries[existing].units = max(entries[existing].units, units)
            } else {
                let inherited = try store.inheritedNames(of: row.id)
                let direct = ConformersOnce.clause(inherited, names: protocolRow.name)
                let alias = direct ? nil : Self.clauseAlias(of: row, among: folded.aliases, hits: folded.hits, files: &files, context: context)
                entries.append(ConformersOnce.Entry(row: row, hits: [hit], direct: direct, alias: alias, units: units))
            }
        }
        try appendAliasConformers(to: &entries, aliases: (folded.aliases, folded.hits), files: &files, context: context)
        let others = entries.count { ConformersOnce.conformsElsewhere($0, recorded: otherHits, context: context, occurrences: occurrences) }
        entries.removeAll { ConformersOnce.conformsElsewhere($0, recorded: otherHits, context: context, occurrences: occurrences) }
        guard !entries.isEmpty else { return nil }
        // A walked row is left out only where the store records it not inheriting from the protocol; the store cannot speak for a row it does not resolve, or one in a file changed since the build, so such a row is kept, and it vouches only for a listed row it records conforming, in a file unchanged since the build.
        let vouched = Set(entries.filter { entry in
            !entry.hits.isEmpty && entry.hits.allSatisfy { occurrences.state(of: $0.path).isLive }
        }.compactMap(\.row?.id))
        let walk = try InheritedConformers(of: protocolRow.name, listed: entries.compactMap(\.row), asked: [protocolRow], store: store, vouched: vouched) { row in
            guard occurrences.state(of: context.repoRoot.appendingPathComponent(row.path).path).isLive, context.store.usr(for: row) != nil else { return nil }
            return context.store.inherits(row, from: usr)
        }
        let state: (ConformersOnce.Entry) -> OccurrenceState = { entry in
            entry.hits.first.map { occurrences.state(of: $0.path) } ?? .live
        }
        let place: (ConformersOnce.Entry) -> (String, Int) = { entry in
            entry.row.map { ($0.path, $0.line) } ?? (entry.hits.first.map { (context.relativePath($0.path), $0.line) } ?? ("", 0))
        }
        // The rows the walk reached come after every other, so each names a row listed above it and the cap is spent on the clauses that write the name first.
        let sorted = entries.sorted { lhs, rhs in
            let (left, right) = (state(lhs).isLive, state(rhs).isLive)
            return left != right ? left : place(lhs) < place(rhs)
        } + walk.rows.map { ConformersOnce.Entry(row: $0.row, hits: [], direct: false, through: $0.through) }
        let direct = entries.count(where: \.direct)
        let throughAlias = entries.count { $0.alias != nil }
        // A conformer in a file the tree no longer has is unclassified: its clause cannot be read, so it is neither direct nor indirect.
        let inDeletedFile = entries.count { !$0.direct && $0.alias == nil && state($0) == .deleted }
        let indirect = entries.count - direct - throughAlias - inDeletedFile
        let inherited = walk.rows.count
        var statesByPath: [String: OccurrenceState] = [:]
        for hit in entries.flatMap(\.hits) {
            statesByPath[hit.path] = occurrences.state(of: hit.path)
        }
        let extra = (throughAlias == 0 ? "" : ", \(throughAlias) through a typealias") + (inDeletedFile == 0 ? "" : ", \(inDeletedFile) in a deleted file")
        let aliasNote = throughAlias == 0 ? "a typealias to it is not followed" : "through a typealias is a clause writing a typealias of it"
        let inheritedCount = inherited == 0 ? "" : ", \(inherited) inherited"
        let inheritedNote = inherited == 0 ? "" : "; \(InheritedConformers.definition)"
        let details = ["\(sorted.count): \(direct) direct, \(indirect) indirect\(inheritedCount)\(extra) — direct is every inheritance clause in this tree's source that writes the name, so a grep for the name finds the same lines; \(aliasNote); indirect is from the index store\(inheritedNote)"]
            + Self.driftDetails(states: Array(statesByPath.values))
            + (others == 0 ? [] : ["\(others) left out: the index store records \(others == 1 ? "its clause" : "their clauses") as conforming to another \"\(protocolRow.name)\""])
        var lines = ["", "conformers of \(protocolRow.name) (\(details.joined(separator: ", "))):"]
        var cited: [String] = []
        var clauseLines: Set<String> = []
        for entry in sorted.prefix(Self.listCap) {
            // A row in a file the tree no longer has carries no mark of its own: the stale-file label after it says all that is known.
            let mark: String? = if let through = entry.through {
                "inherited through \(through)"
            } else if let alias = entry.alias {
                "through typealias \(alias)"
            } else if entry.direct {
                entry.hits.isEmpty ? ConformersOnce.unrecordedMark(entry.row.map { context.store.inherits($0, from: usr) } ?? false) : "direct"
            } else {
                state(entry) == .deleted ? nil : "indirect"
            }
            let marked = mark.map { " — \($0)" } ?? ""
            let marker = (entry.units > 1 ? "  ×\(entry.units) units" : "") + (state(entry).marker ?? "")
            if let row = entry.row {
                cited.append(row.path)
                try lines.append("  \(qualifiedName(row)) — \(row.kind.rawValue) — \(row.path)\(row.rangeDescription)\(marked)\(marker)")
            } else if let hit = entry.hits.first {
                lines.append("  \(hit.name) — \(context.relativePath(hit.path)):\(hit.line)\(marked)\(marker)")
            }
            // A conformance written through an alias keeps its line in the usage rows, which is where it was listed before.
            for hit in entry.hits where entry.alias == nil && occurrences.state(of: hit.path).isLive {
                clauseLines.insert("\(context.relativePath(hit.path)):\(hit.line)")
            }
        }
        if sorted.count > Self.listCap {
            lines.append("  truncated: \(sorted.count - Self.listCap) more conformers")
        }
        return ConformersOnce(lines: lines, citedPaths: cited, clauseLines: clauseLines)
    }

    /// Appends each declared type's extensions and conformers, a protocol's one merged block standing in for the scan's where the store answered it.
    func appendTypeRelations(
        of declarations: [SymbolRow],
        conformerBlocks: [String: ConformersOnce],
        writtenNameChecks: [String: WrittenNameCheck] = [:],
        citing citedPaths: inout [String],
        into lines: inout [String],
        qualifiedName: (SymbolRow) throws -> String
    ) throws {
        let typeNames = Set(declarations.filter(\.kind.isTypeDeclaration).map(\.name))
        for typeName in typeNames.sorted() {
            let extensions = try store.extensions(ofTypeNamed: typeName)
            if !extensions.isEmpty {
                lines.append("")
                lines.append("extensions of \(typeName) (\(extensions.count)):")
                for row in extensions.prefix(Self.listCap) {
                    citedPaths.append(row.path)
                    let memberCount = try store.childCount(of: row.id)
                    lines.append("  extension \(row.name)\(extensionContext(row)) — \(memberCount) members — \(row.path)\(row.rangeDescription)")
                }
            }
            if let block = conformerBlocks[typeName] {
                citedPaths += block.citedPaths
                lines += block.lines
                continue
            }
            let conformers = try store.conformers(of: typeName)
            let asked = declarations.filter { $0.name == typeName }
            // A class or protocol with no clause writing its name may still have types written through its own typealias, which the walk lists first.
            let seedsOwnAliases = asked.contains { $0.kind == .classKind || $0.kind == .protocolKind }
            if !conformers.isEmpty || seedsOwnAliases {
                // The store speaks for the walked rows only where it resolved every asked type of the name; a listed row it vouches for is one it speaks for, in a file unchanged since the build, whether it records the row inheriting from one of them or from none, since its record of the row's own children is as fresh as theirs.
                let check = writtenNameChecks[typeName].flatMap { $0.covers(asked.count(where: \.kind.isTypeDeclaration)) ? $0 : nil }
                let vouched = Set(conformers.filter { check?.confirm($0) != nil }.map(\.id))
                // The aliases are judged by the same check, so an alias of a type the store did not resolve is never refuted.
                let walk = try InheritedConformers(
                    of: typeName,
                    listed: conformers,
                    asked: asked,
                    store: store,
                    vouched: vouched,
                    confirm: check.map { check in { check.confirm($0) } },
                    seedsOwnAliases: seedsOwnAliases,
                    admitsAlias: check.map { check in { alias in try check.admits(alias, spelling: store.qualifiedName(of: alias)) } },
                    seedFor: check.map { check in { row, alias in try check.seeds(row, through: store.qualifiedName(of: alias)) } }
                )
                let total = conformers.count + walk.rows.count
                guard total > 0 else { continue }
                let throughAlias = walk.rows.count { $0.alias != nil }
                let inherited = walk.rows.count - throughAlias
                let counts = (throughAlias == 0 ? "" : ", \(throughAlias) through a typealias") + (inherited == 0 ? "" : ", \(inherited) inherited")
                let notes = (throughAlias == 0 ? [] : ["through a typealias is a clause writing a typealias of it"]) + (inherited == 0 ? [] : [InheritedConformers.definition])
                let defined = notes.isEmpty ? "" : " — " + notes.joined(separator: "; ")
                lines.append("")
                lines.append("conformers of \(typeName) (\(total), by written name\(counts)\(defined)):")
                // Marked, never left out: a clause naming the protocol or class only behind another owner's qualifier may inherit from that type instead.
                let otherOwners = try OtherOwnerQualifiers(store: store, name: typeName, asked: asked, kinds: [.protocolKind, .classKind])
                let rows = conformers.map { ($0, nil as String?) } + walk.rows.map { walked in
                    (walked.row, walked.alias.map { "through typealias \($0)" } ?? "inherited through \(walked.through)")
                }
                for (row, through) in rows.prefix(Self.listCap) {
                    citedPaths.append(row.path)
                    let mark = try through.map { " — \($0)" } ?? otherOwners?.mark(clause: store.inheritedNames(of: row.id), naming: typeName) ?? ""
                    try lines.append("  \(qualifiedName(row)) — \(row.kind.rawValue) — \(row.path)\(row.rangeDescription)\(mark)")
                }
                if total > Self.listCap {
                    lines.append("  truncated: \(total - Self.listCap) more conformers")
                }
            }
        }
    }
}

extension WhereRenderer {
    /// The typealiases the store's fold accepts as standing for a protocol or class, with the store's references to them.
    struct OwnAliases {
        let aliases: [(name: String, spelling: String)]
        let hits: [SemanticStore.Hit]
        /// Whether the fold stopped at its cap, so an alias of the type may be missing.
        let capped: Bool
    }

    /// The index store's word on a row a type's block by written name walks to: kept where it records the row inheriting from one of the asked declarations, left out where it records it inheriting from none.
    struct WrittenNameCheck {
        private var askers: [(SymbolRow) -> Bool?] = []
        private var aliasAskers: [(SymbolRow, String) -> Bool?] = []
        private var seedAskers: [(spellings: Set<String>, ask: (SymbolRow, String) -> Bool?)] = []

        /// Adds the asked declaration `usr`, judged by the store `context` holds against its own build, with the typealiases the store's fold accepts as standing for it and its references to them, or `nil` where it cannot say which do.
        mutating func add(usr: String, context: SemanticContext, occurrences: OccurrenceFreshness, aliases folded: OwnAliases?) {
            let speaks = { (row: SymbolRow) in
                occurrences.state(of: context.repoRoot.appendingPathComponent(row.path).path).isLive && context.store.usr(for: row) != nil
            }
            askers.append { row in
                speaks(row) ? context.store.inherits(row, from: usr) : nil
            }
            let aliases = folded.map { Set($0.aliases.map(\.spelling)) }
            if let folded, let aliases {
                // One parse of each file serves every row asked of it.
                var files = ConformanceHeads.Files(root: context.repoRoot)
                addSeeds(spellings: aliases) { row, spelling in
                    guard let alias = folded.aliases.first(where: { $0.spelling == spelling }) else { return nil }
                    let references = folded.hits.filter { $0.writtenAs == spelling }
                    if WhereRenderer.written(alias.name, by: references, in: row, files: &files, context: context) != nil {
                        return true
                    }
                    return speaks(row) ? false : nil
                }
            }
            aliasAskers.append { alias, spelling in
                guard let aliases else { return nil }
                if aliases.contains(spelling) {
                    return true
                }
                return speaks(alias) ? false : nil
            }
        }

        /// Adds an asked declaration's word on a type whose clause writes one of the aliases spelled `spellings`, the ones its fold accepts.
        mutating func addSeeds(spellings: Set<String>, ask: @escaping (SymbolRow, String) -> Bool?) {
            seedAskers.append((spellings, ask))
        }

        /// Whether the store resolved all `declarations` asked of the name, so a row it records inheriting from none of them is one it refutes.
        func covers(_ declarations: Int) -> Bool {
            askers.count == declarations
        }

        /// `true` where the store records `row` inheriting from an asked declaration, `false` where it records it inheriting from none, and `nil` where it cannot speak for the row.
        func confirm(_ row: SymbolRow) -> Bool? {
            Self.verdict(askers.map { $0(row) })
        }

        /// `true` where the store's fold accepts `alias`, spelled `spelling`, as standing for an asked declaration, `false` where it records it, in a file unchanged since the build, standing for none of them, and `nil` where it cannot speak for the alias.
        func admits(_ alias: SymbolRow, spelling: String) -> Bool? {
            Self.verdict(aliasAskers.map { $0(alias, spelling) })
        }

        /// `true` where the store's reference to the alias spelled `spelling` sits at a head of `row`'s own inheritance clause, `false` where it records the row, in a file unchanged since the build, with no such reference, and `nil` where it cannot speak for the row or no asked declaration's fold accepts the alias.
        ///
        /// Only a declaration whose fold accepts the alias holds the store's references to it, so only such a declaration has a say, and every such one holds the same references.
        func seeds(_ row: SymbolRow, through spelling: String) -> Bool? {
            seedAskers.first { $0.spellings.contains(spelling) }.flatMap { $0.ask(row, spelling) }
        }

        /// `true` where one asked declaration's verdict is, `false` where every one's is, and `nil` otherwise.
        private static func verdict(_ verdicts: [Bool?]) -> Bool? {
            if verdicts.contains(true) {
                return true
            }
            return verdicts.contains(nil) ? nil : false
        }
    }
}
