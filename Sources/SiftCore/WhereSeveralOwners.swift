//
// Copyright © Agulhas Labs
//

import Foundation

/// The answer to a bare name that unrelated owners each declare: the declarations, each with its use count and the qualified query that narrows to it, and no use listings.
///
/// Every owner's uses listed under one name answered a question about one of them at many times the length the question needed, most of it about declarations nobody asked for. The narrowing query is the step the reader takes next, so it is checked by resolving it rather than composed and trusted.
extension WhereRenderer {
    /// The query a plain no-store type answer names as the one listing the uses it counts: the query as written when qualified, else the first row's shortest name that tells it from the same-named declarations listed with it, as the store path's blocks name theirs.
    func typeUsePointer(for row: SymbolRow?, among declarations: [SymbolRow], query: String, qualifiedName: (SymbolRow) throws -> String) throws -> String {
        guard !query.contains("."), let row else { return query }
        return try DeclarationShortNames(declarations, qualifiedName: qualifiedName).name(of: row)
    }

    /// The owner path each declaration of a bare query sits under, keyed by row id, where they fall under two or more owners no written inheritance or conformance relates; `nil` where the query is qualified or every declaration is one owner's.
    ///
    /// Overloads share an owner, and an override or a witness is the member it implements reached by dispatch, so neither is several owners. An extension row is the type it extends rather than a declaration of its own, so it decides nothing.
    func unrelatedOwners(of declarations: [SymbolRow], query: String) throws -> [Int64: String]? {
        guard !query.contains(".") else { return nil }
        var ownerOf: [Int64: String] = [:]
        var typeNameOf: [String: String] = [:]
        var extended: [Int64: [String]] = [:]
        for row in declarations where row.kind != .extensionKind {
            let chain = try store.parentChain(of: row)
            let path = try ownerPath(module: row.module, chain: chain, extended: &extended).joined(separator: ".")
            ownerOf[row.id] = path
            if let container = chain.last {
                typeNameOf[path] = DeclaredTypeName.last(ofPath: container.name)
            }
        }
        var families = Set(ownerOf.values).sorted().map { Set([$0]) }
        guard families.count > 1 else { return nil }
        for (owner, typeName) in typeNameOf.sorted(by: { $0.key < $1.key }) {
            let related = try Self.inheritors(of: typeName, in: store)
            let joined = families.filter { family in
                family.contains(owner) || family.contains { typeNameOf[$0].map(related.contains) ?? false }
            }
            guard joined.count > 1 else { continue }
            families.removeAll { joined.contains($0) }
            families.append(joined.reduce(into: Set<String>()) { $0.formUnion($1) })
        }
        return families.count > 1 ? ownerOf : nil
    }

    /// The owner path of a member whose container chain is `chain`, with an extension it sits in replaced by the path of the one type it extends.
    ///
    /// An extension written in another module names a type by its written name, so it is attached to the type of that name in its own module where there is one, else to the only type of that name, and left as written where several could be meant. Joining owners by short type name instead made two unrelated types that happen to share a name one owner.
    private func ownerPath(module: String, chain: [SymbolRow], extended: inout [Int64: [String]]) throws -> [String] {
        guard let outermost = chain.first, outermost.kind == .extensionKind else {
            return [module] + chain.map(\.name)
        }
        if extended[outermost.id] == nil {
            let types = try declarations(for: outermost.name).filter(\.kind.isTypeDeclaration)
            let local = types.filter { $0.module == outermost.module }
            let chosen = local.count == 1 ? local.first : types.count == 1 ? types.first : nil
            extended[outermost.id] = try chosen.map { try [$0.module] + store.parentChain(of: $0).map(\.name) + [$0.name] } ?? [module, outermost.name]
        }
        return (extended[outermost.id] ?? []) + chain.dropFirst().map(\.name)
    }

    /// The whole answer for a bare name several unrelated owners declare — the header lines so far, then the declarations with their counts and narrowing queries — or `nil` where the query is not one.
    func severalOwnersOutput(_ header: [String], bannerSlot: Int, axis: SemanticAxis, query: String, declarations: [SymbolRow], semantic: SemanticInput) async throws -> Output? {
        guard let owners = try unrelatedOwners(of: declarations, query: query) else { return nil }
        let answer = try await severalOwnersLines(query: query, declarations: declarations, owners: owners, semantic: semantic)
        var lines = header + answer.lines
        var slot = bannerSlot
        if case let .active(context) = semantic, WhereStoreLines.placeStoresNote(context, answeredBy: answer.answeredBy, in: &lines) {
            slot += 1
        }
        if let note = answer.notCompiledNote {
            lines.insert(note, at: 0)
            slot += 1
        }
        let cited = declarations.prefix(Self.listCap).map(\.path)
        return try Output(body: withParseNotices(lines, at: slot, citing: cited).joined(separator: "\n"), axis: answer.axis ?? axis)
    }

    /// The answer with the repository-wide floor note and the cited files' parse-error banner inserted at `slot`, the banner above the note.
    func withParseNotices(_ lines: [String], at slot: Int, citing citedPaths: [String]) throws -> [String] {
        var lines = lines
        if let note = try ParseErrorNotice.acrossRepository(store).floorNote(about: .whereCounts) {
            lines.insert(contentsOf: [note], at: slot)
        }
        if let banner = try parseErrorNotice(touching: citedPaths).banner {
            lines.insert(contentsOf: [banner], at: slot)
        }
        return lines
    }

    /// The parse-error notice for the files this answer cites.
    ///
    /// Answer-scoped, like the digest's: a file with parse errors elsewhere in the repo could in principle hide a conformer this query should have listed, but warning about all of them on every `where` is exactly the undifferentiated noise that makes a header count ignorable. The repo-wide set is what `status` names.
    func parseErrorNotice(touching paths: [String]) throws -> ParseErrorNotice {
        let affected = try Set(store.filesWithParseErrors().map(\.path))
        return ParseErrorNotice(paths: paths.filter(affected.contains))
    }

    /// The lines that replace the use listings for a bare name several unrelated owners declare, and the header verdict the store's counts leave.
    func severalOwnersLines(query: String, declarations: [SymbolRow], owners: [Int64: String], semantic: SemanticInput) async throws -> SeveralOwnersAnswer {
        let listed = Array(declarations.prefix(Self.listCap))
        let ownerCount = Set(owners.values).count
        var lines = ["declarations (\(declarations.count)) under \(ownerCount) owners — a bare name several owners declare lists no uses; each line ends with the query that narrows to its owner:"]
        var counter: OwnerUseCounter?
        let targets = try SemanticTargets.of(declarations, in: store)
        let counted = Set(targets.map(\.id))
        if case let .active(context) = semantic {
            let wrapperSites = try await WrapperAttributeSites.find(for: targets, in: store, callSites: callSites, context: context, projectDirectories: projectDirectories)
            counter = OwnerUseCounter(primary: context, wrapperSites: wrapperSites, store: store, projectDirectories: projectDirectories)
        }
        var narrowingOf: [String: String] = [:]
        for row in listed {
            var fields = try ["  \(store.qualifiedName(of: row))", row.kind.rawValue, "\(row.path)\(row.rangeDescription)"]
            guard let owner = owners[row.id] else {
                lines.append(fields.joined(separator: " — "))
                continue
            }
            if counter != nil {
                if counted.contains(row.id) {
                    try fields.append(counter?.count(of: row, renderer: self) ?? "")
                } else {
                    fields.append("uses not counted — past the first \(targets.count) declarations")
                }
            }
            if narrowingOf[owner] == nil {
                narrowingOf[owner] = try narrowingQuery(to: owner, query: query, owners: owners)
            }
            fields.append(narrowingOf[owner] ?? "")
            lines.append(fields.joined(separator: " — "))
        }
        if declarations.count > Self.listCap {
            lines.append("  truncated: \(declarations.count - Self.listCap) more declarations")
        }
        // The bare `extension Name` rows are declarations of the name and already lines above; what is left is written through a qualified path, and is an owner's only where that path ends the owner's own path (`Outer.Name` for `Beta.Outer`), the reading the owner's narrowing query lists it by.
        let shown = Set(declarations.map(\.id))
        let ownerPaths = Set(owners.values).sorted().map { ($0, QualifiedPath.components(of: $0)) }
        var unlisted = 0
        var pointedAt: [String] = []
        for written in try ExtensionPaths.written(endingIn: query, in: store) where !shown.contains(written.row.id) {
            let qualifier = Array(QualifiedPath.components(of: written.path).dropLast())
            guard !qualifier.isEmpty else { continue }
            // Several owners can end in the qualifier; as `ownerPath` does, the one in the extension's own module is the one extended, else the only match, and an extension that could be any of several is counted under none, since no one owner's query is known to list it.
            let matching = ownerPaths.filter { Array($0.1.suffix(qualifier.count)) == qualifier }
            let local = matching.filter { $0.1.first == written.row.module }
            guard let owner = (local.count == 1 ? local.first : matching.count == 1 ? matching.first : nil)?.0 else { continue }
            let narrowing = try narrowingOf[owner] ?? narrowingQuery(to: owner, query: query, owners: owners)
            narrowingOf[owner] = narrowing
            guard narrowing.hasPrefix("where ") else { continue }
            unlisted += 1
            if !pointedAt.contains(narrowing) {
                pointedAt.append(narrowing)
            }
        }
        if unlisted > 0 {
            lines.append("extensions: \(unlisted) more written through a qualified name, not listed here — an owner's own query lists its extensions: \(pointedAt.joined(separator: ", "))")
        }
        guard let counter else {
            lines.append("uses: not counted — only the index store tells which of these a use names, and this answer has none (the note above says why)")
            return SeveralOwnersAnswer(lines: lines, axis: nil, answeredBy: [])
        }
        let primary = counter.primary
        // The counts are the store's, so a file no store holds a unit for, a new caller above all, has its lines writing the name listed after them and counted in the header, as the single-owner answer does.
        let mentions = try WhereChangedFileMentions(
            names: ScannedNames(rows: targets.filter { $0.kind != .extensionKind && $0.kind != .operatorKind }, in: store),
            unbuilt: [],
            refused: Set(counter.refusals.map(\.path)),
            in: store,
            context: primary,
            judge: counter.declaringFiles,
            listsEveryLine: false,
            readsStoredFiles: false
        )
        lines = mentions.placed(in: lines)
        var setAside = counter.setAside
        setAside.merge(counter.wrapperSites.setAside)
        if let line = setAside.line {
            lines += ["", line]
        }
        let waitsOnInTree = primary.inTreeWarming && counter.uncovered && !counter.refusals.contains(where: \.reason.isStale)
        let axis: SemanticAxis = try waitsOnInTree ? .warming : .of(
            refusals: counter.refusals,
            occurrences: Array(counter.judges.values),
            testFilesWithoutUnit: primary.testFileCoverage(in: store).partialCount,
            listedByName: mentions.listedFiles
        )
        let stale = SemanticAxis.countedFiles(refusals: counter.refusals, occurrences: Array(counter.judges.values), listedByName: mentions.listedFiles)
        let note = try NotCompiledNote.line(for: stale, refused: Set(counter.refusals.map(\.path)), in: store, context: primary)
        return SeveralOwnersAnswer(lines: lines, axis: axis, answeredBy: counter.answeredBy, notCompiledNote: note)
    }

    /// The lines a several-owners answer adds, the header verdict its store counts leave (`nil` where none were read), the in-tree stores that answered, and the note on modules a later build left out.
    struct SeveralOwnersAnswer {
        let lines: [String]
        let axis: SemanticAxis?
        let answeredBy: [String]
        /// The note under the header naming the modules a later build left out (``NotCompiledNote``).
        var notCompiledNote: String?
    }

    /// The shortest qualified query that resolves to declarations of `owner` alone, qualified by as few of its containers as tell it apart, or a sentence saying none does.
    func narrowingQuery(to owner: String, query: String, owners: [Int64: String]) throws -> String {
        let components = QualifiedPath.components(of: owner)
        for length in 1 ... max(components.count, 1) {
            let candidate = (components.suffix(length) + [query]).joined(separator: ".")
            let resolved = try declarations(for: candidate).filter { $0.kind != .extensionKind }
            let resolvedOwners = try resolved.map { row in
                try owners[row.id] ?? ([row.module] + store.parentChain(of: row).map(\.name)).joined(separator: ".")
            }
            if !resolved.isEmpty, resolvedOwners.allSatisfy({ $0 == owner }) {
                return "where \(candidate)"
            }
        }
        return "no qualified query resolves to this owner alone"
    }

    /// Every type name whose inheritance clause names `typeName`, followed transitively and bounded, by written name.
    ///
    /// The name itself is not among them unless a clause writes it: another type that merely shares the name is not related by that.
    private static func inheritors(of typeName: String, in store: IndexStore) throws -> Set<String> {
        var visited: Set<String> = [typeName]
        var reached: Set<String> = []
        var pending = [typeName]
        while let next = pending.popLast(), visited.count < inheritorCap {
            for row in try store.conformers(of: next) {
                let name = DeclaredTypeName.last(ofPath: row.name)
                reached.insert(name)
                if visited.insert(name).inserted {
                    pending.append(name)
                }
            }
        }
        return reached
    }

    /// Type names followed out from one owner before the walk stops; past it, owners it did not reach are answered as unrelated.
    private static var inheritorCap: Int {
        500
    }
}

/// Counts one declaration's uses from the store for the several-owners answer, in the distinct lines and the production · tests split the type verdict uses.
struct OwnerUseCounter {
    let primary: SemanticContext
    let wrapperSites: WrapperAttributeSites
    let store: IndexStore
    private(set) var judges: [String: OccurrenceFreshness] = [:]
    private(set) var refusals: [SemanticRefusal] = []
    private(set) var answeredBy: [String] = []
    private(set) var uncovered = false
    /// The sites the stores set aside for the declarations counted, which the answer says as a single owner's does.
    private(set) var setAside = SetAsideSites()
    private var sources = SemanticStore.SourceLines()
    /// Each declaring file, and each file the answer lists by name, judged against its own build, across every store the query reads.
    let declaringFiles: OccurrenceFreshness
    private let projectDirectories: [String]

    init(primary: SemanticContext, wrapperSites: WrapperAttributeSites, store: IndexStore, projectDirectories: [String]) {
        self.primary = primary
        self.wrapperSites = wrapperSites
        self.store = store
        declaringFiles = OccurrenceFreshness(store: store, context: primary, projectDirectories: projectDirectories)
        self.projectDirectories = projectDirectories
        judges[primary.store.cache.directory.path] = OccurrenceFreshness(store: store, context: primary, projectDirectories: projectDirectories, citedBy: primary.store)
    }

    /// The count clause for `row`: `3 uses: 2 production · 1 test`, or why it was not counted.
    mutating func count(of row: SymbolRow, renderer: WhereRenderer) throws -> String {
        let qualified = try store.qualifiedName(of: row)
        let file = try store.fileRow(path: row.path)
        // No build records an operator declaration, so none is refused with advice to build one.
        guard row.kind != .operatorKind else { return "uses not counted — the index store records no operator declaration" }
        guard let owned = primary.owner(of: row) else {
            let refusal = SemanticRefusal.unowned(row, symbol: qualified, file: file, kind: declaringFiles.kind(ofFile: row.path), context: primary, source: renderer.fileSource)
            refusals.append(refusal)
            if !primary.anyStoreHasUnit(forFile: row.path) {
                uncovered = true
            }
            return switch refusal.reason {
            case .modifiedSinceBuild: "uses not counted — its file was changed since the last build"
            case .newSinceBuild: "uses not counted — its file is new since the last build"
            case .unrecordedUnderCondition, .outsidePackage: "uses not counted — " + refusal.reason.shortClause(declarationCount: 1)
            case .noCoveringUnit: "uses not counted — no build in the store covers its file"
            }
        }
        let context = owned.context
        if context.store !== primary.store, !answeredBy.contains(context.store.provenance.name) {
            answeredBy.append(context.store.provenance.name)
        }
        if let refusal = SemanticRefusal.changed(row, symbol: qualified, file: file, kind: declaringFiles.kind(ofFile: row.path, citedBy: context.store), holder: context.store) {
            refusals.append(refusal)
            return "uses not counted — its file was changed since the last build"
        }
        let key = context.store.cache.directory.path
        let occurrences = judges[key] ?? OccurrenceFreshness(store: store, context: primary, projectDirectories: projectDirectories, citedBy: context.store)
        judges[key] = occurrences
        guard let (hits, asked) = try hits(of: row, usr: owned.usr, context: context, renderer: renderer) else {
            return "uses not counted — the store is not asked about a \(row.kind.rawValue)"
        }
        setAside.note(ofUSR: owned.usr, inStore: key, context.store.setAsideReferences(ofUSR: owned.usr), relativePath: context.relativePath)
        // A call or read made through a requirement the function, property or subscript implements is never recorded against it, so its count is of direct ones, and says why.
        let implemented = row.kind == .function || row.kind == .initializer || row.kind.isReadAndWritten ? context.store.implementedRequirements(ofUSR: owned.usr) : []
        let noun = implemented.isEmpty ? asked : "direct \(asked)"
        let grouped = WhereRenderer.ReferencedFiles(hits: hits, context: context, occurrences: occurrences)
        let deleted = try Set(store.deletionLedger().entries.keys)
        let split = try renderer.countingUnbuiltTests(in: WhereRenderer.usageSplit(sitesByPath: grouped.paths.map { ($0, grouped.lines(in: $0).count) }, deleted: deleted) {
            try store.fileRow(path: $0)?.imports
        }, context: context)
        var clause = "\(grouped.sites) \(noun)\(grouped.sites == 1 ? "" : "s"): " + split.tally.joined(separator: " · ")
        let drift = WhereRenderer.driftDetails(states: grouped.states)
        if !drift.isEmpty {
            clause += " (\(drift.joined(separator: ", ")))"
        }
        if wrapperSites.hasSites(for: row) {
            clause += ", and property-wrapper attribute sites the store does not record"
        }
        if !implemented.isEmpty {
            clause += ", and " + ImplementedRequirement.hedge(implemented, relation: row.kind.isReadAndWritten ? .uses : .calls)
        }
        return clause
    }

    /// The store's hits for `row` in the relation its kind is asked for, with the noun a count of them is in, or `nil` for a kind the store is not asked about.
    private mutating func hits(of row: SymbolRow, usr: String, context: SemanticContext, renderer: WhereRenderer) throws -> (hits: [SemanticStore.Hit], noun: String)? {
        switch row.kind {
        case .function, .initializer:
            return (context.store.callers(ofUSR: usr), "call site")
        case .enumCase:
            return (context.store.caseUses(ofUSR: usr).map(\.hit), "use")
        case .typealiasKind:
            let (references, fold) = try renderer.foldedReferences(ofUSR: usr, named: row.name, excluding: usr, context: context, sources: &sources)
            return (WhereRenderer.excludingSites(references + fold.hits, inside: fold.declarationSpans, relativePath: context.relativePath).sites, "reference")
        case _ where row.kind.isReadAndWritten:
            return (context.store.uses(ofUSR: usr, sources: &sources).map(\.hit), "use")
        case _ where row.kind.isTypeDeclaration:
            let (references, fold) = try renderer.foldedReferences(ofUSR: usr, named: row.name, context: context, sources: &sources)
            let spans = try renderer.ownSpans(of: row, extendedAt: context.store.extensionSites(ofUSR: usr), relativePath: context.relativePath)
            let own = WhereRenderer.excludingSites(references + fold.hits, inside: spans.spans, relativePath: context.relativePath)
            return (WhereRenderer.excludingSites(own.sites, inside: fold.declarationSpans, relativePath: context.relativePath).sites, "reference")
        default:
            return nil
        }
    }
}
