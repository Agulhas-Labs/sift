//
// Copyright © Agulhas Labs
//

import SwiftParser
import SwiftSyntax

/// `where`'s name-matched stand-in for a type's usage verdict, for the types the index store left unanswered — stale, absent or refused.
///
/// A type is reached far more often than it is built: through a static member (`T.make()`), in an annotation, a generic argument, a conformance or a cast. A scan for calls spelling its name finds none of those, and "no call spelled T" said of a type used only that way reads as a deletion verdict. So a type's stand-in lists every place its name is written, grouped as the store's `used by` verdict is — distinct lines per file, split into production and tests on the file's own imports — under the name-matched block's heading, so a reader of the finished answer takes its rows as leads to verify rather than locations the answer resolved.
struct SyntacticTypeUsage {
    let store: IndexStore
    let callSites: (([String: CallSiteScanner.SiteShape]) async -> [String: [SyntacticCallSite]])?
    /// Whether any file holds a freestanding macro or a custom attribute at file scope (``BareNameOutsideTypes``); `nil` reads as one may.
    var expandsAtFileScope: (() async -> Bool)?
    /// The query a plain answer names for the sites, `— where --refs <pointer> lists them`, in place of listing them; `nil` lists them, for `--refs` and for a caller standing the answer in for a search's lines.
    var pointer: String?
    /// A repo-relative file's current text, or `nil` where it cannot be read: it places a clause continued onto later lines.
    var fileSource: ((String) -> String?)?
    /// Whether a guessed file's build file renames its module through a setting this tool cannot read, which a verdict says in place of the module being guessed from the path.
    var isUnreadablyRenamed: (String) -> Bool = { _ in false }
    /// Where a files view (`where X --files`) records every file the block lists, past its caps.
    var filesCollector: WhereFilesCollector?

    /// Whether the store's usage verdict is what answers for a declaration of this kind, so the name-matched stand-in for it is this one rather than a scan for calls.
    static func standsIn(for kind: SymbolKind) -> Bool {
        kind.isTypeDeclaration || kind == .typealiasKind
    }

    /// The block for `rows`, one verdict per name, or nothing where no row is left to stand in for or there is no working tree to scan.
    ///
    /// `listedAbove` is whether the index store resolved a site to another declaration of the name and the answer already handed it on there: such a site is no use of these rows, and listing it again would repeat it. `listedInPlace` is whether that answer listed it on a line of its own, rather than only counting it.
    func lines(for rows: [SymbolRow], qualifiedName: (SymbolRow) throws -> String, listedAbove: (SyntacticCallSite) -> Bool = { _ in false }, listedInPlace: (SyntacticCallSite) -> Bool = { _ in false }, paging: SyntacticSweepPaging? = nil) async throws -> [String] {
        guard let callSites, !rows.isEmpty else { return [] }
        // An extension written through a dotted path is found by its final component, the one name a type use writes as a token of its own.
        let byName = Dictionary(grouping: rows) { $0.kind == .extensionKind ? DeclaredTypeName.last(ofPath: $0.name) : $0.name }
        let typealiases = try store.everyTypealias()
        let guessedModules = try GuessedModuleNotice.reasons(for: store.filesWithGuessedModule(), isUnreadablyRenamed: isUnreadablyRenamed)
        let chains = try byName.mapValues { try AliasChain(of: $0, among: typealiases, store: store, guessedModules: guessedModules) }
        var shapes = byName.mapValues { _ in CallSiteScanner.SiteShape.typeUse }
        for alias in chains.values.flatMap(\.aliases) {
            shapes[alias.row.name] = .typeUse
        }
        let sitesByName = await callSites(shapes)
        var scopes = try Dictionary(uniqueKeysWithValues: byName.map { name, named in try (name, BareTypeNameScope(store: store, name: name, asked: named)) })
        // Per asked name, what each of its aliases' names means where it is written: a scope nearer the site declaring its own of the name hides the alias.
        var aliasScopes = try chains.mapValues { chain in
            try Dictionary(uniqueKeysWithValues: Set(chain.aliases.map(\.row.name)).map { aliasName in
                try (aliasName, AliasNameScope(store: store, name: aliasName, aliases: chain.aliases.filter { $0.row.name == aliasName }.map(\.row), reachedCap: chain.reachedCap))
            })
        }
        // A function-local typealias is no row of the index, so it is found by the type use its right-hand side writes, and its uses by a second scan, kept to the block declaring it.
        let locals = try localAliases(among: sitesByName, chains: chains, scopes: &scopes, aliasScopes: &aliasScopes)
        let localNames = Set(locals.values.joined().map(\.alias.name)).subtracting(shapes.keys)
        let localSites = localNames.isEmpty ? [:] : await callSites(Dictionary(uniqueKeysWithValues: localNames.map { ($0, CallSiteScanner.SiteShape.typeUse) }))
        let deleted = try Set(store.deletionLedger().entries.keys)
        let resolver = try SameNamedTypes.Resolver(store: store)
        // Read once, and only where a line would be set apart by it: the read walks every file.
        var expands: Bool?
        var lines: [String] = []
        for name in byName.keys.sorted() {
            let named = byName[name] ?? []
            let owners = try Set(named.map(qualifiedName)).sorted().joined(separator: ", ")
            let ownerships = try named.map { try ownership(of: $0, guessedModules: guessedModules) }
            var scope = try scopes[name] ?? BareTypeNameScope(store: store, name: name, asked: named)
            let qualified = try QualifiedTypeNameScope(store: store, resolver: resolver, name: name, asked: named)
            let chain = chains[name] ?? AliasChain()
            let sites = sitesByName[name] ?? []
            var tally = Tally(ownerships: ownerships, chain: chain)
            if sites.contains(where: \.writtenOutsideTypes), try BareNameOutsideTypes.setsApart(name, asked: named, store: store) {
                if expands == nil {
                    expands = await expandsAtFileScope?() ?? true
                }
                tally.setsApartOutside = expands == false
            }
            let otherOwners = try OtherOwnerQualifiers(store: store, name: name, asked: named)
            var spelledAsAnother = OtherOwnerQualifiers.Lines()
            var readAsAnother = OtherOwnerQualifiers.Lines()
            let foreign = try ExtensionHeaders(store: store).qualifiedAsAnother(named: name, asked: named, sites: sites)
            for site in sites where foreign[site.path]?[site.line].map({ $0 != site.qualifier }) ?? true {
                try tally.add(site, named: name, listedAbove: listedAbove(site), listedInPlace: listedInPlace(site), meansAnother: scope.meansAnother(site))
                spelledAsAnother.add(site, scope: otherOwners)
                // Kept, never set apart: reading a qualifier from the index alone is not sound.
                try readAsAnother.add(site, owners: qualified.otherOwners(of: site))
            }
            // A use written through an alias is a use of the type, whatever the alias is called, where the name means the alias; one of the same name as the type was scanned above.
            for aliasName in Set(chain.aliases.map(\.row.name)).subtracting([name]).sorted() {
                let named = chain.aliases.filter { $0.row.name == aliasName }
                let spelling = try AliasChain.spelling(of: named, qualifiedName: qualifiedName)
                let undecided = try AliasChain.sharedWithAnother(spelling, of: named, qualifiedName: qualifiedName)
                for site in sitesByName[aliasName] ?? [] {
                    let reading = try aliasScopes[name]?[aliasName]?.reading(of: site) ?? .alias
                    tally.add(site, named: aliasName, listedAbove: listedAbove(site), listedInPlace: listedInPlace(site), writtenAs: reading == .undecided ? undecided : spelling, aliasReading: reading)
                    spelledAsAnother.add(site, scope: nil)
                    readAsAnother.add(site, owners: [])
                }
            }
            for local in locals[name] ?? [] {
                for site in localSites[local.alias.name] ?? sitesByName[local.alias.name] ?? [] where local.isMeant(at: site) {
                    tally.add(site, named: local.alias.name, listedAbove: listedAbove(site), listedInPlace: listedInPlace(site), writtenAs: local.spelling)
                    spelledAsAnother.add(site, scope: nil)
                    readAsAnother.add(site, owners: [])
                }
            }
            lines.append("")
            let kind = Set(named.map(\.kind.rawValue)).count == 1 ? named[0].kind.rawValue : "type"
            let readClause = readAsAnother.clause(
                named: name,
                used: tally.used,
                behind: "behind a qualifier the index reads as",
                asked: "this \(kind)'s",
                because: "as a qualifier read from the index alone may name another type in Swift"
            )
            tally.extendsAnother = try ExtensionHeaders(store: store).extendingAnother(named: name, asked: named, sites: sites)
            let placedClause = ExtensionHeaders.placedClause(named: name, kind: kind, used: tally.used, headers: tally.extendsAnother)
            let caveats = [spelledAsAnother.clause(named: name, used: tally.used), readClause, placedClause].compactMap(\.self)
            tally.caveat = caveats.isEmpty ? nil : caveats.joined(separator: "; ")
            lines += try verdict(for: name, tally: tally, ownerships: ownerships, owners: owners, deleted: deleted, paging: paging)
        }
        return lines
    }

    /// Where `row`'s name is written as part of declaring itself, by the store's rule: its declaration, and an extension of a type declaration written with its own path — `Outer.Item`, or `Module.Outer.Item` — in its own module.
    ///
    /// Nothing else is its own. Another module's extension of it breaks when the type goes, so it is a use, tallied for the verdict to say which rule it followed; a type of the same name nested elsewhere is another type, so the lines inside it are not its own either — though one writing the name bare where the type around it declares its own type of the name means that one, and the verdict counts it apart (`BareTypeNameScope`). Nor is an extension the declaration is not visible from — private to another file, or under an `#if` the extension does not share — since it may extend another type of the name, so its lines stay uses.
    private func ownership(of row: SymbolRow, guessedModules: [String: GuessedModuleNotice.Reason]) throws -> Ownership {
        // An extension asked of here extends a type the tree does not declare, so every line writing that type's name is a use of it, the extension's own included.
        guard row.kind != .extensionKind else { return Ownership(spans: [:]) }
        let declared = try store.parentChain(of: row) + [row]
        let path = declared.map(\.name).joined(separator: ".")
        var own = Ownership(spans: [row.path: [row.line ... max(row.line, row.endLine)]])
        // An extension written through a typealias extends the type it names, and deleting the alias breaks it: a use.
        guard row.kind.isTypeDeclaration else { return own }
        let placement = try ExtensionPlacement(of: row, in: store)
        for written in try ExtensionPaths.written(endingIn: row.name, in: store) where written.path == path || written.path == "\(row.module).\(path)" {
            // An extension the code places as another type's, such as a bare one in a module declaring its own type of the path, is neither its own nor a use of it.
            guard try placement.place(written) != .another else { continue }
            let extended = written.row
            let isVisible = declared.allSatisfy { $0.accessLevel >= .internalLevel || $0.path == extended.path }
                && (row.ifConfigCondition == nil || row.ifConfigCondition == extended.ifConfigCondition)
            guard isVisible else { continue }
            guard extended.module == row.module else {
                own.otherModuleExtensions += 1
                own.otherModuleExtensionsGuessed.formUnion([extended.path, row.path].compactMap { guessedModules[$0] })
                continue
            }
            own.spans[extended.path, default: []].append(extended.line ... max(extended.line, extended.endLine))
        }
        return own
    }

    /// Per asked name, the function-local typealiases a type use on their right-hand side shows to name it, by the fold rules of one declared where they are, with how their uses are counted.
    ///
    /// One named as the type or as one of its indexed typealiases is left out: the uses of that name are counted already. So is one whose right-hand side writes the name bare where `scopes` reads it as another type of the name, or an alias's name where `aliasScopes` reads it as another declaration, as that line is counted; one whose right-hand side writes an alias's name where the scope leaves what it means unsaid is kept.
    private func localAliases(among sitesByName: [String: [SyntacticCallSite]], chains: [String: AliasChain], scopes: inout [String: BareTypeNameScope], aliasScopes: inout [String: [String: AliasNameScope]]) throws -> [String: [LocalAlias]] {
        var found: [String: [LocalAlias]] = [:]
        for (name, chain) in chains {
            let counted = Set(chain.aliases.map(\.row.name)).union([name])
            var byDeclaration: [String: LocalAlias] = [:]
            for written in counted.sorted() {
                for site in sitesByName[written] ?? [] {
                    guard let alias = site.localTypealias, !counted.contains(alias.name) else { continue }
                    if written == name, try scopes[name]?.meansAnother(site) == true {
                        continue
                    }
                    let reading = written == name ? .alias : try aliasScopes[name]?[written]?.reading(of: site) ?? .alias
                    guard reading == .alias || reading == .undecided else { continue }
                    let target = site.qualifier.map { $0 + "." + written } ?? written
                    guard let fold = chain.fold(ofLocal: target, atTopLevel: alias.atTopLevel) else { continue }
                    let key = "\(site.path):\(alias.declaredAt)"
                    guard byDeclaration[key]?.proven != true else { continue }
                    let text = try ([store.fileRow(path: site.path)?.module].compactMap(\.self) + [site.enclosing, alias.name]).joined(separator: ".")
                    let spelling: AliasChain.Spelling = switch fold {
                    case .proven where reading == .undecided: .kept([AliasChain.KeptSpelling(text: text, kind: .sharingNameWithAnother)], because: .sharesNameWithAnother)
                    case .proven: .folded(text)
                    case let .kept(unproven, throughKept): .kept([AliasChain.KeptSpelling(text: "\(text) (\(target))", kind: throughKept ? .aliasOfKept : .behindLeadingName)], because: unproven)
                    }
                    byDeclaration[key] = LocalAlias(path: site.path, alias: alias, spelling: spelling, proven: fold == .proven && reading == .alias)
                }
            }
            found[name] = byDeclaration.keys.sorted().compactMap { byDeclaration[$0] }
        }
        return found
    }

    /// The verdict for one name and the files backing it, capped as the store's usage listing is, or with `pointer` the verdict alone, naming the query that lists them.
    private func verdict(for name: String, tally: Tally, ownerships: [Ownership], owners: String, deleted: Set<String>, paging: SyntacticSweepPaging?) throws -> [String] {
        let used = tally.used
        // A plain answer lists a conformer's header once, in the conformers block, so the rows leave those lines out and the cap does not count them, as the store's verdict does.
        // None under `--refs` or a caller standing the answer in for a search's lines, which list every line.
        let conformances = try pointer == nil ? [:] : ConformanceUseLines(store: store, fileSource: fileSource).lines(of: name, among: tally.usedColumns)
        let rest = Tally.lines(of: used, less: [conformances])
        let conformanceCount = Tally.count(conformances, less: [])
        // Few enough uses are listed in place, as the store's verdict does, rather than handing a handful of lines to `--refs`.
        let pointer = rest.values.reduce(0) { $0 + $1.count } <= WhereRenderer.listedInPlaceCap ? nil : self.pointer
        let ownLines = Tally.count(tally.own, less: [used])
        let anotherLines = Tally.count(tally.another, less: [used, tally.own])
        let localLines = Tally.count(tally.local, less: [used, tally.own, tally.another])
        // An alias's name a scope around the line declares its own of, counted by the name written.
        let anotherOfAlias = tally.anotherOfAlias.mapValues { Tally.count($0, less: [used, tally.own, tally.another, tally.local]) }
        let shadowedAnother = Tally.merged(tally.anotherOfAlias.values)
        let localOfAlias = tally.localOfAlias.mapValues { Tally.count($0, less: [used, tally.own, tally.another, tally.local, shadowedAnother]) }
        let shadowed = Tally.merged([shadowedAnother] + tally.localOfAlias.values)
        let outsideLines = Tally.count(tally.outside, less: [used, tally.own, tally.another, tally.local, shadowed])
        let aliasLines = Tally.count(tally.aliasDeclarations, less: [used, tally.own, tally.another, tally.local, shadowed, tally.outside])
        let listedLines = Tally.count(tally.listedAbove, less: [used, tally.own, tally.another, tally.local, shadowed, tally.outside, tally.aliasDeclarations])
        let listedInPlaceLines = Tally.count(tally.listedInPlace, less: [used, tally.own, tally.another, tally.local, shadowed, tally.outside, tally.aliasDeclarations])
        let writtenAsAlias = Tally.count(tally.throughAlias, less: [tally.direct])
        // A no-store sweep is the whole of what a rename has, and nothing else lists a line the type writes its own name on or a typealias declaration names it in, so both are listed with the uses rather than only counted.
        let swept = paging == nil ? [:] : Tally.lines(of: tally.own, less: [used]).merging(Tally.lines(of: tally.aliasDeclarations, less: [used, tally.own, tally.another, tally.local, shadowed, tally.outside])) { $0.union($1) }
        let listedBelow = { (count: Int) in paging == nil ? "" : ", listed below as a rename changes \(count == 1 ? "it" : "them")" }
        // First, beside the count it qualifies: some of the lines just counted may be another type's.
        var clauses = tally.caveat.map { [$0] } ?? []
        // Named for what is written there, since a reader checking the line will not find the type's name on it.
        if writtenAsAlias > 0 {
            clauses.append(Self.foldedClause(writtenAsAlias, spellings: tally.spellings))
        }
        // Kept, never dropped, and never worded as folded: nothing visible proves the alias names this type.
        let keptThroughAlias = Tally.count(tally.keptThroughAlias, less: [tally.direct, tally.throughAlias])
        if keptThroughAlias > 0 {
            clauses.append(Self.keptClause(keptThroughAlias, spellings: tally.keptSpellings, reasons: tally.keptReasons))
        }
        if tally.chain.reachedCap {
            filesCollector?.recordAliasFoldCapped()
            clauses.append(Self.aliasCapClause)
        }
        if aliasLines > 0 {
            clauses.append("\(aliasLines) more line\(aliasLines == 1 ? "" : "s") declaring a typealias of it, which is another name for the type rather than use of it" + listedBelow(aliasLines))
        }
        if ownLines > 0 {
            clauses.append("\(ownLines) more line\(ownLines == 1 ? "" : "s") inside its own declaration or its extensions in this module" + listedBelow(ownLines))
        }
        // Counted apart, never dropped: the rule that set them aside is said, so a reader who doubts it can check the lines.
        if anotherLines > 0 {
            clauses.append("\(anotherLines) more line\(anotherLines == 1 ? "" : "s") writing \"\(name)\" bare inside a type that declares its own \"\(name)\", which is what the name means there, so not use")
        }
        for (alias, count) in anotherOfAlias.sorted(by: { $0.key < $1.key }) where count > 0 {
            clauses.append("\(count) more line\(count == 1 ? "" : "s") writing \"\(alias)\" bare inside a type that declares its own \"\(alias)\", which is what the name means there, so not use")
        }
        if localLines > 0 {
            clauses.append("\(localLines) more line\(localLines == 1 ? "" : "s") writing \"\(name)\" bare inside a function that declares its own \"\(name)\", which is what the name means there, so not use")
        }
        for (alias, count) in localOfAlias.sorted(by: { $0.key < $1.key }) where count > 0 {
            clauses.append("\(count) more line\(count == 1 ? "" : "s") writing \"\(alias)\" bare inside a function that declares its own \"\(alias)\", which is what the name means there, so not use")
        }
        if outsideLines > 0 {
            clauses.append("\(outsideLines) more line\(outsideLines == 1 ? "" : "s") writing \"\(name)\" bare outside every type, extension and protocol, where the name cannot mean a type nested in another, so not use")
        }
        // Counted rather than listed a second time: the store resolved these sites, and the answer lists them under the declaration it resolved them to.
        if listedLines > 0 {
            // Said of what the store's answer did with each, since it lists few and counts many.
            let countedLines = listedLines - listedInPlaceLines
            let handling = countedLines == 0 ? "listed above under it" : listedInPlaceLines == 0 ? "counted above under it" : "\(listedInPlaceLines) listed above under it, \(countedLines) counted"
            clauses.append("\(listedLines) more line\(listedLines == 1 ? "" : "s") the index store resolved to another declaration of the name, \(handling), so not use")
        }
        let otherModuleExtensions = ownerships.reduce(0) { $0 + $1.otherModuleExtensions }
        if otherModuleExtensions > 0 {
            let guessedNote = GuessedModuleNotice.Reason.countNote(for: ownerships.reduce(into: []) { $0.formUnion($1.otherModuleExtensionsGuessed) })
            clauses.append(otherModuleExtensions == 1
                ? "1 extension in another module counted as use — deleting the type breaks that module\(guessedNote)"
                : "\(otherModuleExtensions) extensions in other modules counted as uses — deleting the type breaks those modules\(guessedNote)")
        }
        let ownClause = clauses.map { "; " + $0 }.joined()
        let listed = rest.merging(swept) { $0.union($1) }
        let none = "no use spelled \"\(name)\" anywhere — no construction, no member reached through it, and no annotation, generic argument, conformance, cast or attribute naming it; a string literal is not searched\(ownClause) (for \(owners))"
        guard !used.isEmpty || !swept.isEmpty else {
            return [none]
        }
        // Every line the rows list, past both caps below, with the conformances the conformers block lists for them.
        filesCollector?.recordWrittenLines(used.merging(swept) { $0.union($1) })
        var block: [String]
        if used.isEmpty {
            block = [none + ":"]
        } else {
            let paths = used.keys.sorted()
            let count = used.values.reduce(0) { $0 + $1.count }
            let split = try WhereRenderer.usageSplit(sitesByPath: paths.map { ($0, used[$0]?.count ?? 0) }, deleted: deleted) { try store.fileRow(path: $0)?.imports }
            let conformed = conformanceCount == 0 ? "" : ", \(conformanceCount) of them the conformance\(conformanceCount == 1 ? "" : "s") listed below"
            block = ["\"\(name)\" (\(count) use\(count == 1 ? "" : "s") by written name in \(paths.count) file\(paths.count == 1 ? "" : "s")\(conformed)) — "
                + split.tally.joined(separator: " · ") + "\(ownClause) (for \(owners))" + (pointer.map { " — where --refs \($0) lists them" } ?? (listed.isEmpty ? "" : ":"))]
        }
        // A question about where a type is did not ask for its uses: the count stands alone, and --refs lists them.
        guard pointer == nil else { return block }
        let paths = listed.keys.sorted()
        let count = listed.values.reduce(0) { $0 + $1.count }
        // Few enough to read in place: one row per line with its source text, every line of every file kept, so the
        // sites can be judged without opening the files. Past that, the line numbers alone keep the block short.
        if count <= WhereRenderer.siteTextLineCap {
            let rows = { (path: String) -> [String] in
                let lines = (listed[path] ?? []).sorted()
                return ["  \(path) (\(lines.count)):"] + lines.map { line in
                    "    :\(line)" + NameMatchedSites.textSuffix(tally.texts[path]?[line]) + (tally.extendsAnother[path]?[line].map { " — extends \($0)" } ?? "")
                }
            }
            if let paging {
                return block + paging.page(files: paths, indent: "  ", render: rows)
            }
            return block + paths.flatMap(rows)
        }
        // A no-store sweep has nothing else to list these sites, so it pages through them all, every line of a file kept.
        if let paging {
            return block + paging.page(files: paths, indent: "  ") { path in
                let lines = (listed[path] ?? []).sorted()
                return ["  \(path) (\(lines.count)): " + lines.map(String.init).joined(separator: ", ")]
            }
        }
        var hiddenLines = 0
        for path in paths.prefix(WhereRenderer.listCap) {
            let lines = (listed[path] ?? []).sorted()
            var rendered = lines.prefix(WhereRenderer.lineListCap).map(String.init).joined(separator: ", ")
            if lines.count > WhereRenderer.lineListCap {
                hiddenLines += lines.count - WhereRenderer.lineListCap
                rendered += ", +\(lines.count - WhereRenderer.lineListCap) more"
            }
            block.append("  \(path) (\(lines.count)): \(rendered)")
        }
        if paths.count > WhereRenderer.listCap {
            let hidden = paths.count - WhereRenderer.listCap
            block.append("  truncated: \(hidden) more file\(hidden == 1 ? "" : "s") — grep for the name to list them")
        }
        if hiddenLines > 0 {
            block.append("  note: \(hiddenLines) line\(hiddenLines == 1 ? "" : "s") past the per-file cap in the files above — grep those files before sweeping")
        }
        return block
    }
}

extension SyntacticTypeUsage {
    /// The typealiases a call of a type's initializers may be written through in place of the type's name, followed as the type's own answer follows them, and the clauses a count line says of the calls written through them.
    ///
    /// Only an alias that is another name for the type counts, directly or through other such aliases: a call through one that builds a type from it, `[Gizmo]` or `Gizmo?`, builds that type instead. A generic alias, `typealias Box<T> = Gizmo`, or one handing the type generic arguments, `typealias Crate = Gizmo<Int>`, still names it. A function-local alias, or one in another module, is no row of the index and stays unseen, as it does for the type.
    struct InitializerAliases {
        /// The names those calls write, the type's own left out, which the scan for the initializers' calls is asked for too.
        let names: [String]
        /// Whether the chain stopped at the cap on followed aliases, so a count through them is a lower bound.
        let reachedCap: Bool
        private let spellings: [String: AliasChain.Spelling]
        private let undecidedSpellings: [String: AliasChain.Spelling]
        private var scopes: [String: AliasNameScope]
        private var undecidedPlaces: [(site: SyntacticCallSite, alias: String)] = []
        private var droppedPlaces: [AliasNameScope.Reading: [(site: SyntacticCallSite, alias: String)]] = [:]

        /// The aliases of the types `initializers` belong to: each one's declaration where the index holds it, or the extension declaring the initializer where it does not.
        init(of initializers: [SymbolRow], store: IndexStore, isUnreadablyRenamed: (String) -> Bool, qualifiedName: (SymbolRow) throws -> String) throws {
            var types: [Int64: SymbolRow] = [:]
            for row in initializers {
                guard let parentID = row.parentID, let parent = try store.symbol(withID: parentID) else { continue }
                let path = try qualifiedName(parent)
                let declared = try store.typeDeclarations(named: DeclaredTypeName.last(ofPath: parent.name)).filter { try qualifiedName($0) == path }
                for type in declared.isEmpty ? [parent] : declared {
                    types[type.id] = type
                }
            }
            try self.init(ofTypes: types.values.sorted { $0.id < $1.id }, store: store, isUnreadablyRenamed: isUnreadablyRenamed, qualifiedName: qualifiedName)
        }

        /// The aliases of the types `rows` declare, whether their initializers are declared or written by the compiler.
        init(ofTypes rows: [SymbolRow], store: IndexStore, isUnreadablyRenamed: (String) -> Bool, qualifiedName: (SymbolRow) throws -> String) throws {
            let guessedModules = try GuessedModuleNotice.reasons(for: store.filesWithGuessedModule(), isUnreadablyRenamed: isUnreadablyRenamed)
            let chain = try AliasChain(of: rows, among: store.everyTypealias(), store: store, guessedModules: guessedModules)
            // An alias is another name for the type where the path a call through it builds ends in the type's name or in that of an alias already found to be one; a built alias's path counts where it is the one the chain folded, or names such an alias.
            let typeNames = Set(rows.map { DeclaredTypeName.last(ofPath: $0.name) })
            var aliasNames: Set<String> = []
            var naming: [AliasChain.Alias] = []
            var left = chain.aliases.compactMap { alias in (alias.built ? AliasChain.calledPath(of: alias.row) : alias.target).map { (alias: alias, path: $0) } }
            while let index = left.firstIndex(where: { entry in
                let last = DeclaredTypeName.last(ofPath: entry.path)
                return aliasNames.contains(last) || entry.path == entry.alias.target && typeNames.contains(last)
            }) {
                let alias = left.remove(at: index).alias
                naming.append(alias)
                aliasNames.insert(alias.row.name)
            }
            names = Set(naming.map(\.row.name)).subtracting(typeNames).sorted()
            spellings = try Dictionary(uniqueKeysWithValues: names.map { name in
                try (name, AliasChain.spelling(of: naming.filter { $0.row.name == name }, qualifiedName: qualifiedName))
            })
            reachedCap = chain.reachedCap
            var scopes: [String: AliasNameScope] = [:]
            var undecided: [String: AliasChain.Spelling] = [:]
            for name in names {
                let named = naming.filter { $0.row.name == name }
                scopes[name] = try AliasNameScope(store: store, name: name, aliases: named.map(\.row), reachedCap: chain.reachedCap)
                if let spelling = spellings[name] {
                    undecided[name] = try AliasChain.sharedWithAnother(spelling, of: named, qualifiedName: qualifiedName)
                }
            }
            self.scopes = scopes
            undecidedSpellings = undecided
        }

        /// An empty list where `sitesByName` holds a call through one of these aliases, so a type called only through them is still answered, or `nil` where it holds none.
        func noOwnSites(in sitesByName: [String: [SyntacticCallSite]]) -> [SyntacticCallSite]? {
            names.contains { sitesByName[$0] != nil } ? [] : nil
        }

        /// `own`, the sites written with the type's name, joined by those `sitesByName` holds for these aliases where the name means the alias at the site, ordered by path then line, each place once since an `.init call` whose type the scan cannot tell is found under every name asked; and the joined ones, with the alias each writes.
        ///
        /// A site inside a type or function that declares its own of the name is left out and counted, for `clauses(for:through:filesCollector:)`; one whose scope leaves the name unsaid is joined and worded as unproven.
        mutating func joining(_ own: [SyntacticCallSite], from sitesByName: [String: [SyntacticCallSite]]) throws -> (sites: [SyntacticCallSite], through: [(site: SyntacticCallSite, alias: String)]) {
            var joined = own
            var through: [(site: SyntacticCallSite, alias: String)] = []
            for name in names {
                for site in sitesByName[name] ?? [] where !joined.contains(where: { $0.isSamePlace(as: site) }) {
                    let reading = try scopes[name]?.reading(of: site) ?? .alias
                    switch reading {
                    case .alias:
                        break
                    case .undecided:
                        if !undecidedPlaces.contains(where: { $0.alias == name && $0.site.isSamePlace(as: site) }) {
                            undecidedPlaces.append((site, name))
                        }
                    case .another, .local:
                        if !(droppedPlaces[reading] ?? []).contains(where: { $0.alias == name && $0.site.isSamePlace(as: site) }) {
                            droppedPlaces[reading, default: []].append((site, name))
                        }
                        continue
                    }
                    joined.append(site)
                    through.append((site, name))
                }
            }
            guard !through.isEmpty else { return (own, []) }
            let sorted = joined.sorted { ($0.path, $0.line) < ($1.path, $1.line) }
            return (sorted, through)
        }

        /// The clauses a count line says of those of `sites` written through these aliases, as `through` records them, in the words the type's own answer uses; a cap reached on the aliases followed is recorded in `filesCollector`.
        func clauses(for sites: [SyntacticCallSite], through: [(site: SyntacticCallSite, alias: String)], filesCollector: WhereFilesCollector?) -> [String] {
            var written: [String: Int] = [:]
            var unproven: [String: Int] = [:]
            for site in sites {
                guard let alias = through.first(where: { $0.site.isSamePlace(as: site) })?.alias else { continue }
                if undecidedPlaces.contains(where: { $0.alias == alias && $0.site.isSamePlace(as: site) }) {
                    unproven[alias, default: 0] += 1
                } else {
                    written[alias, default: 0] += 1
                }
            }
            if reachedCap {
                filesCollector?.recordAliasFoldCapped()
            }
            return clauses(counting: written, undecided: unproven)
        }

        /// The clauses for the calls `written` counts by the name each writes.
        private func clauses(counting written: [String: Int], undecided: [String: Int]) -> [String] {
            var folded = 0
            var foldedSpellings: Set<String> = []
            var kept = 0
            var keptSpellings: Set<AliasChain.KeptSpelling> = []
            var reasons: Set<AliasChain.Unproven> = []
            let counted = written.map { (name: $0.key, count: $0.value, spelling: spellings[$0.key]) }
                + undecided.map { (name: $0.key, count: $0.value, spelling: undecidedSpellings[$0.key]) }
            for (_, count, spelling) in counted where count > 0 {
                switch spelling {
                case let .folded(spelling):
                    folded += count
                    foldedSpellings.insert(spelling)
                case let .kept(spellings, unproven):
                    kept += count
                    keptSpellings.formUnion(spellings)
                    reasons.insert(unproven)
                case nil:
                    continue
                }
            }
            return (folded > 0 ? [SyntacticTypeUsage.foldedClause(folded, spellings: foldedSpellings)] : [])
                + (kept > 0 ? [SyntacticTypeUsage.keptClause(kept, spellings: keptSpellings, reasons: reasons)] : [])
                + droppedClauses
                + (reachedCap ? [SyntacticTypeUsage.aliasCapClause] : [])
        }

        /// One clause per alias name and kind of scope for the places left out, each counted once.
        private var droppedClauses: [String] {
            let kinds: [(reading: AliasNameScope.Reading, scope: String)] = [(.another, "type"), (.local, "function")]
            return names.flatMap { name in
                kinds.compactMap { kind in
                    let count = (droppedPlaces[kind.reading] ?? []).filter { $0.alias == name }.count
                    return count == 0 ? nil : "\(count) written as \"\(name)\" bare inside a \(kind.scope) that declares its own \"\(name)\", which is what the name means there, dropped"
                }
            }
        }
    }
}

private extension SyntacticTypeUsage {
    /// Said where the aliases followed reached the cap on them.
    static var aliasCapClause: String {
        "more typealiases than the \(WhereRenderer.typealiasFoldCap) this follows, so the count is a lower bound"
    }

    /// The clause counting `count` uses written through typealiases proven to name the type, named for what is written there, since a reader checking the line will not find the type's name on it.
    static func foldedClause(_ count: Int, spellings: Set<String>) -> String {
        let spellings = spellings.sorted()
        let naming = spellings.count == 1 ? "a typealias naming it" : "typealiases naming it"
        return "\(count) written as \(WhereRenderer.namedSpellings(spellings)), \(naming), folded in here"
    }

    /// The clause counting `count` uses written through typealiases nothing visible proves name the type, each alias named with what it is, since an alias proven to name the type can share its name with a kept one.
    static func keptClause(_ count: Int, spellings: Set<AliasChain.KeptSpelling>, reasons: Set<AliasChain.Unproven>) -> String {
        let groups = AliasChain.KeptSpelling.Kind.allCases.compactMap { kind -> String? in
            let spellings = spellings.filter { $0.kind == kind }.map(\.text).sorted()
            return spellings.isEmpty ? nil : "\(WhereRenderer.namedSpellings(spellings)), \(kind.described(plural: spellings.count > 1))"
        }
        let reasons = reasons.map(\.reason).sorted().joined(separator: ", and ")
        return "\(count) written as \(groups.joined(separator: ", and ")), kept as \(count == 1 ? "a use" : "uses") though not proven to name it, as \(reasons)"
    }

    /// The line spans a declaration's name is written in as part of declaring itself, and how many extensions of it other modules write, which stay counted as uses.
    struct Ownership {
        /// Per file, repo-relative, the line spans of the declaration and of its extensions in its own module.
        var spans: [String: [ClosedRange<Int>]]
        var otherModuleExtensions = 0
        /// Why any of `otherModuleExtensions` was told apart only by a module guessed rather than declared.
        var otherModuleExtensionsGuessed: Set<GuessedModuleNotice.Reason> = []

        func owns(_ site: SyntacticCallSite) -> Bool {
            spans[site.path]?.contains { $0.contains(site.line) } ?? false
        }
    }

    /// A function-local typealias of an asked type, in the file declaring it, and how the uses of it in its block are counted.
    struct LocalAlias {
        let path: String
        let alias: LocalTypealias
        let spelling: AliasChain.Spelling
        let proven: Bool

        /// Whether `site` writes this alias's name where it may mean this alias: in its file, with this declaration among those the name may mean there, so a block nearer the site declaring another type of the name hides it.
        func isMeant(at site: SyntacticCallSite) -> Bool {
            site.path == path && site.localDeclarations?.contains(alias.declaredAt) == true
        }
    }

    /// Where each line writing a type's name, or the name of one of its typealiases, is counted.
    struct Tally {
        let ownerships: [Ownership]
        let chain: AliasChain
        /// Per file, the lines writing the type's own name as a use.
        var direct: [String: Set<Int>] = [:]
        /// Per file, the lines writing one of its typealiases as a use.
        var throughAlias: [String: Set<Int>] = [:]
        var own: [String: Set<Int>] = [:]
        var another: [String: Set<Int>] = [:]
        /// Per file, the lines writing the name bare where a type declared in a body around them is what it means.
        var local: [String: Set<Int>] = [:]
        /// Per typealias name, per file, the lines writing it where a type around them declares its own of the name, which is what it means there.
        var anotherOfAlias: [String: [String: Set<Int>]] = [:]
        /// Per typealias name, per file, the lines writing it where a type declared in a body around them is what it means.
        var localOfAlias: [String: [String: Set<Int>]] = [:]
        /// Per file, the lines writing the name bare outside every type, where it cannot mean the nested types asked for.
        var outside: [String: Set<Int>] = [:]
        /// Whether a line written bare outside every type is set apart: the index shows nothing that may make the name mean one of the nested types asked for.
        var setsApartOutside = false
        var aliasDeclarations: [String: Set<Int>] = [:]
        /// Per file, the lines holding a site the store resolved to another declaration of the name and listed above.
        var listedAbove: [String: Set<Int>] = [:]
        /// Per file, the lines of those that the store's answer listed on a line of its own.
        var listedInPlace: [String: Set<Int>] = [:]
        /// The qualified names of the typealiases a use was written through.
        var spellings: Set<String> = []
        /// Per file, the lines writing a typealias nothing proves names the type, kept as uses.
        var keptThroughAlias: [String: Set<Int>] = [:]
        /// The typealiases of the names those lines write, each named with what it is.
        var keptSpellings: Set<AliasChain.KeptSpelling> = []
        /// Why each of them is not proven.
        var keptReasons: Set<AliasChain.Unproven> = []
        /// Per file and line, the source text of the line as the scan read it.
        var texts: [String: [Int: String]] = [:]
        /// A clause said first of the lines kept as uses, where some may be another type's.
        var caveat: String?
        /// Per file and line, the header of a bare extension placed as another type's, with what to call that type.
        var extendsAnother: [String: [Int: String]] = [:]
        /// Per file and line of ``used``, the columns of the names its uses write.
        var usedColumns: [String: [Int: Set<Int>]] = [:]
        /// The typealias declarations whose right-hand side a site has already been counted as, one site each, since a plain path writes the name once and a second site on the line is something else.
        private var declared: Set<Int64> = []

        init(ownerships: [Ownership], chain: AliasChain) {
            self.ownerships = ownerships
            self.chain = chain
        }

        var used: [String: Set<Int>] {
            direct.merging(throughAlias) { $0.union($1) }.merging(keptThroughAlias) { $0.union($1) }
        }

        /// Counts `site`, written as `name`: `writtenAs` is how the typealiases of that name are spelled, folded in or kept, where `name` is a typealias of the type rather than the type's own name, with the reading of what that name means at the site.
        mutating func add(_ site: SyntacticCallSite, named name: String, listedAbove: Bool = false, listedInPlace: Bool = false, meansAnother: Bool = false, writtenAs: AliasChain.Spelling? = nil, aliasReading: AliasNameScope.Reading = .alias) {
            // A site the store resolved is settled before any rule by name. Past it, a line is the type declaring itself
            // only inside the own spans of every declaration the name stands for: a line one of them owns can be a use
            // of another, and no use may leave the answer. Counted, never dropped.
            if let text = site.text {
                texts[site.path, default: [:]][site.line] = text
            }
            if listedAbove {
                self.listedAbove[site.path, default: []].insert(site.line)
                if listedInPlace {
                    self.listedInPlace[site.path, default: []].insert(site.line)
                }
            } else if !ownerships.isEmpty, ownerships.allSatisfy({ $0.owns(site) }) {
                own[site.path, default: []].insert(site.line)
            } else if meansAnother {
                another[site.path, default: []].insert(site.line)
            } else if aliasReading == .another {
                anotherOfAlias[name, default: [:]][site.path, default: []].insert(site.line)
            } else if aliasReading == .local {
                localOfAlias[name, default: [:]][site.path, default: []].insert(site.line)
            } else if site.meansLocalType, writtenAs == nil {
                local[site.path, default: []].insert(site.line)
            } else if setsApartOutside, site.writtenOutsideTypes, writtenAs == nil {
                outside[site.path, default: []].insert(site.line)
            } else if let alias = declaration(writtenAt: site, named: name) {
                declared.insert(alias.id)
                aliasDeclarations[site.path, default: []].insert(site.line)
            } else if case let .kept(kept, unproven) = writtenAs {
                keptThroughAlias[site.path, default: []].insert(site.line)
                keptSpellings.formUnion(kept)
                keptReasons.insert(unproven)
                placeUse(site)
            } else if case let .folded(spelling) = writtenAs {
                throughAlias[site.path, default: []].insert(site.line)
                spellings.insert(spelling)
                placeUse(site)
            } else {
                direct[site.path, default: []].insert(site.line)
                placeUse(site)
            }
        }

        /// Records the column of the name a use writes on its line, 0 where the scan gave none.
        private mutating func placeUse(_ site: SyntacticCallSite) {
            let column = site.nameAt.flatMap { $0.split(separator: ":").last.flatMap { Int($0) } } ?? 0
            usedColumns[site.path, default: [:]][site.line, default: []].insert(column)
        }

        /// The alias proven to name the type whose right-hand side `site` is, written with the qualifier it names the type with, and not yet counted; an unproven alias's line stays a use, and so does the line of one that builds a type from it.
        private func declaration(writtenAt site: SyntacticCallSite, named name: String) -> SymbolRow? {
            let written = site.qualifier.map { $0 + "." + name } ?? name
            return chain.aliases.first { alias in
                alias.unproven == nil && !alias.built && alias.target == written && alias.row.path == site.path && (alias.row.line ... max(alias.row.line, alias.row.endLine)).contains(site.line)
                    && !declared.contains(alias.row.id)
            }?.row
        }

        /// Per file, the lines of `lines` none of `others` holds, with no file left empty.
        static func lines(of lines: [String: Set<Int>], less others: [[String: Set<Int>]]) -> [String: Set<Int>] {
            lines.reduce(into: [:]) { kept, entry in
                let left = others.reduce(entry.value) { $0.subtracting($1[entry.key] ?? []) }
                if !left.isEmpty {
                    kept[entry.key] = left
                }
            }
        }

        /// Per file, the lines any of `buckets` holds.
        static func merged(_ buckets: some Sequence<[String: Set<Int>]>) -> [String: Set<Int>] {
            buckets.reduce(into: [:]) { $0.merge($1) { $0.union($1) } }
        }

        /// How many lines of `lines` none of `others` holds.
        static func count(_ lines: [String: Set<Int>], less others: [[String: Set<Int>]]) -> Int {
            Self.lines(of: lines, less: others).values.reduce(0) { $0 + $1.count }
        }
    }
}
