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

    /// Whether the store's usage verdict is what answers for a declaration of this kind, so the name-matched stand-in for it is this one rather than a scan for calls.
    static func standsIn(for kind: SymbolKind) -> Bool {
        kind.isTypeDeclaration || kind == .typealiasKind
    }

    /// The block for `rows`, one verdict per name, or nothing where no row is left to stand in for or there is no working tree to scan.
    ///
    /// `listedAbove` is whether the index store resolved a site to another declaration of the name and the answer already listed it there: such a site is no use of these rows, and listing it again would repeat it.
    func lines(for rows: [SymbolRow], qualifiedName: (SymbolRow) throws -> String, listedAbove: (SyntacticCallSite) -> Bool = { _ in false }, paging: SyntacticSweepPaging? = nil) async throws -> [String] {
        guard let callSites, !rows.isEmpty else { return [] }
        // An extension written through a dotted path is found by its final component, the one name a type use writes as a token of its own.
        let byName = Dictionary(grouping: rows) { $0.kind == .extensionKind ? DeclaredTypeName.last(ofPath: $0.name) : $0.name }
        let typealiases = try store.everyTypealias()
        let guessedModulePaths = try Set(store.filesWithGuessedModule().map(\.path))
        let chains = try byName.mapValues { try AliasChain(of: $0, among: typealiases, store: store, guessedModulePaths: guessedModulePaths) }
        var shapes = byName.mapValues { _ in CallSiteScanner.SiteShape.typeUse }
        for alias in chains.values.flatMap(\.aliases) {
            shapes[alias.row.name] = .typeUse
        }
        let sitesByName = await callSites(shapes)
        var scopes = try Dictionary(uniqueKeysWithValues: byName.map { name, named in try (name, BareTypeNameScope(store: store, name: name, asked: named)) })
        // A function-local typealias is no row of the index, so it is found by the type use its right-hand side writes, and its uses by a second scan, kept to the block declaring it.
        let locals = try localAliases(among: sitesByName, chains: chains, scopes: &scopes)
        let localNames = Set(locals.values.joined().map(\.alias.name)).subtracting(shapes.keys)
        let localSites = localNames.isEmpty ? [:] : await callSites(Dictionary(uniqueKeysWithValues: localNames.map { ($0, CallSiteScanner.SiteShape.typeUse) }))
        let deleted = try Set(store.deletionLedger().entries.keys)
        let resolver = try SameNamedTypes.Resolver(store: store)
        // Read once, and only where a line would be set apart by it: the read walks every file.
        var expands: Bool?
        var lines = ["", "\(NameMatchedSites.typeUseHeadingOpening) over the working tree, never stale — see sift help answers (call sites)"]
        for name in byName.keys.sorted() {
            let named = byName[name] ?? []
            let owners = try Set(named.map(qualifiedName)).sorted().joined(separator: ", ")
            let ownerships = try named.map { try ownership(of: $0, guessedModulePaths: guessedModulePaths) }
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
            for site in sites {
                try tally.add(site, named: name, listedAbove: listedAbove(site), meansAnother: scope.meansAnother(site))
                spelledAsAnother.add(site, scope: otherOwners)
                // Kept, never set apart: reading a qualifier from the index alone is not sound.
                try readAsAnother.add(site, owners: qualified.otherOwners(of: site))
            }
            // A use written through an alias is a use of the type, whatever the alias is called; one of the same name as the type was scanned above.
            for aliasName in Set(chain.aliases.map(\.row.name)).subtracting([name]).sorted() {
                let named = chain.aliases.filter { $0.row.name == aliasName }
                // A scan by name cannot tell which alias of the name a use writes, so one kept alias of it keeps every use of the name, named with each alias of it; otherwise they fold in.
                let spelling: AliasChain.Spelling = if let unproven = named.compactMap(\.unproven).first {
                    try .kept(Set(named.map { try AliasChain.KeptSpelling(of: $0, qualifiedName: qualifiedName($0.row)) }), because: unproven)
                } else {
                    try .folded(named.map { try qualifiedName($0.row) }.sorted().joined(separator: " or "))
                }
                for site in sitesByName[aliasName] ?? [] {
                    tally.add(site, named: aliasName, listedAbove: listedAbove(site), writtenAs: spelling)
                    spelledAsAnother.add(site, scope: nil)
                    readAsAnother.add(site, owners: [])
                }
            }
            for local in locals[name] ?? [] {
                for site in localSites[local.alias.name] ?? sitesByName[local.alias.name] ?? [] where local.isMeant(at: site) {
                    tally.add(site, named: local.alias.name, listedAbove: listedAbove(site), writtenAs: local.spelling)
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
            tally.extendsAnother = try headersExtendingAnother(named: name, asked: named, sites: sites)
            let placedClause = Self.placedClause(named: name, kind: kind, used: tally.used, headers: tally.extendsAnother)
            let caveats = [spelledAsAnother.clause(named: name, used: tally.used), readClause, placedClause].compactMap(\.self)
            tally.caveat = caveats.isEmpty ? nil : caveats.joined(separator: "; ")
            lines += try verdict(for: name, tally: tally, ownerships: ownerships, owners: owners, deleted: deleted, paging: paging)
        }
        return lines
    }

    /// Where `row`'s name is written as part of declaring itself, by the store's rule: its declaration, and an extension of a type declaration written with its own path — `Outer.Item`, or `Module.Outer.Item` — in its own module.
    ///
    /// Nothing else is its own. Another module's extension of it breaks when the type goes, so it is a use, tallied for the verdict to say which rule it followed; a type of the same name nested elsewhere is another type, so the lines inside it are not its own either — though one writing the name bare where the type around it declares its own type of the name means that one, and the verdict counts it apart (`BareTypeNameScope`). Nor is an extension the declaration is not visible from — private to another file, or under an `#if` the extension does not share — since it may extend another type of the name, so its lines stay uses.
    private func ownership(of row: SymbolRow, guessedModulePaths: Set<String>) throws -> Ownership {
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
                if guessedModulePaths.contains(extended.path) || guessedModulePaths.contains(row.path) {
                    own.otherModuleExtensionsGuessed = true
                }
                continue
            }
            own.spans[extended.path, default: []].append(extended.line ... max(extended.line, extended.endLine))
        }
        return own
    }

    /// Per file and line, the header of each extension written bare through `name` that ``ExtensionPlacement`` places as another type's than the one `asked` declares, with what to call that type; none where `asked` is not one type at one path in one module.
    ///
    /// A qualified header is left to the qualifier's own caveat. The header is the first site in the extension, since its body follows it.
    private func headersExtendingAnother(named name: String, asked: [SymbolRow], sites: [SyntacticCallSite]) throws -> [String: [Int: String]] {
        guard asked.allSatisfy(\.kind.isTypeDeclaration) else { return [:] }
        let placements = try asked.map { try ExtensionPlacement(of: $0, in: store) }
        guard let placement = placements.first, placements.allSatisfy({ $0.module == placement.module && $0.path == placement.path }) else { return [:] }
        var headers: [String: [Int: String]] = [:]
        for written in try ExtensionPaths.written(endingIn: name, in: store) where !written.path.contains(".") {
            guard try placement.place(written) == .another else { continue }
            let extended = written.row
            let span = extended.line ... max(extended.line, extended.endLine)
            guard let header = sites.filter({ $0.path == extended.path && span.contains($0.line) }).map(\.line).min() else { continue }
            headers[extended.path, default: [:]][header] = extended.module == placement.module ? "another \(name)" : "another module's \(name)"
        }
        return headers
    }

    /// The verdict's clause for the lines of `used` that are the header of a bare extension placed as another type's, or `nil` where there are none.
    private static func placedClause(named name: String, kind: String, used: [String: Set<Int>], headers: [String: [Int: String]]) -> String? {
        let count = headers.reduce(0) { total, file in total + file.value.keys.count { used[file.key]?.contains($0) == true } }
        guard count > 0 else { return nil }
        let writes = count == 1 ? "writes" : "write"
        let extends = count == 1 ? "extends" : "extend"
        return "\(count) of them \(writes) \"\(name)\" as the header of an extension the index places as another type's, so \(extends) that type rather than this \(kind) — counted all the same, as a placement read from the index alone is not proof"
    }

    /// Per asked name, the function-local typealiases a type use on their right-hand side shows to name it, by the fold rules of one declared where they are, with how their uses are counted.
    ///
    /// One named as the type or as one of its indexed typealiases is left out: the uses of that name are counted already. So is one whose right-hand side writes the name bare where `scopes` reads it as another type of the name, as that line is counted.
    private func localAliases(among sitesByName: [String: [SyntacticCallSite]], chains: [String: AliasChain], scopes: inout [String: BareTypeNameScope]) throws -> [String: [LocalAlias]] {
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
                    let target = site.qualifier.map { $0 + "." + written } ?? written
                    guard let fold = chain.fold(ofLocal: target, atTopLevel: alias.atTopLevel) else { continue }
                    let key = "\(site.path):\(alias.declaredAt)"
                    guard byDeclaration[key]?.proven != true else { continue }
                    let text = try ([store.fileRow(path: site.path)?.module].compactMap(\.self) + [site.enclosing, alias.name]).joined(separator: ".")
                    let spelling: AliasChain.Spelling = switch fold {
                    case .proven: .folded(text)
                    case let .kept(unproven, throughKept): .kept([AliasChain.KeptSpelling(text: "\(text) (\(target))", kind: throughKept ? .aliasOfKept : .behindLeadingName)], because: unproven)
                    }
                    byDeclaration[key] = LocalAlias(path: site.path, alias: alias, spelling: spelling, proven: fold == .proven)
                }
            }
            found[name] = byDeclaration.keys.sorted().compactMap { byDeclaration[$0] }
        }
        return found
    }

    /// The verdict for one name and the files backing it, capped as the store's usage listing is.
    private func verdict(for name: String, tally: Tally, ownerships: [Ownership], owners: String, deleted: Set<String>, paging: SyntacticSweepPaging?) throws -> [String] {
        let used = tally.used
        let ownLines = Tally.count(tally.own, less: [used])
        let anotherLines = Tally.count(tally.another, less: [used, tally.own])
        let localLines = Tally.count(tally.local, less: [used, tally.own, tally.another])
        let outsideLines = Tally.count(tally.outside, less: [used, tally.own, tally.another, tally.local])
        let aliasLines = Tally.count(tally.aliasDeclarations, less: [used, tally.own, tally.another, tally.local, tally.outside])
        let listedLines = Tally.count(tally.listedAbove, less: [used, tally.own, tally.another, tally.local, tally.outside, tally.aliasDeclarations])
        let writtenAsAlias = Tally.count(tally.throughAlias, less: [tally.direct])
        // A no-store sweep is the whole of what a rename has, and nothing else lists a line the type writes its own name on or a typealias declaration names it in, so both are listed with the uses rather than only counted.
        let swept = paging == nil ? [:] : Tally.lines(of: tally.own, less: [used]).merging(Tally.lines(of: tally.aliasDeclarations, less: [used, tally.own, tally.another, tally.local, tally.outside])) { $0.union($1) }
        let listedBelow = { (count: Int) in paging == nil ? "" : ", listed below as a rename changes \(count == 1 ? "it" : "them")" }
        // First, beside the count it qualifies: some of the lines just counted may be another type's.
        var clauses = tally.caveat.map { [$0] } ?? []
        // Named for what is written there, since a reader checking the line will not find the type's name on it.
        if writtenAsAlias > 0 {
            let spellings = tally.spellings.sorted()
            let naming = spellings.count == 1 ? "a typealias naming it" : "typealiases naming it"
            clauses.append("\(writtenAsAlias) written as \(WhereRenderer.namedSpellings(spellings)), \(naming), folded in here")
        }
        // Kept, never dropped, and never worded as folded: nothing visible proves the alias names this type.
        let keptThroughAlias = Tally.count(tally.keptThroughAlias, less: [tally.direct, tally.throughAlias])
        if keptThroughAlias > 0 {
            // Each alias named with what it is, since an alias proven to name the type can share its name with a kept one.
            let groups = AliasChain.KeptSpelling.Kind.allCases.compactMap { kind -> String? in
                let spellings = tally.keptSpellings.filter { $0.kind == kind }.map(\.text).sorted()
                return spellings.isEmpty ? nil : "\(WhereRenderer.namedSpellings(spellings)), \(kind.described(plural: spellings.count > 1))"
            }
            let reasons = tally.keptReasons.map(\.reason).sorted().joined(separator: ", and ")
            clauses.append("\(keptThroughAlias) written as \(groups.joined(separator: ", and ")), "
                + "kept as \(keptThroughAlias == 1 ? "a use" : "uses") though not proven to name it, as \(reasons)")
        }
        if tally.chain.reachedCap {
            clauses.append("more typealiases than the \(WhereRenderer.typealiasFoldCap) this follows, so the count is a lower bound")
        }
        if aliasLines > 0 {
            clauses.append("\(aliasLines) more line\(aliasLines == 1 ? "" : "s") declaring a typealias of it, which is another name for the type rather than use of it" + listedBelow(aliasLines))
        }
        if ownLines > 0 {
            clauses.append("\(ownLines) more line\(ownLines == 1 ? "" : "s") inside its own declaration or its extensions in this module, which is not use" + listedBelow(ownLines))
        }
        // Counted apart, never dropped: the rule that set them aside is said, so a reader who doubts it can check the lines.
        if anotherLines > 0 {
            clauses.append("\(anotherLines) more line\(anotherLines == 1 ? "" : "s") writing \"\(name)\" bare inside a type that declares its own \"\(name)\", which is what the name means there, so not use")
        }
        if localLines > 0 {
            clauses.append("\(localLines) more line\(localLines == 1 ? "" : "s") writing \"\(name)\" bare inside a function that declares its own \"\(name)\", which is what the name means there, so not use")
        }
        if outsideLines > 0 {
            clauses.append("\(outsideLines) more line\(outsideLines == 1 ? "" : "s") writing \"\(name)\" bare outside every type, extension and protocol, where the name cannot mean a type nested in another, so not use")
        }
        // Counted rather than listed a second time: the store resolved these sites, and the answer lists them under the declaration it resolved them to.
        if listedLines > 0 {
            clauses.append("\(listedLines) more line\(listedLines == 1 ? "" : "s") the index store resolved to another declaration of the name, listed above under it, so not use")
        }
        let otherModuleExtensions = ownerships.reduce(0) { $0 + $1.otherModuleExtensions }
        if otherModuleExtensions > 0 {
            let guessedNote = ownerships.contains(where: \.otherModuleExtensionsGuessed) ? " (module guessed from the path)" : ""
            clauses.append(otherModuleExtensions == 1
                ? "1 extension in another module counted as use — deleting the type breaks that module\(guessedNote)"
                : "\(otherModuleExtensions) extensions in other modules counted as uses — deleting the type breaks those modules\(guessedNote)")
        }
        let ownClause = clauses.map { "; " + $0 }.joined()
        let listed = used.merging(swept) { $0.union($1) }
        let none = "no use spelled \"\(name)\" anywhere — no construction, no member reached through it, and no annotation, generic argument, conformance, cast or attribute naming it; a string literal is not searched\(ownClause) (for \(owners))"
        guard !listed.isEmpty else {
            return [none]
        }
        var block: [String]
        if used.isEmpty {
            block = [none + ":"]
        } else {
            let paths = used.keys.sorted()
            let count = used.values.reduce(0) { $0 + $1.count }
            let split = try WhereRenderer.usageSplit(sitesByPath: paths.map { ($0, used[$0]?.count ?? 0) }, deleted: deleted) { try store.fileRow(path: $0)?.imports }
            block = ["\"\(name)\" used by \(count) line\(count == 1 ? "" : "s") in \(paths.count) file\(paths.count == 1 ? "" : "s") — "
                + split.tally.joined(separator: " · ") + ", split on the XCTest or Testing import, never the path\(ownClause) (for \(owners)):"]
        }
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

private extension SyntacticTypeUsage {
    /// The line spans a declaration's name is written in as part of declaring itself, and how many extensions of it other modules write, which stay counted as uses.
    struct Ownership {
        /// Per file, repo-relative, the line spans of the declaration and of its extensions in its own module.
        var spans: [String: [ClosedRange<Int>]]
        var otherModuleExtensions = 0
        /// Whether any of `otherModuleExtensions` was told apart only by a module guessed from a path rather than declared.
        var otherModuleExtensionsGuessed = false

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

    /// The typealiases that are another name for the asked types, followed through aliases of aliases, as the store's fold follows them.
    ///
    /// An alias whose right-hand side is a plain name or member path is another name for the type, so its line is counted apart. One that builds a type from the name — through generic arguments, a tuple, an optional or a function type, or as a generic alias — is followed by every whole path it writes, generic arguments included, never a member path's base alone and never one led by its own generic parameter: its uses break with the type, so they are the type's, but its line stays a use, since it is no other name for the type.
    struct AliasChain {
        private(set) var aliases: [Alias] = []
        private(set) var reachedCap = false
        /// The paths the aliases were folded against: the asked types', the extensions followed beside them, and every alias's.
        private var paths: [WrittenPath] = []

        init() {}

        /// How a function-local typealias writing `target` names the asked types, through any path the chain followed, a proven reading first, or `nil` where it names none of them.
        func fold(ofLocal target: String, atTopLevel: Bool) -> WrittenPath.Fold? {
            let folds = paths.compactMap { $0.fold(of: target, atTopLevel: atTopLevel) }
            return folds.first { $0 == .proven } ?? folds.first
        }

        /// The aliases naming `rows`, where one declared at the top level names a type only by writing its whole path, with or without its module.
        ///
        /// Unqualified lookup at the top level never sees a type nested in another, so a shorter path there names some other type. An alias declared in a type or an extension may name a type nested beside it by any trailing part of its path. One writing the whole path behind a leading name that may be the type's module is kept, unproven, and so is every alias of it.
        init(of rows: [SymbolRow], among typealiases: [SymbolRow], store: IndexStore, guessedModulePaths: Set<String>) throws {
            let written = typealiases.compactMap { alias -> Written? in
                if let target = Self.aliasedPath(of: alias) {
                    return Written(row: alias, targets: [target], built: false)
                }
                let paths = Self.builtPaths(of: alias)
                return paths.isEmpty ? nil : Written(row: alias, targets: paths, built: true)
            }
            var seen = Set(rows.map(\.id))
            var frontier = try rows.map { row in try WrittenPath(of: row, store: store, guessedModulePaths: guessedModulePaths, reachedThrough: nil) }
            var folded = 0
            // An extension of a declared type's bare name that may extend some other type of the name is a path of its own, though the answer counts it as that type's.
            // So is a dotted one (`extension Foundation.JSONDecoder`) beside a type or typealias of the name the bare query found: the one asked may be private, conditional, nested or another name for some other type, and the extension another's.
            // An alias the declaration's own path proves is folded in through that path whatever an extension of it reads as.
            for row in rows where row.kind.isTypeDeclaration || row.kind == .typealiasKind {
                for written in try ExtensionPaths.written(endingIn: row.name, in: store) where !seen.contains(written.row.id) {
                    seen.insert(written.row.id)
                    let path = try WrittenPath(of: written.row, store: store, guessedModulePaths: guessedModulePaths, reachedThrough: nil, mayExtendAnother: written.path != row.name)
                    if path.unknownModule == .extendedOnly || path.mayExtendAnother {
                        frontier.append(path)
                    }
                }
            }
            while !frontier.isEmpty {
                paths += frontier
                var next: [WrittenPath] = []
                for alias in written where !seen.contains(alias.row.id) {
                    let folds = frontier.flatMap { path in alias.targets.compactMap { target in path.fold(of: target, atTopLevel: alias.row.parentID == nil).map { (fold: $0, target: target) } } }
                    guard let first = folds.first else { continue }
                    let proven = folds.first { $0.fold == .proven }
                    let unproven = proven == nil ? first.fold.unproven : nil
                    // Only a folded alias counts against the cap, so a kept one never crowds a proven one out; a kept one is followed whatever the count, since its uses are listed rather than counted apart, and no use may leave the answer.
                    if unproven == nil {
                        guard folded < WhereRenderer.typealiasFoldCap else {
                            reachedCap = true
                            continue
                        }
                        folded += 1
                    }
                    seen.insert(alias.row.id)
                    aliases.append(Alias(row: alias.row, target: (proven ?? first).target, unproven: unproven, ofKept: unproven != nil && folds.allSatisfy(\.fold.throughKept), built: alias.built))
                    try next.append(WrittenPath(of: alias.row, store: store, guessedModulePaths: guessedModulePaths, reachedThrough: unproven))
                }
                frontier = next
            }
        }

        /// The dotted path `alias` is another name for, or `nil` where it is generic or its right-hand side is anything but a plain name or member path.
        static func aliasedPath(of alias: SymbolRow) -> String? {
            guard !alias.signature.contains("<") else { return nil }
            return SameNamedTypes.Resolver.target(of: alias)
        }

        /// Every whole dotted path the right-hand side of `alias` writes, generic arguments followed in, leaving out any led by the alias's own generic parameters, or none where it does not parse as a typealias.
        static func builtPaths(of alias: SymbolRow) -> [String] {
            let tree = Parser.parse(source: alias.signature)
            guard let declaration = tree.statements.first.flatMap({ Syntax($0.item).as(TypeAliasDeclSyntax.self) }), !declaration.hasError else { return [] }
            let parameters = Set(declaration.genericParameterClause?.parameters.map(\.name.text) ?? [])
            return writtenPaths(in: Syntax(declaration.initializer.value)).filter { !parameters.contains(String($0.prefix { $0 != "." })) }
        }

        /// The whole dotted paths written in `node`: a member path as one, never its base alone, and the generic arguments at every level of it.
        private static func writtenPaths(in node: Syntax) -> [String] {
            guard let type = node.as(TypeSyntax.self), let path = DeclaredTypeName.path(of: type) else {
                return node.children(viewMode: .sourceAccurate).flatMap(writtenPaths)
            }
            var arguments: [Syntax] = []
            var level: TypeSyntax? = type
            while let current = level {
                let member = current.as(MemberTypeSyntax.self)
                let clause = member?.genericArgumentClause ?? current.as(IdentifierTypeSyntax.self)?.genericArgumentClause
                arguments += clause.map { [Syntax($0)] } ?? []
                level = member?.baseType
            }
            return [path] + arguments.flatMap(writtenPaths)
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
        /// Per file, the lines writing the name bare outside every type, where it cannot mean the nested types asked for.
        var outside: [String: Set<Int>] = [:]
        /// Whether a line written bare outside every type is set apart: the index shows nothing that may make the name mean one of the nested types asked for.
        var setsApartOutside = false
        var aliasDeclarations: [String: Set<Int>] = [:]
        /// Per file, the lines holding a site the store resolved to another declaration of the name and listed above.
        var listedAbove: [String: Set<Int>] = [:]
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
        /// The typealias declarations whose right-hand side a site has already been counted as, one site each, since a plain path writes the name once and a second site on the line is something else.
        private var declared: Set<Int64> = []

        init(ownerships: [Ownership], chain: AliasChain) {
            self.ownerships = ownerships
            self.chain = chain
        }

        var used: [String: Set<Int>] {
            direct.merging(throughAlias) { $0.union($1) }.merging(keptThroughAlias) { $0.union($1) }
        }

        /// Counts `site`, written as `name`: `writtenAs` is how the typealiases of that name are spelled, folded in or kept, where `name` is a typealias of the type rather than the type's own name.
        mutating func add(_ site: SyntacticCallSite, named name: String, listedAbove: Bool = false, meansAnother: Bool = false, writtenAs: AliasChain.Spelling? = nil) {
            // A site the store resolved is settled before any rule by name. Past it, a line is the type declaring itself
            // only inside the own spans of every declaration the name stands for: a line one of them owns can be a use
            // of another, and no use may leave the answer. Counted, never dropped.
            if let text = site.text {
                texts[site.path, default: [:]][site.line] = text
            }
            if listedAbove {
                self.listedAbove[site.path, default: []].insert(site.line)
            } else if !ownerships.isEmpty, ownerships.allSatisfy({ $0.owns(site) }) {
                own[site.path, default: []].insert(site.line)
            } else if meansAnother {
                another[site.path, default: []].insert(site.line)
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
            } else if case let .folded(spelling) = writtenAs {
                throughAlias[site.path, default: []].insert(site.line)
                spellings.insert(spelling)
            } else {
                direct[site.path, default: []].insert(site.line)
            }
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

        /// How many lines of `lines` none of `others` holds.
        static func count(_ lines: [String: Set<Int>], less others: [[String: Set<Int>]]) -> Int {
            Self.lines(of: lines, less: others).values.reduce(0) { $0 + $1.count }
        }
    }
}

private extension SyntacticTypeUsage.AliasChain {
    /// Why a typealias is kept as another name for a type rather than folded in as one: the leading name its right-hand side writes before the type's whole path may be the type's module, and nothing in the tree says whether it is.
    enum Unproven: Hashable {
        case guessedModule
        /// The path starts at an extension by a bare name that no type its module visibly declares is proven to be, so which module's type it extends goes unsaid.
        case extendedOnly
        /// The path starts at a dotted extension whose leading name the tree declares no type of, and the alias writes the path without it: that name may be a type of another module (`extension UIView.ContentMode`) rather than the module the alias would have to be reading it past.
        case leadingNameMayBeAType
        /// The path starts at a dotted extension beside the type asked, which may extend another type of the name than that one.
        case extendsAnotherOfTheName

        /// Said after "as" in the verdict's clause.
        var reason: String {
            switch self {
            case .guessedModule: "this type's module is guessed from the path"
            case .extendedOnly: "its path starts at an extension of a type its module does not visibly declare, whose module is unknown"
            case .extendsAnotherOfTheName: "its path starts at a dotted extension that may extend another type of the name than the one asked"
            case .leadingNameMayBeAType: "it writes the path of a dotted extension without its leading name, which may be a type rather than a module"
            }
        }
    }

    /// A typealias of the asked types, the dotted path it writes, and why it is only kept, or `nil` where it provably names them.
    struct Alias {
        let row: SymbolRow
        let target: String
        let unproven: Unproven?
        /// Whether it is kept only because what it writes is an alias kept itself, rather than the type's path behind a leading name.
        let ofKept: Bool
        /// Whether its right-hand side builds a type from the name rather than naming it, so `target` is only the path in it that folded.
        let built: Bool
    }

    /// A typealias and the paths its right-hand side writes: the one path it names, or every whole path in the type it builds.
    struct Written {
        let row: SymbolRow
        let targets: [String]
        let built: Bool
    }

    /// How the uses written through typealiases of one name are counted: folded in under the aliases' qualified names, or kept, naming every alias of the name, where one of them is not proven to name the type.
    enum Spelling {
        case folded(String)
        case kept(Set<KeptSpelling>, because: Unproven)
    }

    /// A typealias named in the clause of kept uses, with what it is.
    struct KeptSpelling: Hashable {
        let text: String
        let kind: Kind

        /// `alias` as the clause names it: a kept one with the path it writes, a proven one by its name alone.
        init(of alias: Alias, qualifiedName: String) {
            guard alias.unproven != nil else {
                text = qualifiedName
                kind = .sharingNameWithKept
                return
            }
            text = "\(qualifiedName) (\(alias.target))"
            kind = alias.ofKept ? .aliasOfKept : .behindLeadingName
        }

        /// An alias the index holds no row of, named as `text`.
        init(text: String, kind: Kind) {
            self.text = text
            self.kind = kind
        }
    }

    /// A declaration's path as written, and the whole paths a top-level alias may name it by without its module, or `nil` where a qualifier in the path cannot be accounted for.
    struct WrittenPath {
        let path: String
        let module: String
        let wholePaths: [String]?
        /// Why a whole path behind a leading name other than `module` may still name this declaration, or `nil` where the module is known.
        let unknownModule: Unproven?
        /// Why this declaration, an alias, is itself only kept, so that every alias of it is too.
        let reachedThrough: Unproven?
        /// The path of a dotted extension as written and with its leading name dropped, where the tree declares no top-level type of that name: a target that is a trailing part of the second and not of the first reads the leading name as a module, which nothing proves.
        let droppedLeading: (written: String, rest: String)?
        /// Whether this is a dotted extension found beside a type of its final name, which may extend another type than that one, so no alias is proven to name the type asked through it.
        let mayExtendAnother: Bool

        /// The path of `row` through its containers, where an extension's name is the path its declaration wrote.
        ///
        /// The outermost name may be an extension's, whose leading component may be a module (`extension Lib.Net`, `extension Foundation.JSONDecoder`): it is dropped as one unless the tree declares a top-level type of that name. A dotted name further in is no declaration Swift allows, so the path is taken as unaccounted for.
        init(of row: SymbolRow, store: IndexStore, guessedModulePaths: Set<String>, reachedThrough: Unproven?, mayExtendAnother: Bool = false) throws {
            self.mayExtendAnother = mayExtendAnother
            let chain = try store.parentChain(of: row) + [row]
            // An extension's generic arguments are no part of the path it extends, so `extension Shelf.Box<Int>` is read as `Shelf.Box`.
            let names = chain.map { Self.extendedPath(of: $0) }
            module = row.module
            path = ([module] + names).joined(separator: ".")
            unknownModule = try Self.extendsUnseenType(chain[0], in: store) ? .extendedOnly : guessedModulePaths.contains(row.path) ? .guessedModule : nil
            self.reachedThrough = reachedThrough
            let inner = names.dropFirst()
            guard let outermost = names.first, !inner.contains(where: { $0.contains(".") }) else {
                wholePaths = nil
                droppedLeading = nil
                return
            }
            let written = ([outermost] + inner).joined(separator: ".")
            var paths = [written]
            var dropped: (written: String, rest: String)?
            if let dot = outermost.firstIndex(of: "."), try !Self.declaresTopLevelType(named: String(outermost[..<dot]), in: store) {
                let rest = ([String(outermost[outermost.index(after: dot)...])] + inner).joined(separator: ".")
                paths.append(rest)
                dropped = (written, rest)
            }
            wholePaths = paths
            droppedLeading = dropped
        }

        /// How `alias`, writing `target`, names this declaration, or `nil` where it does not: proven where it is declared at the top level and writes a whole path, with or without the module, or is declared elsewhere and writes any trailing part of the path where a qualifier in it is unaccounted for; kept where it writes a whole path behind one leading name that may be the module, or where this declaration is an alias only kept itself.
        func fold(of target: String, atTopLevel: Bool) -> Fold? {
            if mayExtendAnother, relyOnDroppedLeading(target) || isNamed(by: target, atTopLevel: atTopLevel) {
                return .kept(.extendsAnotherOfTheName, throughKept: false)
            }
            if relyOnDroppedLeading(target) {
                return .kept(reachedThrough ?? .leadingNameMayBeAType, throughKept: reachedThrough != nil)
            }
            if isNamed(by: target, atTopLevel: atTopLevel) {
                return reachedThrough.map { .kept($0, throughKept: true) } ?? .proven
            }
            // Any leading name is kept, a type the tree declares included: that type may be invisible where the alias is written.
            guard let unknownModule, let wholePaths, let dot = target.firstIndex(of: "."),
                  wholePaths.contains(String(target[target.index(after: dot)...]))
            else { return nil }
            return .kept(reachedThrough ?? unknownModule, throughKept: reachedThrough != nil)
        }

        /// Whether an alias writing `target` names this declaration only by reading a dotted extension's leading name as a module: its target is a trailing part of the path without that name, so it never writes the name.
        private func relyOnDroppedLeading(_ target: String) -> Bool {
            guard let droppedLeading else { return false }
            return ("." + droppedLeading.rest).hasSuffix("." + target)
        }

        /// Whether an alias writing `target` provably names this declaration: one where no type is around it only by a whole path, with or without the module, or by any trailing part of the path where a qualifier in it is unaccounted for.
        private func isNamed(by target: String, atTopLevel: Bool) -> Bool {
            guard ("." + path).hasSuffix("." + target) else { return false }
            // Behind an extension of a type the tree does not declare, the module this file is in is not the extended type's, so writing it before the path proves nothing.
            guard unknownModule != .extendedOnly || target != path else { return false }
            guard atTopLevel, let wholePaths else { return true }
            return wholePaths.contains { target == $0 || target == module + "." + $0 }
        }

        /// A row's name, an extension's with its generic arguments set aside.
        private static func extendedPath(of row: SymbolRow) -> String {
            row.kind == .extensionKind && row.name.contains("<") ? DeclaredTypeName.path(ofSpelling: row.name) : row.name
        }

        private static func declaresTopLevelType(named name: String, in store: IndexStore) throws -> Bool {
            try store.symbols(named: name).contains { $0.parentID == nil && ($0.kind.isTypeDeclaration || $0.kind == .typealiasKind) }
        }

        /// Whether `outermost` is an extension written by a bare name that no type this tree declares is provably the one it extends: a top-level type of the name in the extension's module, visible beyond its file, under no `#if`.
        ///
        /// A typealias of the name is no such proof, since it names some other type.
        private static func extendsUnseenType(_ outermost: SymbolRow, in store: IndexStore) throws -> Bool {
            let name = extendedPath(of: outermost)
            guard outermost.kind == .extensionKind, !name.contains(".") else { return false }
            return try !store.symbols(named: name).contains { declared in
                declared.parentID == nil && declared.kind.isTypeDeclaration && declared.module == outermost.module
                    && declared.accessLevel >= .internalLevel && declared.ifConfigCondition == nil
            }
        }
    }
}

private extension SyntacticTypeUsage.AliasChain.WrittenPath {
    /// How an alias names a declaration: by a path that proves it, or by one that is only kept.
    enum Fold: Equatable {
        case proven
        /// Kept, and why; `throughKept` where the declaration it names is itself an alias only kept.
        case kept(SyntacticTypeUsage.AliasChain.Unproven, throughKept: Bool)

        var unproven: SyntacticTypeUsage.AliasChain.Unproven? {
            guard case let .kept(unproven, _) = self else { return nil }
            return unproven
        }

        var throughKept: Bool {
            guard case let .kept(_, throughKept) = self else { return false }
            return throughKept
        }
    }
}

private extension SyntacticTypeUsage.AliasChain.KeptSpelling {
    /// What a kept alias is, in the order the clause names them.
    enum Kind: CaseIterable {
        /// It writes the type's whole path behind a leading name that may be its module.
        case behindLeadingName
        /// It writes a kept alias, or a path through one, rather than the type's.
        case aliasOfKept
        /// It is proven to name the type, but a kept alias shares its name, so a use of the name may be either.
        case sharingNameWithKept

        /// Said after the aliases of this kind in the clause.
        func described(plural: Bool) -> String {
            switch self {
            case .behindLeadingName: "\(plural ? "typealiases" : "a typealias") of its path behind a leading name that may be its module"
            case .aliasOfKept: plural ? "aliases of kept typealiases" : "an alias of a kept typealias"
            case .sharingNameWithKept: plural ? "typealiases naming it whose names kept ones share" : "a typealias naming it whose name a kept one shares"
            }
        }
    }
}
