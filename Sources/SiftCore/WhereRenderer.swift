//
// Copyright © Agulhas Labs
//

import Foundation

/// Resolves a symbol query to declarations, extensions, and conformers — one resolved answer, not text matches.
///
/// With a semantic context, declarations also gain callers (for a property or subscript, its reads and writes), overrides, and store-recorded conformers — refusing per symbol when the declaring file postdates the store's last build, with "build the project" as the instruction (Docs/Design.md §2: this axis cannot self-heal).
struct WhereRenderer {
    let store: IndexStore
    /// Supplies name-matched call sites for symbols the semantic layer could not answer for.
    ///
    /// Optional rather than defaulted-empty so "no scanner wired" and "scanned, found nothing" stay distinguishable: the second is a real finding about the symbol and gets said out loud, and a default that swallowed it would reintroduce exactly the silence this fallback exists to end.
    var callSites: (([String: CallSiteScanner.SiteShape]) async -> [String: [SyntacticCallSite]])?
    /// Whether any file holds a freestanding macro or a custom attribute at file scope, asked only where a type sweep would set a line apart by that; `nil` reads as one may.
    var expandsAtFileScope: (() async -> Bool)?
    /// Supplies the other registered roots whose existing index accounts for the *whole* target — the same cross-root pointer digest serves on a miss, and the same claim strength, since the target is what the line prints.
    var siblingRoots: ((String) -> [SiblingPointer])?
    /// Supplies, for a repo-relative file no store covers, the line naming the Xcode project that builds it, or `nil` when none owns it.
    var projectOwner: ((String) -> String?)?
    /// The repository's project directories (``ModuleResolver/projectDirectories``), which tell a test file outside every project the build covers from one the last build merely skipped; empty where none are supplied, so every file without a unit reads as skipped.
    var projectDirectories: [String] = []
    /// Supplies a declaration's current source lines, or `nil` where they cannot be read: where a stored signature was cut before an initial value, they tell whether a memberwise parameter has a default.
    var declarationSource: ((SymbolRow) -> [String]?)?
    /// Supplies a repo-relative file's current text, or `nil` where it cannot be read: it tells which `#if` a declaration's `#else` is the other branch of.
    var fileSource: ((String) -> String?)?
    /// Supplies what the working tree holds of a bare name outside code, for the `not code` section a `--refs` answer ends with; with none, the answer carries no section.
    var nonCodeMentions: ((String) -> NonCodeMentions)?
    /// Supplies the Swift files git shows that hold a name, for the file accounting the store's conformers block ends with; with none, or `nil` past the scan's bounds, the block carries no such line.
    var textSearchFiles: ((String) -> TextSearchFiles?)?
    /// The revision an `--at` answer reads, as written, or `nil` for the working tree's: its degraded note names it, and its `--refs` answer says in one line in place of the `not code` section that its comments are not read.
    var revision: String?
    /// The Swift files git lists at ``revision``, which the basename pointer names from in place of the store's inventory, since a revision's store holds only the files that spell the name.
    var revisionPaths: [String] = []
    /// Whether a guessed file's build file renames its module through a setting this tool cannot read, so a count told apart by its module says that rather than that it was guessed from the path.
    var isUnreadablyRenamed: (String) -> Bool = { _ in false }
    /// Records, for the `--files` view, every file each section of this render names, from the section's full data (``WhereFilesCollector``); `nil` in every other render.
    var filesCollector: WhereFilesCollector?

    /// What the working tree's module resolution says that an answer needs: where its projects are, and which guessed modules are unreadable renames.
    mutating func takeModuleFacts(from resolver: ModuleResolver) {
        projectDirectories = resolver.projectDirectories
        isUnreadablyRenamed = { [resolver] in resolver.isUnreadablyRenamed($0) }
    }

    /// The revision the basename pointer reads its files from, or `nil` for the working tree's.
    private var basenameRevision: WhereBasenamePointer.Revision? {
        revision.map { WhereBasenamePointer.Revision(name: $0, paths: revisionPaths) }
    }

    static var listCap: Int {
        40
    }

    /// Above this many declarations, rows drop their signature and doc summary — the reader is choosing which one they meant, and `digest` gives the signature for the one they pick.
    static var compactDeclarationThreshold: Int {
        5
    }

    /// Call sites listed per refused symbol before the remainder is counted instead.
    static var callSiteCap: Int {
        40
    }

    /// Semantic relations are resolved for at most this many declarations per query.
    static var semanticDeclCap: Int {
        5
    }

    /// Line numbers listed per file in a grouped reference line before the remainder is counted instead.
    static var lineListCap: Int {
        30
    }

    /// Lines a file may hold and still be listed one row per line, naming what encloses each, where the block's other files are compact line numbers.
    static var rowedFileSiteCap: Int {
        2
    }

    /// Lines a type's name-matched uses may total and still be listed one row per line with their source text, rather than as line numbers per file.
    static var siteTextLineCap: Int {
        40
    }

    func render(query written: String, semantic: SemanticInput, options: WhereOptions = WhereOptions()) async throws -> Output {
        if options.filesOnly, !options.standsInForSearch {
            return try await filesOutput(query: written, semantic: semantic, options: options)
        }
        let paging = SyntacticSweepPaging(offset: options.offset)
        let output = try await render(query: written, semantic: semantic, options: options, paging: paging)
        // An offset is a cursor into a paged list, and with no store open only a no-store sweep's lists page: one sent to any other answer is named as unused rather than served as if it had paged.
        guard !semantic.isActive, options.offset > 0, !paging.pagedAnyList else { return output }
        return Output(body: output.body + "\n(offset \(options.offset) unused — only the lists of a --refs sweep page, and this answer has none)", axis: output.axis)
    }

    /// The answer, with `paging` handed to every name-matched list of a no-store `--refs` sweep and left untouched by any other.
    private func render(query written: String, semantic: SemanticInput, options: WhereOptions, paging: SyntacticSweepPaging) async throws -> Output {
        // A name written in backticks is asked for by the name the index holds, which drops them around an ordinary word.
        let query = SymbolNaming.unbackticked(written)
        // Resolved before the header rather than after it because the header's own caveats depend on what the query
        // resolved to: a type's usage is answered by default, so the two reference boundaries below belong on that
        // answer whether or not --refs was passed, and they are printed above the answer they qualify.
        let declarations = try ExtensionPaths.orSpelled(query, resolved: resolveDeclarations(query: query), in: store)
        let semanticTargets = try SemanticTargets.of(declarations, in: store)
        // A nested package's store answers for that package's files alone, so a query about none of them takes the no-store path.
        let semantic = semantic.answering(forFiles: declarations.map(\.path))
        // No echo of the query: the call carries it, and the declaration rows name what it resolved to.
        var lines: [String] = []
        var axis: SemanticAxis = .syntacticOnly
        var undeclared = UndeclaredInitializer(store: store, semantic: semantic.context, callSites: callSites, declarationSource: declarationSource, filesCollector: filesCollector)
        undeclared.declarationsOnly = options.declarationsOnly
        undeclared.initializerAliases = { try SyntacticTypeUsage.InitializerAliases(ofTypes: [$0], store: store, isUnreadablyRenamed: isUnreadablyRenamed, qualifiedName: qualifiedName(of:)) }
        // Nothing of the store is said under `--decl`: no degraded note, and no pointer to the store where a miss would carry one.
        let storePointer = options.declarationsOnly ? [] : WhereDegradedNote.pointer(semantic: semantic)
        let sweepsByName = try isSweptByName(declarations, query: query, semantic: semantic, options: options, undeclared: undeclared)
        if sweepsByName {
            undeclared.paging = paging
        }
        // One note under the header where the store's relations are withheld: why, what, and the remedy, in place of
        // the mode line, the absence notice and the references line that said one thing three times. Under an open
        // store, a note about the stores only where there is something to say of them; `semantic:` says the rest.
        let degraded = WhereDegradedNote(revision: revision, standIn: standIn(for: semanticTargets), isAskedOfTheStore: isAskedOfTheStore).line(semantic: semantic, sample: semanticTargets)
        switch semantic {
        case .inactive:
            axis = revision == nil ? .off : .syntacticOnly
        case let .unavailable(note):
            axis = SiftEngine.noStoreAxis(from: note)
        case .warming:
            axis = .warming
        case .openFailed:
            axis = .openFailed
        case let .active(context):
            _ = WhereStoreLines.placeStoresNote(context, answeredBy: [], in: &lines)
        }
        // Said only above a list matched by written name: an answer resolving no declaration lists none, unless it is
        // an initializer nobody declared, whose answer places the note itself below.
        if !declarations.isEmpty, !options.declarationsOnly, let degraded {
            lines.append(degraded)
        }
        var narrowingSlot = lines.count
        // The banner is resolved last but printed here, above the answer it qualifies — the same placement lesson refusals taught: a caveat below the content is a caveat read after the decision.
        var bannerSlot = lines.count
        var citedPaths: [String] = []
        lines.append("")

        if declarations.isEmpty {
            // A type built only through an initializer nobody declared under it is answered with where it is built,
            // never as a path that does not resolve: the other types' inits that answer listed are not what was asked.
            if let answer = try await undeclared.answer(for: query) {
                if let degraded, !options.declarationsOnly {
                    lines.insert(degraded, at: narrowingSlot)
                    bannerSlot += 1
                }
                lines += paging.settle(answer.body) + (options.declarationsOnly && answer.declared ? [Self.declarationsOnlyPointer(query: written)] : [])
                if let banner = try parseErrorNotice(touching: answer.cited).banner {
                    lines.insert(banner, at: bannerSlot)
                }
                return Output(body: lines.joined(separator: "\n"), axis: axis)
            }
            // Said apart from "no such symbol", because the two are acted on differently: an unresolvable path is
            // a wrong *address* for a declaration that exists, and answering it with nearest symbols reads as
            // "you have the wrong name" — which sends a caller looking for a member that was in front of it.
            // Every answer below this line is a claim of absence, and each carries the repo-wide notice for it:
            // a file the parser could not finish is how all three of them come to be said about a declaration
            // sitting in plain sight, and the file that would disprove any of them is by definition not among
            // the paths the answer cites.
            let absence = try ParseErrorNotice.acrossRepository(store).absenceBanner
            let elsewhere = try declarationsOfFinalComponent(in: query)
            if !elsewhere.isEmpty {
                if let absence {
                    lines.insert(absence, at: bannerSlot)
                }
                lines.append("could not resolve the path \(query) — \(baseComponent(of: query)) is declared, but not under \(qualifierPath(of: query)):")
                for row in elsewhere.prefix(Self.listCap) {
                    try lines.append("  \(qualifiedName(of: row)) — \(row.kind.rawValue) — \(row.path)\(row.rangeDescription)")
                }
                if elsewhere.count > Self.listCap {
                    lines.append("  truncated: \(elsewhere.count - Self.listCap) more declarations")
                }
                lines.append(contentsOf: siblingPointerLines(for: query))
                return Output(body: lines.joined(separator: "\n"), axis: axis)
            }
            let candidates = try store.searchCandidates(prefix: baseComponent(of: query), limit: 12, qualifiers: qualifierChain(of: query))
            guard !candidates.isEmpty else {
                // The most absolute of the three: not "not here" but "nowhere", with nothing else in the answer
                // for a reader to weigh it against.
                if let absence {
                    lines.insert(absence, at: bannerSlot)
                }
                lines.append("no declarations found")
                try lines.append(contentsOf: WhereBasenamePointer.lines(for: baseComponent(of: query), in: store, at: basenameRevision))
                lines.append(contentsOf: storePointer)
                lines.append(contentsOf: siblingPointerLines(for: query))
                return Output(body: lines.joined(separator: "\n"), axis: axis)
            }
            // A near-miss list is still an answer whose headline is "not here", and a fuzzy candidate is not the
            // declaration that was asked for — so this one is in the class too, rather than left as the one
            // absence answer where the reader has to know the rule to apply it.
            if let absence {
                lines.insert(absence, at: bannerSlot)
            }
            try lines.append(contentsOf: WhereBasenamePointer.lines(for: baseComponent(of: query), in: store, at: basenameRevision) + ["no exact match; nearest symbols:"])
            for row in candidates {
                lines.append("  \(row.name) — \(row.kind.rawValue) — \(row.module) — \(row.path):\(row.line)")
            }
            lines.append(contentsOf: storePointer)
            lines.append(contentsOf: siblingPointerLines(for: query))
            return Output(body: lines.joined(separator: "\n"), axis: axis)
        }

        // A bare name unrelated owners each declare is answered with its declarations and the query that narrows to
        // each; a sweep asked for by name with --refs still lists everything it asked for, and so does a caller that
        // stands the answer in for a search's lines.
        if options.collapsesSeveralOwners, !options.includeReferences, !options.declarationsOnly, let output = try await severalOwnersOutput(lines, bannerSlot: bannerSlot, axis: axis, query: query, declarations: declarations, semantic: semantic) {
            return output
        }

        let block = try declarationsBlock(declarations, query: query, written: written, declarationsOnly: options.declarationsOnly)
        lines += block.lines
        citedPaths += block.cited
        let (extensionListings, printedExtensions) = (block.extensionListings, block.printedExtensions)
        if options.declarationsOnly {
            try await lines += undeclared.lines(beside: declarations, for: query) + [Self.declarationsOnlyPointer(query: written)]
            return try Output(body: withParseNotices(lines, at: bannerSlot, citing: citedPaths).joined(separator: "\n"), axis: axis)
        }

        // Which symbols are left with no caller answer at all — the refused ones under an open store, or every callable declaration when there is no store to refuse from.
        var unanswered: [SymbolRow] = []
        var listedAbove: (SyntacticCallSite) -> Bool = { _ in false }
        var typeUseListedAbove: (SyntacticCallSite) -> Bool = { _ in false }
        var typeUseListedInPlace: (SyntacticCallSite) -> Bool = { _ in false }
        var conformerBlocks: [String: ConformersOnce] = [:]
        var writtenNameChecks: [String: WrittenNameCheck] = [:]
        if case let .active(context) = semantic {
            let wrapperSites = try await WrapperAttributeSites.find(for: semanticTargets, in: store, callSites: callSites, context: context, projectDirectories: projectDirectories)
            let outcome = try appendSemanticSections(for: declarations, query: query, context: context, wrapperSites: wrapperSites, options: options, paging: paging, into: &lines)
            axis = outcome.axis
            // An overload past the ceiling is resolved by no store query, so under --refs its call sites are listed by written name.
            unanswered = try outcome.refused + semanticTargets.filter { $0.kind == .operatorKind } + (options.includeReferences ? SemanticTargets.pastCeiling(declarations, in: store) : [])
            let listingJudge = OccurrenceFreshness(store: store, context: context, projectDirectories: projectDirectories)
            listedAbove = { site in
                outcome.listsAlready(site, modifiedSinceBuild: listingJudge.writtenSinceBuild(file:))
            }
            typeUseListedAbove = outcome.listsTypeUse
            typeUseListedInPlace = outcome.listsTypeUseInPlace
            conformerBlocks = outcome.conformerBlocks
            writtenNameChecks = outcome.writtenNameChecks
            // Placed above everything held open below it, so each slot moves down past it.
            if WhereStoreLines.placeStoresNote(context, answeredBy: outcome.answeredBy, in: &lines) {
                bannerSlot += 1
                narrowingSlot += 1
            }
            if let note = outcome.notCompiledNote {
                lines.insert(note, at: 0)
                bannerSlot += 1
                narrowingSlot += 1
            }
            WhereStoreLines.appendProjectHintsIfAllowed(to: &lines, for: outcome.uncovered, owner: projectOwner, inTreeWarming: context.inTreeWarming, primaryProvenance: context.store.provenance)
        } else {
            unanswered = semanticTargets.filter { isAskedOfTheStore($0.kind) || $0.kind == .operatorKind }
            // Suppressed once the note already says the in-tree walk was cut short: the hint's advice —
            // build inside the tree — may already be exactly what happened, just past where the walk reached.
            if case let .unavailable(note) = semantic, !note.hasSuffix(SiftEngine.inTreeWalkTruncatedClause) {
                WhereStoreLines.appendNoStoreProjectHints(to: &lines, for: unanswered, owner: projectOwner)
            }
        }
        // A type is answered by the places its name is written, never by a scan for calls spelling it: one reached
        // only through its static members or in annotations is called nowhere, and "no call" of it reads as "unused".
        // With a store, the extension of a type the tree does not declare is no row the store refused, and its declaration
        // line is all the store says of it: its uses are the lines writing the extended name, found as they are with no store.
        let typeUse = try semantic.isActive
            ? typeUseRows(of: unanswered.filter { SyntacticTypeUsage.standsIn(for: $0.kind) } + semanticTargets.filter { $0.kind == .extensionKind }, among: declarations)
            : typeUseRows(of: unanswered, among: declarations)
        let typeUseIDs = Set(typeUse.map(\.id))
        let pointer = options.includeReferences || options.standsInForSearch ? nil : try typeUsePointer(for: typeUse.first, among: declarations, query: query, qualifiedName: qualifiedName(of:))
        try await lines += SyntacticTypeUsage(store: store, callSites: callSites, expandsAtFileScope: expandsAtFileScope, pointer: pointer, fileSource: fileSource, isUnreadablyRenamed: isUnreadablyRenamed, filesCollector: filesCollector)
            .lines(for: typeUse, qualifiedName: qualifiedName(of:), listedAbove: typeUseListedAbove, listedInPlace: typeUseListedInPlace, paging: sweepsByName ? paging : nil)
        let fallbackRows = unanswered.filter { !typeUseIDs.contains($0.id) && $0.kind != .extensionKind }
        let sameNamed = SameNamedTypes(store: store)
        try await lines += SyntacticCallerFallback.lines(
            for: fallbackRows,
            declaredAs: declarations,
            callSites: callSites,
            callSiteCap: options.nameMatchedSiteCap ?? Self.callSiteCap,
            listedAbove: listedAbove,
            initializerLabelsWereNamed: (splitQualified(query).last ?? query).contains("("),
            qualifiedName: qualifiedName(of:),
            receivers: MemberReceivers.lookup(qualifiedBy: splitQualified(query).dropLast(), in: store),
            sameNamed: sameNamed,
            paging: sweepsByName ? paging : nil,
            memberwise: MemberwiseLabelSites(rows: fallbackRows, sameNamed: sameNamed, source: declarationSource),
            listsLabelCalls: options.includeReferences,
            filesCollector: filesCollector,
            initializerAliases: { try SyntacticTypeUsage.InitializerAliases(of: $0, store: store, isUnreadablyRenamed: isUnreadablyRenamed, qualifiedName: qualifiedName(of:)) }
        )
        // A type of the name that declares no init of its own is built all the same, and its sites are not the initializers' above.
        try await lines += undeclared.lines(beside: declarations, for: query)
        // A name-matched sweep that found nothing is an empty verdict like the store's: the same sentences, and the degraded note's own "not unused" clause dropped so that exactly one caveat is said.
        lines = SyntacticCallerFallback.endingInTheCaveatsIfEmpty(lines, degradedNote: degraded)
        try appendTypeRelations(of: declarations, conformerBlocks: conformerBlocks, writtenNameChecks: writtenNameChecks, extensions: (extensionListings, printedExtensions), citing: &citedPaths, into: &lines, qualifiedName: qualifiedName(of:))
        // Last, after every declaration's sections, and before the pager settles, since its rows join the answer's one window.
        try await lines += nonCodeLines(for: declarations, query: query, options: options, paging: paging, joinsPager: !semantic.isActive)
        // Every paged list is in now, so the one window they all show is known and each list's slot is filled.
        lines = paging.settle(lines)
        if sweepsByName, paging.spansPages, let line = try narrowingLine(declarations, query: query) {
            lines.insert(line, at: narrowingSlot)
            bannerSlot += 1
        }

        // Every count in this answer is read out of a repository-wide lookup: `declarations (N)` through
        // `resolveDeclarations` → `symbols(named:)`, `extensions of X (N)` through `ExtensionPaths.extensions(ofTypeNamed:in:)`,
        // and `conformers of X (N, …)` through `conformers(of:)`. A row lost with the tail of a truncated file
        // is missing from its number *and* from the cited paths, so the banner below goes quiet about the only
        // file that could explain it. One note for all three, because three would be the noise a single one
        // avoids — and counted rather than listed, because that banner is often present here and a wider list
        // printed beside it nests one inside the other; see `ParseErrorNotice.floorNote(about:)` for the rule.
        //
        // Inserted before the banner so that the banner ends up above it: both go in at `bannerSlot`, and the
        // later insert takes the line.
        return try Output(body: withParseNotices(lines, at: bannerSlot, citing: citedPaths).joined(separator: "\n"), axis: axis)
    }

    /// Whether a declaration of this kind has relations only the store answers — callers, uses, conformers — so that with no store the name-matched section stands in for them.
    ///
    /// An associated type is used by being written, as a typealias is; so is the type an extension names, which counts here only where no declaration of that type is in the tree to stand in for it (``typeUseRows(of:among:)``).
    private func isAskedOfTheStore(_ kind: SymbolKind) -> Bool {
        callersApply(to: kind) || kind.isUsedRatherThanCalled || kind.isTypeDeclaration || kind == .typealiasKind || kind == .associatedType || kind == .extensionKind
    }

    /// The rows whose written name stands in for their uses with no store open: a type, a typealias, an associated type, and an extension of a type the tree does not declare, whose sites are then every line writing the extended name.
    ///
    /// An extension of a type the tree declares at the path it writes is that type's own, already counted under its declaration; one written through a dotted path is scanned by its final component (``SyntacticTypeUsage``).
    private func typeUseRows(of rows: [SymbolRow], among declarations: [SymbolRow]) throws -> [SymbolRow] {
        let declaredPaths = try ExtensionPaths.declared(among: declarations, in: store)
        return rows.filter { row in
            switch row.kind {
            case .associatedType: true
            case .extensionKind: !declaredPaths.contains(row.name)
            default: SyntacticTypeUsage.standsIn(for: row.kind)
            }
        }
    }

    /// What the name-matched section stands in with for these declarations: nothing when every one it would scan for is a subscript, uses when any is a property or an enum case, calls otherwise.
    private func standIn(for declarations: some Sequence<SymbolRow>) -> StandIn {
        let scanned = declarations.filter { isAskedOfTheStore($0.kind) }
        if !scanned.isEmpty, scanned.allSatisfy({ $0.kind == .subscriptKind }) {
            return .nothing
        }
        return declarations.contains { $0.kind == .variable || $0.kind == .enumCase } ? .uses : .calls
    }

    /// Whether the store is asked for a declaration's callers: only functions and initializers, which are called.
    ///
    /// A property or subscript is read and written instead (``SymbolKind/isReadAndWritten``), and asking the store for its calls finds none however much it is used.
    private func callersApply(to kind: SymbolKind) -> Bool {
        switch kind {
        case .function, .initializer: true
        default: false
        }
    }

    // MARK: Resolution

    /// The declaration rows a query resolves to — the resolution step `digest Type.member` shares with `where`.
    func declarations(for query: String) throws -> [SymbolRow] {
        try resolveDeclarations(query: query)
    }

    /// Handles `Name`, `Module.Name`, `Type.member`, and labeled forms like `save(_:to:)`.
    private func resolveDeclarations(query: String) throws -> [SymbolRow] {
        let hasDot = query.contains(".") && !query.hasPrefix(".")
        guard hasDot else {
            return try store.symbols(named: query)
        }
        let components = splitQualified(query)
        let lastName = components.last ?? query
        let qualifiers = Array(components.dropLast())
        let matches = try store.symbols(named: lastName)
        return try matches.filter { row in
            try QualifiedPath.matches(
                qualifiers: qualifiers,
                chain: store.parentChain(of: row).map(\.name),
                module: row.module
            )
        }
    }

    /// Splits on dots outside parentheses, so `save(_:to:)` survives as one component.
    private func splitQualified(_ query: String) -> [String] {
        QualifiedPath.components(of: query)
    }

    /// What an empty or self-only finding says of the places outside code: listed below where this answer ends with the `not code` section, pointed at where it could, and left to grep for a name a rename does not respell.
    private func nonCodePointer(query: String, options: WhereOptions) -> String {
        guard WhereNonCodeSection.bareName(of: baseComponent(of: query)) != nil else { return "check comments and strings with grep" }
        return listsNonCode(query: query, options: options) ? WhereNonCodeSection.listedBelow : WhereNonCodeSection.pointer
    }

    /// Whether this answer ends with a `not code` section listing what the tree holds of the name outside code.
    func listsNonCode(query: String, options: WhereOptions) -> Bool {
        options.includeReferences && !options.standsInForSearch && nonCodeMentions != nil && revision == nil && WhereNonCodeSection.bareName(of: baseComponent(of: query)) != nil
    }

    /// The `not code` section of a `--refs` answer, keyed on the query's bare name; none for the hook's in-place answers or a name a rename does not respell.
    private func nonCodeLines(for declarations: [SymbolRow], query: String, options: WhereOptions, paging: SyntacticSweepPaging, joinsPager: Bool) async throws -> [String] {
        guard options.includeReferences, !options.standsInForSearch, let name = WhereNonCodeSection.bareName(of: baseComponent(of: query)) else { return [] }
        guard revision == nil else { return ["", WhereNonCodeSection.atRevisionLine] }
        guard let nonCodeMentions else { return [] }
        let isAmbiguous = try splitQualified(query).count > 1 || unrelatedOwners(of: declarations, query: query) != nil
        let mentions = nonCodeMentions(name)
        filesCollector?.recordNotCode(mentions)
        return WhereNonCodeSection(mentions: mentions, isAmbiguous: isAmbiguous).lines(offset: options.offset, paging: paging, joinsPager: joinsPager)
    }

    private func baseComponent(of query: String) -> String {
        QualifiedPath.baseName(of: splitQualified(query).last ?? query)
    }

    /// The qualifiers of a dotted query, as written — the path the final component was looked for under.
    private func qualifierPath(of query: String) -> String {
        splitQualified(query).dropLast().joined(separator: ".")
    }

    /// The whole qualifier chain written before the final component, outermost first — `["Engine"]` for `Engine.start(mod:)`, `["Settings", "DetailData"]` for `Settings.DetailData.load(i:)`, `["App", "Engine"]` for `App.Engine.start(mod:)` — or empty for an unqualified query.
    ///
    /// What a labeled-member miss's fuzzy candidates are ranked against, since that chain is what the miss belongs to — and exactly the qualifiers `resolveDeclarations` hands `QualifiedPath.matches`, so ranking judges the path by the rule resolution just applied to it.
    private func qualifierChain(of query: String) -> [String] {
        Array(splitQualified(query).dropLast())
    }

    /// The declarations of a dotted query's *final* component when none of them sits under the qualifiers written before it — what separates "this path does not resolve" from "no such symbol".
    ///
    /// Empty where one of them *does* sit under the qualifiers: then the path resolved and only the labeled spelling missed (`Engine.start(mod:)` for `start(mode:)`), which is a different failure with a different answer — the candidate list, which names the labels.
    private func declarationsOfFinalComponent(in query: String) throws -> [SymbolRow] {
        let components = splitQualified(query)
        guard components.count > 1 else { return [] }
        let qualifiers = Array(components.dropLast())
        let rows = try store.symbols(named: baseComponent(of: query))
        for row in rows {
            let chain = try store.parentChain(of: row).map(\.name)
            if QualifiedPath.matches(qualifiers: qualifiers, chain: chain, module: row.module) {
                return []
            }
        }
        return rows
    }

    /// The cross-root pointer for a missed query — one line per sibling root whose existing index accounts for it, same claim strength and wording as digest's.
    private func siblingPointerLines(for query: String) -> [String] {
        guard let siblingRoots else { return [] }
        let pointers = siblingRoots(query)
        guard !pointers.isEmpty else { return [] }
        return [""] + pointers.map { $0.line(for: query) }
    }

    func qualifiedName(of row: SymbolRow) throws -> String {
        try store.qualifiedName(of: row)
    }
}

extension WhereRenderer {
    /// Whether a `--refs` answer is swept by name: with no store at all, the name-matched sites are the only sweep there is, so they are listed whole and the line says what they are rather than sending the reader to grep; a subscript, whose uses spell no name, has none.
    ///
    /// A `T.init` of a type that declares no init resolves no declaration at all, and its sites are swept the same way.
    private func isSweptByName(_ declarations: [SymbolRow], query: String, semantic: SemanticInput, options: WhereOptions, undeclared: UndeclaredInitializer) throws -> Bool {
        guard case .unavailable = semantic, options.includeReferences else { return false }
        guard !declarations.isEmpty else { return try undeclared.buildsAnUndeclaredType(query) }
        let sample = try SemanticTargets.of(declarations, in: store)
        return sample.contains { isAskedOfTheStore($0.kind) } && standIn(for: sample) != .nothing
    }

    /// The line a sweep by name of a bare name several unrelated owners declare carries once it runs past one page: a written name cannot tell the owners' sites apart, so the query that narrows to one is named; `nil` where the name has one owner.
    private func narrowingLine(_ declarations: [SymbolRow], query: String) throws -> String? {
        guard let owners = try unrelatedOwners(of: declarations, query: query), let first = declarations.first(where: { owners[$0.id] != nil }), let owner = owners[first.id] else { return nil }
        let narrowing = try narrowingQuery(to: owner, query: query, owners: owners)
        return "references: \(Set(owners.values).count) unrelated owners declare \"\(query)\", and a match by written name cannot tell their sites apart, so this sweep pages through every owner's — "
            + (narrowing.hasPrefix("where ") ? "narrow it to one owner's, as `\(narrowing) --refs`" : "narrow it to one owner by qualifying the name with its type")
    }

    /// What stands in for the store's callers under the degraded note, which is what an empty list of it means.
    enum StandIn {
        /// Calls spelling the name.
        case calls
        /// Every expression spelling the name — a property's or an enum case's.
        case uses
        /// Nothing: every declaration left is a subscript, whose uses spell no name to match.
        case nothing
    }
}

/// The store-backed half of a `where` answer: the relations, the rows the tree no longer backs, and the header verdict all three feed.
extension WhereRenderer {
    // MARK: Semantic sections

    /// Resolves relations for the declarations `SemanticTargets.of(_:in:)` picks, rendering only what it actually found.
    ///
    /// Emptiness is summarised, never itemised: a declaration with no recorded callers contributes one name to a single trailing line instead of its own three-line block, and refusals group by file rather than repeating for every declaration in it. Density is the product — five "none recorded in the store" blocks cost the reader more than the answer is worth.
    private func appendSemanticSections(
        for declarations: [SymbolRow],
        query: String,
        context primary: SemanticContext,
        wrapperSites: WrapperAttributeSites,
        options: WhereOptions,
        paging: SyntacticSweepPaging? = nil,
        into lines: inout [String]
    ) throws -> SemanticOutcome {
        // The rule the declaring-file refusal uses, applied to the *cited* files: a store keeps every occurrence
        // the last build recorded, including ones in files the tree no longer has (Docs/Design.md §2). One judge
        // per store, each file judged against its own build in the store whose rows cite it first.
        var judges = [primary.store.cache.directory.path: OccurrenceFreshness(store: store, context: primary, projectDirectories: projectDirectories, citedBy: primary.store)]
        // Each declaring file is judged against its own build, across every store the query reads.
        let declaringFiles = OccurrenceFreshness(store: store, context: primary, projectDirectories: projectDirectories)
        var answeredBy: [String] = []
        var uncovered: [SymbolRow] = []
        let targets = try SemanticTargets.of(declarations, in: store)
        let names = try DeclarationShortNames(declarations, qualifiedName: qualifiedName(of:))
        var refusals: [SemanticRefusal] = []
        var refusedRows: [SymbolRow] = []
        var listedSites: [SyntacticCallSite] = []
        var recordedCalls: Set<String> = []
        var typeUses: [String: Bool] = [:]
        // A protocol's conformers, one block per name, rendered where the scan by written name would have put its own.
        var conformerBlocks: [String: ConformersOnce] = [:]
        var writtenNameChecks: [String: WrittenNameCheck] = [:]
        var sections: [String] = []
        var withoutCallers: [String] = []
        var implementersWithoutCallers: [String] = []
        var verdicts = try ZeroUseVerdict(store: store, context: primary, projectDirectories: projectDirectories, declarations: targets)
        var callerEligible = 0
        // A property or subscript is never called — the store records its reads and writes on its own USR and the call on an accessor's — so it is asked for those instead, and its empty case says that is what was looked for: "no callers" said of one reads as dead code, which is how a live constant gets deleted.
        var withoutUses: [String] = []
        var implementersWithoutUses: [String] = []
        var useEligible = 0
        // Whether a use inside an observer a macro moved was listed: its row sits on the macro's line, and what that leaves out is said beside it.
        var listedMovedObserver = false
        // An enum case is neither called nor read: the store records every use of one as a reference on its own USR — a call too only where a payload is built — so that is what it is asked for, and its empty case says uses were looked for.
        var withoutCaseUses: [String] = []
        var implementersWithoutCaseUses: [String] = []
        var caseEligible = 0

        var withoutReferences: [String] = []
        var referenceEligible = 0

        // A type is neither called nor read: what it has is references, and putting them behind --refs left the
        // default answer with no section at all and no empty case either — silence a deletion unit read as "nothing
        // uses this" while twelve tests called the type's statics. So a type's references are resolved here, always,
        // and the verdict the decision is made from is the first line of them.
        var withoutUsage: [String] = []
        var usedOnlyByItself: [String] = []
        var namedOnlyByItsAliases: [String] = []
        var usageEligible = 0

        // A typealias's own deletion question is different from its underlying type's, and the fold above already
        // answers the type's — so a typealias query gets a verdict of its own, in the same buckets and the same
        // vocabulary, counting the alias's own name (folded with any alias *of* the alias) rather than the type
        // it names. Kept apart from the type's arrays above so the two questions are never summarised together.
        var withoutAliasUsage: [String] = []
        var aliasNamedOnlyByItsAliases: [String] = []
        var aliasUsageEligible = 0
        // Whether any fold behind the two "and nothing uses those either" sentences stopped at its cap, which is
        // the one condition under which that clause is a guess rather than a finding.
        var namedOnlyByItsAliasesCapped = false
        var aliasNamedOnlyByItsAliasesCapped = false

        // One query's use files, read once however many lookups resolve a sibling spelling in them. Never held past this query: the refusal below is judged on each symbol's own file, so a use file edited since the build is read as it stands now.
        var sourceLines = SemanticStore.SourceLines()

        // How many of the targets are even eligible to be refused — extensions never are — so a refusal set that
        // covers every one of them can be told apart from a refusal set that covers only some.
        var consideredCount = 0

        for row in targets {
            // An extension carries no USR of its own — the store anchors the type's canonical occurrence at the type's declaration, and the extension's *members* hold their own USRs. Refusing it would print "build the project, then retry" against something no build can ever resolve.
            // An operator declaration (`infix operator <~>`) is never recorded by the store, so no build answers for it: its uses are found by the scan of written operators below instead.
            guard row.kind != .extensionKind, row.kind != .operatorKind else { continue }
            consideredCount += 1
            let qualified = try qualifiedName(of: row)
            let file = try store.fileRow(path: row.path)
            // The first store that resolves the declaration owns it — the primary, then each in-tree store in path
            // order — and everything below is read from that store alone, against its own build.
            guard let owned = primary.owner(of: row) else {
                refusals.append(SemanticRefusal.unowned(row, symbol: qualified, file: file, kind: declaringFiles.kind(ofFile: row.path), context: primary, source: fileSource))
                refusedRows.append(row)
                // Coverage before staleness: a file no store has a unit for is one no build of these stores covers,
                // however recently it was edited, so it gets the project hint whatever its date.
                if !primary.anyStoreHasUnit(forFile: row.path) {
                    uncovered.append(row)
                }
                continue
            }
            let context = owned.context
            let usr = owned.usr
            // Named whether this store goes on to answer or refuses below, not only when it answers.
            if context.store !== primary.store, !answeredBy.contains(context.store.provenance.name) {
                answeredBy.append(context.store.provenance.name)
            }
            if let refusal = SemanticRefusal.changed(row, symbol: qualified, file: file, kind: declaringFiles.kind(ofFile: row.path, citedBy: context.store), holder: context.store) {
                refusals.append(refusal)
                refusedRows.append(row)
                continue
            }
            let judgeKey = context.store.cache.directory.path
            let occurrences = judges[judgeKey] ?? OccurrenceFreshness(store: store, context: primary, projectDirectories: projectDirectories, citedBy: context.store)
            judges[judgeKey] = occurrences
            verdicts.noteSetAside(ofUSR: usr, inStore: judgeKey, context.store.setAsideReferences(ofUSR: usr), relativePath: context.relativePath)
            // A type use listed on a line of its own, at the column its name is written, which a refused declaration of the name's stand-in lists no second time — only while its file is unchanged since the build.
            let recordTypeUse: (SemanticStore.Hit, Bool) -> Void = { hit, listed in
                if row.kind.isTypeDeclaration || row.kind == .typealiasKind, occurrences.state(of: hit.path).isLive {
                    let key = "\(context.relativePath(hit.path)):\(hit.line):\(hit.column)"
                    typeUses[key] = listed || typeUses[key] == true
                }
            }
            // Each line `callers of` lists on a row of its own, repo-relative, which `references to` then does not list again.
            var callSitesAbove: Set<String> = []
            if callersApply(to: row.kind) {
                callerEligible += 1
                let callers = context.store.callers(ofUSR: usr)
                // The store records no call where a property wrapper is written on a function's parameter, so those attribute sites are listed by name after its answer, and "no callers" is never said over one.
                if callers.isEmpty, !wrapperSites.hasSites(for: row) {
                    // A function that implements a requirement is called through it too, and none of those calls is recorded against the function: its empty case is hedged on a line of its own, out of the summary's arithmetic.
                    ImplementedRequirement.file(qualified, implementing: context.store.implementedRequirements(ofUSR: usr), relation: .calls, verdict: verdicts, plain: &withoutCallers, hedged: &implementersWithoutCallers)
                } else if !callers.isEmpty {
                    // A call counts as listed only where its own line is: a fold's count or a truncation stands for it without showing it.
                    var ownLines: Set<String> = []
                    let heading = ImplementedRequirement.listHeading(of: qualified, implementing: context.store.implementedRequirements(ofUSR: usr))
                    let qualifier = try [heading.qualifier, WhereCallersResolvedClause(store: store).clause(for: row, bare: splitQualified(query).count == 1)].compactMap(\.self).joined(separator: "; ")
                    sections.append(contentsOf: hitSection(heading.title, hits: callers, noun: "call site", qualifier: qualifier.isEmpty ? nil : qualifier, foldByCaller: true, context: context, occurrences: occurrences) { hit in
                        ownLines.insert("\(hit.path):\(hit.line)")
                        callSitesAbove.insert("\(context.relativePath(hit.path)):\(hit.line)")
                    })
                    recordedCalls.formUnion(callers.filter { ownLines.contains("\($0.path):\($0.line)") }.map { "\(context.relativePath($0.path)):\($0.line):\($0.column)" })
                }
                sections.append(contentsOf: wrapperSites.lines(for: row, owner: names.name(of: row), cap: Self.callSiteCap, judgedBy: occurrences, under: context.repoRoot, recording: filesCollector))
                listedSites += wrapperSites.sites(for: row, cap: Self.callSiteCap)
            }
            if row.kind.isReadAndWritten {
                useEligible += 1
                let found = context.store.uses(ofUSR: usr, sources: &sourceLines)
                listedMovedObserver = listedMovedObserver || found.contains(where: \.inMovedObserver)
                let uses = Self.collapsedUses(found, markingReferences: true)
                if uses.isEmpty {
                    // A property or subscript that satisfies a requirement is read through it too, and none of those reads is recorded against it, so its empty case is hedged as a function's is.
                    ImplementedRequirement.file(qualified, implementing: context.store.implementedRequirements(ofUSR: usr), relation: .uses, verdict: verdicts, plain: &withoutUses, hedged: &implementersWithoutUses)
                } else {
                    let heading = ImplementedRequirement.listHeading(of: qualified, implementing: context.store.implementedRequirements(ofUSR: usr), relation: .uses)
                    sections.append(contentsOf: listedSection(heading.title, rows: uses, noun: "use", qualifier: heading.qualifier, context: context, occurrences: occurrences))
                }
            }
            if row.kind == .enumCase {
                caseEligible += 1
                let uses = Self.collapsedUses(context.store.caseUses(ofUSR: usr))
                if uses.isEmpty {
                    // A case that witnesses a protocol's static requirement (`case standard` for `static var standard: Self`) is used through it, which the store records against the requirement, so its empty case is hedged as a property's is.
                    ImplementedRequirement.file(qualified, implementing: context.store.implementedRequirements(ofUSR: usr), relation: .uses, verdict: verdicts, plain: &withoutCaseUses, hedged: &implementersWithoutCaseUses)
                } else {
                    sections.append(contentsOf: listedSection("uses of \(qualified)", rows: uses, noun: "use", context: context, occurrences: occurrences))
                }
            }
            // A protocol's conformers merge the store's with the scan's into one block, which its usage rows then do not repeat; a second protocol of the same name keeps the store's own block, so none of its conformers leaves the answer.
            let mergesConformers = row.kind == .protocolKind && conformerBlocks[row.name] == nil
            var conformance: ConformersOnce?
            if mergesConformers {
                conformance = try conformersOnce(of: row, usr: usr, context: context, occurrences: occurrences, qualifiedName: qualifiedName(of:))
                conformerBlocks[row.name] = conformance ?? ConformersOnce(lines: [], citedPaths: [], clauseLines: [])
            }
            // Resolved once and handed to the sweep view below, which lists the same rows in full.
            var typeReferences: [SemanticStore.Hit]?
            var typeGeneratedLines: Set<String> = []
            // The files the conformers block's accounting counts as using it or aliasing it, from the sections that list them.
            var accounted = ConformerFileAccounting.Listed(block: conformance)
            if row.kind.isTypeDeclaration {
                usageEligible += 1
                // A use written through a typealias is recorded against the alias, so references to the type's own USR
                // cannot see it — and `1 production · 0 tests` said of a type three tests use through an alias, the
                // one line being the alias declaration itself, is this section's own defect wearing a number. The
                // aliases are discovered from the references themselves, where the store records the aliasing, and
                // folded in before anything is counted or denied.
                let (references, fold) = try foldedReferences(ofUSR: usr, named: row.name, context: context, sources: &sourceLines)
                typeReferences = references
                typeGeneratedLines = fold.generatedLines
                let spans = try ownSpans(of: row, extendedAt: context.store.extensionSites(ofUSR: usr), relativePath: context.relativePath)
                let own = Self.excludingSites(references + fold.hits, inside: spans.spans, relativePath: context.relativePath)
                // A `typealias Crate = Gizmo` names the type without using it, the same as an `extension Gizmo`
                // header, and is taken out on the same ground — whatever uses the alias is a use and was folded in
                // just above. Counted, it made a type nothing at all uses read as `2 production`.
                let usage = Self.excludingSites(own.sites, inside: fold.declarationSpans, relativePath: context.relativePath)
                (accounted.uses, accounted.aliases) = (Set(usage.sites.map { context.relativePath($0.path) }), Set(fold.declarationSpans.keys))
                if usage.sites.isEmpty, usage.excluded > 0 {
                    namedOnlyByItsAliases.append(qualified)
                    namedOnlyByItsAliasesCapped = namedOnlyByItsAliasesCapped || fold.reachedCap
                } else if usage.sites.isEmpty, own.excluded > 0 {
                    usedOnlyByItself.append(qualified)
                } else if usage.sites.isEmpty {
                    withoutUsage.append(qualified)
                } else {
                    try sections.append(contentsOf: usageSection(
                        for: qualified,
                        hits: usage.sites,
                        excludedLines: own.excluded,
                        otherModuleExtensions: spans.otherModuleExtensions,
                        otherModuleExtensionsGuessed: spans.otherModuleExtensionsGuessed,
                        aliasDeclarationLines: usage.excluded,
                        options: options,
                        aliasFoldCapped: fold.reachedCap,
                        conformanceLines: conformance.map { $0.folded(options.includeReferences ? $0.startLines : $0.clauseLines, among: usage.sites, relativePath: context.relativePath) } ?? [],
                        pointing: query.contains(".") ? query : names.name(of: row),
                        context: context,
                        occurrences: occurrences,
                        targetsNotBuilt: verdicts.targetsNotBuilt.names,
                        shown: recordTypeUse
                    ))
                }
            }
            // A typealias is not a type declaration (``SymbolKind/isTypeDeclaration``) — the sibling branch above
            // never runs for it — but it is exactly as neither-called-nor-read, and "used by <alias>" is a
            // deletion unit's question the same way "used by <Type>" is. The fold this reuses is the one built for
            // a *type's* aliases; asked from the alias's own USR it does the same job one hop sideways — an alias
            // of this alias is itself the alias's aliasing, so it folds in the same way.
            if row.kind == .typealiasKind {
                aliasUsageEligible += 1
                let (references, fold) = try foldedReferences(ofUSR: usr, named: row.name, excluding: usr, context: context, sources: &sourceLines)
                typeReferences = references
                typeGeneratedLines = fold.generatedLines
                // Only one of the type's two exclusions carries across. A type's own declaration and extension
                // headers spell its name without using it; an alias has neither to take out. Its declaration
                // records no reference to itself at all — a definition is not a reference — so the only lines that
                // rule could ever remove from an alias are a use written on the declaration's own line and an
                // `extension <alias>` header, and both of those stop compiling when the alias goes. Taking them
                // out said "no uses of Lib.Crate — every reference recorded falls inside its own declaration" of an
                // alias something was still spelling. What remains is the aliases *of* this alias, which are
                // another name for it rather than use of it, exactly as they are for a type.
                let usage = Self.excludingSites(references + fold.hits, inside: fold.declarationSpans, relativePath: context.relativePath)
                if usage.sites.isEmpty, usage.excluded > 0 {
                    aliasNamedOnlyByItsAliases.append(qualified)
                    aliasNamedOnlyByItsAliasesCapped = aliasNamedOnlyByItsAliasesCapped || fold.reachedCap
                } else if usage.sites.isEmpty {
                    withoutAliasUsage.append(qualified)
                } else {
                    try sections.append(contentsOf: usageSection(
                        for: qualified,
                        hits: usage.sites,
                        aliasDeclarationLines: usage.excluded,
                        options: options,
                        aliasFoldCapped: fold.reachedCap,
                        isAlias: true,
                        pointing: query.contains(".") ? query : names.name(of: row),
                        context: context,
                        occurrences: occurrences,
                        targetsNotBuilt: verdicts.targetsNotBuilt.names,
                        shown: recordTypeUse
                    ))
                }
            }
            if options.includeReferences {
                var references = typeReferences ?? []
                var generatedLines = typeGeneratedLines
                if typeReferences == nil {
                    (references, generatedLines) = context.store.referencesAndGeneratedMentions(ofUSR: usr, sources: &sourceLines)
                }
                // A type's (or a typealias's) emptiness has already been said by its usage line, in the noun that
                // decision is made in; repeating it here would read as a second finding rather than the same one.
                if !row.kind.isTypeDeclaration, row.kind != .typealiasKind {
                    referenceEligible += 1
                    if references.isEmpty {
                        withoutReferences.append(qualified)
                    }
                }
                accounted.uses.formUnion(references.map { context.relativePath($0.path) })
                if !references.isEmpty {
                    sections.append(contentsOf: referenceSection(for: qualified, hits: references, offset: options.offset, context: context, occurrences: occurrences, paging: paging, callSitesAbove: callSitesAbove, conformanceLines: conformance.map { $0.folded($0.startLines, among: references, relativePath: context.relativePath) } ?? [], generatedMentions: generatedLines.subtracting(references.map { "\($0.path):\($0.line)" }).count, shown: { recordTypeUse($0, true) }))
                }
            }
            conformerBlocks[row.name]?.lines += fileAccounting(of: row, usr: usr, listed: accounted, options: options, context: context, occurrences: occurrences)
            // In the tree means indexed: the SDK sits outside the root, and a dependency's checkout under `.build` is never indexed.
            let overrides = context.store.overrides(ofUSR: usr) { (try? store.fileRow(path: context.relativePath($0))) != nil }
            if !overrides.isEmpty {
                // The store's overrideOf relation covers protocol witnesses as well as class overrides — verified against a real store, where a mock's method is recorded against the protocol requirement it witnesses. Heading a protocol requirement's list "overrides" reads as classes-only and leaves the reader unsure witnesses are covered; the parent kind knows which word is true.
                let parentIsProtocol = try store.parentChain(of: row).last?.kind == .protocolKind
                sections.append(contentsOf: hitSection(
                    parentIsProtocol ? "implementations of \(qualified)" : "overrides of \(qualified)",
                    hits: overrides,
                    noun: parentIsProtocol ? "implementation" : "override",
                    context: context,
                    occurrences: occurrences
                ))
            }
            if row.kind.isTypeDeclaration, !mergesConformers {
                let semanticConformers = context.store.semanticConformers(ofUSR: usr)
                // The store records a subclass only where its clause writes the class, or, as an implicit occurrence, through one of its own typealiases; so a class's block holds its direct subclasses alone, each written through an alias marked with it, and the block by written name below carries the walked ones.
                let storeRows = Self.collapsedIdentical(semanticConformers).map { ListedRow(hit: $0.hit, units: $0.units, access: $0.hit.uncalled ? "referenced, not called" : nil) }
                let (accepted, rows) = try ownAliasRows(of: row, usr: usr, listed: storeRows, context: context)
                writtenNameChecks[row.name, default: WrittenNameCheck()].add(usr: usr, context: context, occurrences: occurrences, aliases: accepted)
                if !rows.isEmpty {
                    sections.append(contentsOf: listedSection(
                        "conformers of \(row.name)",
                        rows: rows,
                        noun: "conformer",
                        qualifier: row.kind == .classKind ? "direct subclasses from the store" : "from the store",
                        context: context,
                        occurrences: occurrences
                    ))
                }
            }
        }

        // Refused and answered lockstep with `refusedRows` — each pair appended together above — so a refusal's
        // own qualified name (its `symbol`) looks its declaration's short name up without recomputing it.
        let refusedShortNames = zip(refusals, refusedRows).reduce(into: [String: String]()) { dict, pair in
            dict[pair.0.symbol] = names.name(of: pair.1)
        }
        lines.append(contentsOf: SemanticRefusal.lines(
            refusals,
            namingDeclarations: false,
            declarationsSpanMultipleFiles: Set(declarations.map(\.path)).count > 1,
            allListedRefused: consideredCount > 0 && refusedRows.count == consideredCount,
            shortName: { refusedShortNames[$0.symbol] ?? $0.symbol }
        ))
        verdicts.noteSetAside(wrapperSites.setAside)
        lines.append(contentsOf: sections + (verdicts.setAsideLine.map { ["", $0] } ?? []))
        let callerSummary = [verdicts.summary(withoutCallers, eligible: callerEligible, noun: "callers", preposition: "of")].compactMap(\.self) + implementersWithoutCallers
        lines += callerSummary.isEmpty ? [] : [""] + callerSummary
        // What the store cannot record of every property or case (a synthesized conformance's, by name at runtime) is
        // said in the answer that lists none (Docs/Design.md §2, *standing caveats*); a moved observer's boundary is this answer's own.
        let useSummary = [verdicts.summary(withoutUses, eligible: useEligible, noun: "reads or writes", preposition: "of")].compactMap(\.self) + implementersWithoutUses
        let useLines = useSummary + (listedMovedObserver ? [Self.movedObserverBoundary] : [])
        if !useLines.isEmpty {
            lines.append("")
            lines.append(contentsOf: useLines)
        }
        let caseLines = [verdicts.summary(withoutCaseUses, eligible: caseEligible, noun: "uses", preposition: "of")].compactMap(\.self) + implementersWithoutCaseUses
        if !caseLines.isEmpty {
            lines.append("")
            lines.append(contentsOf: caseLines)
        }
        let nonCode = nonCodePointer(query: query, options: options)
        // A type that nothing uses is the one answer this section exists to make sayable out loud, so it is said in
        // the same words the sweep view uses for an empty result — and a type whose every recorded reference sits
        // inside its own declaration or its extensions in this module is a different finding, not the same one:
        // references exist, and none of them is a use.
        if let summary = verdicts.summary(withoutUsage, eligible: usageEligible, noun: "references", preposition: "to") {
            lines.append("")
            lines.append(summary + " — \(nonCode)")
        }
        if let summary = verdicts.summary(usedOnlyByItself, eligible: usageEligible, noun: "uses", preposition: "of") {
            lines.append("")
            // Under `--refs` the sweep lists exactly the lines this sentence is disowning, and a reader not told so
            // reads the two as contradicting each other rather than as one finding and its evidence. It is *above*
            // this sentence: the sections are appended before every summary line, so a sentence pointing downward
            // points at the extensions block and leaves the listing it owns unclaimed.
            let evidence = options.includeReferences ? " — the references listed above are those lines" : ""
            lines.append(summary + " — every reference recorded falls inside its own declaration or its extensions in this module, which is the type spelling its own name\(evidence); \(nonCode)")
        }
        // A third finding, not either of the two above: references exist, and every one of them is the type being
        // given another name rather than being used. It is worth its own sentence because the deletion it clears is
        // bigger than the type — the aliases go with it — and because "2 production" was what this used to say.
        if let summary = verdicts.summary(namedOnlyByItsAliases, eligible: usageEligible, noun: "uses", preposition: "of") {
            lines.append("")
            let evidence = options.includeReferences ? " — the references listed above are those lines" : ""
            let aliasesGo = namedOnlyByItsAliasesCapped ? Self.foldStoppedShort : "and nothing uses those aliases either, so they go with it"
            lines.append(summary + " — every reference recorded is the type declaring itself or a typealias declaration naming it, which is another name for the type rather than use of it, \(aliasesGo)\(evidence); \(nonCode)")
        }
        if let summary = verdicts.summary(withoutReferences, eligible: referenceEligible, noun: "references", preposition: "to") {
            lines += ["", summary + " — \(nonCode)"]
        }
        // The alias's own three findings, worded exactly like the type's above, with one clause added throughout:
        // which name this counted. Without it, "no references to Nickname" reads as "nothing uses Gizmo either",
        // which is the type's answer given under the alias's name.
        let aliasCounts = " — counts the alias's own name, and any typealias of it, not the type it names, which may still be used directly, under its own name, without it"
        if let summary = verdicts.summary(withoutAliasUsage, eligible: aliasUsageEligible, noun: "references", preposition: "to") {
            lines.append("")
            lines.append(summary + aliasCounts + "; \(nonCode)")
        }
        if let summary = verdicts.summary(aliasNamedOnlyByItsAliases, eligible: aliasUsageEligible, noun: "uses", preposition: "of") {
            lines.append("")
            let evidence = options.includeReferences ? " — the references listed above are those lines" : ""
            let aliasesGo = aliasNamedOnlyByItsAliasesCapped ? Self.foldStoppedShort : "and nothing uses those either, so they go with it"
            lines.append(summary + " — every reference recorded is another typealias naming it, which is another name for it rather than use of it, \(aliasesGo)\(evidence)" + aliasCounts + "; \(nonCode)")
        }
        // An empty verdict is where "not proof it is unused" matters, so the standing caveats are said here on every one of them (no callers, uses or references; only the type's own lines; only its aliases; only the requirement it implements) and on no answer that lists something.
        let emptyVerdicts = withoutCallers + withoutUses + withoutCaseUses + withoutUsage + withoutReferences + withoutAliasUsage
            + usedOnlyByItself + namedOnlyByItsAliases + aliasNamedOnlyByItsAliases
            + implementersWithoutCallers + implementersWithoutUses + implementersWithoutCaseUses
        if !emptyVerdicts.isEmpty {
            lines += ["", StandingCaveats.sentences]
        }
        // The store records nothing in a file it holds no unit for, a new one above all, nor what a file it holds has written since the build, so a lower bound names the lines there that write the name, which a rename trusting the answer would otherwise miss, and the header counts each file no store holds that it names.
        let mentions = try WhereChangedFileMentions(names: ScannedNames(rows: targets.filter { row in row.kind != .extensionKind && row.kind != .operatorKind && !refusedRows.contains { $0.id == row.id } }, in: store), unbuilt: verdicts.filesOutsideTheBuild, refused: Set(refusals.map(\.path)), in: store, context: primary, judge: declaringFiles, listsEveryLine: options.includeReferences, offset: options.offset)
        lines = mentions.placed(in: lines)
        filesCollector.map(mentions.record(into:))
        if let note = try SemanticTargets.capNote(for: declarations, includeReferences: options.includeReferences, in: store) {
            lines.append("")
            lines.append(note)
        }
        // A declaration no open store resolves, while an in-tree store is still loading, may be that store's to answer: said as warming, a wait, rather than as unresolved, a build — but never where a refusal here is already the stronger, unconditional fact a loading store could never change.
        let waitsOnInTree = primary.inTreeWarming && !uncovered.isEmpty && !refusals.contains(where: \.reason.isStale)
        let counted = SemanticAxis.countedFiles(refusals: refusals, occurrences: Array(judges.values), listedByName: mentions.listedFiles)
        return try SemanticOutcome(
            axis: waitsOnInTree ? .warming : .of(refusals: refusals, occurrences: Array(judges.values), testFilesWithoutUnit: primary.testFileCoverage(in: store).partialCount, targetsNotBuilt: verdicts.targetsNotBuilt, listedByName: mentions.listedFiles),
            refused: refusedRows,
            notCompiledNote: NotCompiledNote.line(for: counted, refused: Set(refusals.map(\.path)), in: store, context: primary),
            answeredBy: answeredBy,
            uncovered: uncovered,
            listedSites: listedSites,
            recordedCalls: recordedCalls,
            typeUses: typeUses,
            conformerBlocks: conformerBlocks,
            writtenNameChecks: writtenNameChecks
        )
    }

    /// One titled block of hits, capped with a truncation marker.
    ///
    /// Never called with an empty list — an empty relation is summarised, not headed.
    ///
    /// Hits on one line — same symbol, same file — collapse to one row, marked `×N units` when more than one build unit recorded it (``collapsedIdentical(_:)``). This is rendering, not the silent under-reporting Docs/Design.md §8 forbids: the duplicates that carry information are the *drifted* ones from multi-target stores (same call, lines disagreeing), and those stay listed as-is because they are genuinely ambiguous evidence. Copies on one line carry no distinct information, and the count in the heading matches the rows listed, so the answer still reconciles with itself.
    ///
    /// A row whose file the tree no longer has, or has written since the build, is **labelled, not dropped**: the store's memory of a deleted file is exactly what a delete sweep reads it for, and withholding it would answer a real question with silence. Labelled rows sort last so a truncated section spends its cap on the rows that still stand, and the heading names how many of its own rows it is disowning.
    private func hitSection(
        _ title: String,
        hits: [SemanticStore.Hit],
        noun: String,
        qualifier: String? = nil,
        foldByCaller: Bool = false,
        context: SemanticContext,
        occurrences: OccurrenceFreshness,
        shown: (SemanticStore.Hit) -> Void = { _ in }
    ) -> [String] {
        let rows = Self.collapsedIdentical(hits).map { ListedRow(hit: $0.hit, units: $0.units, access: $0.hit.uncalled ? "referenced, not called" : nil) }
        return listedSection(title, rows: rows, noun: noun, qualifier: qualifier, foldByCaller: foldByCaller, context: context, occurrences: occurrences, shown: shown)
    }

    /// The block ``hitSection(_:hits:noun:qualifier:foldByCaller:context:occurrences:)`` describes, from rows already collapsed: a property's uses arrive collapsed per line by `collapsedUses`, each printing the access it records after its location.
    ///
    /// With `foldByCaller`, rows sharing one calling function collapse to that function's first call site, carrying the rest as a site count — a caller matters once, however many of its own lines call the subject, and grouping by name and file rather than by adjacency survives a store that interleaves a caller's own sites with another's.
    ///
    /// `shown` is handed each row printed on a line of its own, never one only counted in a fold or past the cap.
    private func listedSection(
        _ title: String,
        rows: [ListedRow],
        noun: String,
        qualifier: String? = nil,
        foldByCaller: Bool = false,
        context: SemanticContext,
        occurrences: OccurrenceFreshness,
        shown: (SemanticStore.Hit) -> Void = { _ in }
    ) -> [String] {
        let judged = rows.map { (entry: $0, state: occurrences.state(of: $0.hit.path)) }
        judged.forEach { filesCollector?.recordCode(path: context.relativePath($0.entry.hit.path), lines: [$0.entry.hit.line], state: $0.state) }
        let ordered = judged.filter(\.state.isLive) + judged.filter { !$0.state.isLive }
        var details = ["\(judged.count)"] + [qualifier].compactMap(\.self)
        var statesByPath: [String: OccurrenceState] = [:]
        for row in judged {
            statesByPath[row.entry.hit.path] = row.state
        }
        details.append(contentsOf: Self.driftDetails(states: Array(statesByPath.values)))
        var block = ["", "\(title) (\(details.joined(separator: ", "))):"]
        // Few enough to read in place: one row per site with its source text, so neither the fold nor the cap is reached.
        if judged.count <= Self.siteTextLineCap {
            return block + Self.siteTextRows(ordered, relativePath: context.relativePath, shown: shown)
        }
        let displayed = foldByCaller ? CallerFoldedRow.folded(ordered) : ordered.map { CallerFoldedRow(entry: $0.entry, state: $0.state, sites: 1) }
        for row in displayed.prefix(Self.listCap) {
            shown(row.entry.hit)
            let units = row.entry.units > 1 ? "  ×\(row.entry.units) units" : ""
            let access = row.entry.access.map { " — \($0)" } ?? ""
            let sites = row.sites > 1 ? " (\(row.sites) sites)" : ""
            block.append("  \(row.entry.hit.name) — \(context.relativePath(row.entry.hit.path)):\(row.entry.hit.line)\(access)\(units)\(sites)\(row.state.marker ?? "")")
        }
        if displayed.count > Self.listCap {
            let residual = displayed.count - Self.listCap
            block.append("  truncated: \(residual) more \(foldByCaller ? "caller\(residual == 1 ? "" : "s")" : "\(noun)\(residual == 1 ? "" : "s")")")
        }
        return block
    }

    /// The heading clauses that disown part of what the section is nevertheless listing, changed before deleted as the header orders them — never omitted when they apply, since a count that silently includes dead rows is the defect this whole path exists to end.
    ///
    /// Counted in **files**, whatever the section lists, and worded identically in both: the header's own count is in files, and two sections disowning in different units invite the reader to compare numbers that were never the same measurement. One `states` entry per distinct file is the caller's job.
    static func driftDetails(states: [OccurrenceState]) -> [String] {
        var details: [String] = []
        let deleted = states.count { $0 == .deleted }
        let modified = states.count { $0 == .modifiedSinceBuild }
        if modified > 0 {
            details.append("\(modified) file\(modified == 1 ? "" : "s") changed since last build")
        }
        if deleted > 0 {
            details.append("\(deleted) file\(deleted == 1 ? "" : "s") deleted since last build")
        }
        return details
    }

    /// What a use inside an observer a macro moved cannot show — where it is written — stated wherever one is listed: its row sits on the macro's line, and a reference sweep drops it, since there is nothing to rename there.
    static var movedObserverBoundary: String {
        "observers: a macro that moves a property into generated storage, as @Observable does, moves its didSet and willSet with it — the store records their uses at the macro's line, never where they are written, so a reference sweep lists none of their lines"
    }
}

extension WhereRenderer {
    /// A rendered `where` answer plus the semantic axis it earned.
    struct Output {
        let body: String
        let axis: SemanticAxis
    }
}

/// The extension's access, conformance, and where-clause context (`(private)`, `(: Equatable)`, `where T: Sendable`), recovered from its signature for headings.
///
/// The conformance colon is searched only *before* any `where` clause, so `extension S where T: Sendable` reports its constraint as a where-clause — never a fabricated "(: Sendable)" conformance.
func extensionContext(_ row: SymbolRow) -> String {
    let stripped = AttributeScanner.strippingLeadingAttributes(SourceSlicer.tidyingBrackets(in: row.signature))
    var parts: [String] = []
    if let firstWord = stripped.split(separator: " ").first.map(String.init),
       AccessLevel(rawValue: firstWord) != nil
    {
        parts.append("(\(firstWord))")
    }
    let whereRange = stripped.range(of: " where ")
    let clauseEnd = whereRange?.lowerBound ?? stripped.endIndex
    if let colonRange = stripped.range(of: ": "), colonRange.upperBound <= clauseEnd {
        let conformance = stripped[colonRange.lowerBound ..< clauseEnd].trimmingCharacters(in: .whitespaces)
        parts.append("(" + conformance + ")")
    }
    if let whereRange {
        parts.append(stripped[whereRange.lowerBound...].trimmingCharacters(in: .whitespaces))
    }
    return parts.isEmpty ? "" : " " + parts.joined(separator: " ")
}
