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

    /// The two boundaries a resolved reference sweep carries, on one line: what the store records is code, and only what this repository's own build compiled, with the sibling-repo and uncompiled-target cases named.
    static var referenceBoundaryLine: String {
        "references: code only (not comments or strings) and this repo's own build only (a sibling repo or an uncompiled target has no occurrence here) — check those before deleting"
    }

    /// What an answer says about the half of the question the semantic pass did not answer — one line, not the paragraph this used to be.
    ///
    /// The full reasoning (why an empty fallback list is not "nothing uses this", what a name-matched fallback does and does not match) lives once in `sift help worktree-index`, and the `mode:` line directly above already names this call's semantic state and what to do about it, so this points there rather than repeating either. Worded to hold in every state it is shown for — including `.warming` and `.openFailed`, where a store exists but this call still could not read it — so it never claims "no index store" when the mode line above says otherwise.
    ///
    /// Called only when the caller asked for callers/overrides at all — `render` skips it for `--syntactic`, which turned them off on purpose.
    static func absenceNotice(standIn: StandIn, isType: Bool = false) -> String {
        // A type's default section is headed "used by", never "callers/overrides" — its declarations have
        // neither — so the no-store notice standing in for that section names the same word, or a reader
        // comparing the header this answer would have carried against the one in front of them finds no match.
        let label = isType ? "used by" : "callers/overrides"
        let opening = "\(label): NOT ANSWERED from the index store"
        // Said only on the type's own notice, since the reader of the answer may never open the help topic that
        // carries the full reasoning: the syntactic stand-in matches the type's written name and the names of the
        // typealiases of it the index holds, so a use under any other name — an alias declared inside a function
        // body, or a string literal — is invisible to it, and an empty list here is not "nothing uses this".
        let caveat = isType ? " (by written name — an empty list is not \"unused\")" : ""
        guard standIn != .nothing else {
            return opening + caveat + " (a subscript has no name-matched fallback either); see the mode line above."
        }
        return opening + caveat + "; see the mode line above."
    }

    /// Line numbers listed per file in a grouped reference line before the remainder is counted instead.
    static var lineListCap: Int {
        30
    }

    /// Lines a type's name-matched uses may total and still be listed one row per line with their source text, rather than as line numbers per file.
    static var siteTextLineCap: Int {
        40
    }

    func render(query written: String, semantic: SemanticInput, options: WhereOptions = WhereOptions()) async throws -> Output {
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
        var lines = ["where \(query)"]
        var axis: SemanticAxis = .syntacticOnly
        // Where the two reference boundaries go, held open while the semantic pass decides whether there is anything
        // for them to bound. They are printed above the answer they qualify, but only the pass knows whether that
        // answer exists: a row refused for staleness resolves no reference or usage material at all, and the
        // declaration kinds alone cannot see that coming.
        var boundaryPoint: Int?
        var undeclared = UndeclaredInitializer(store: store, semantic: semantic.context, callSites: callSites, declarationSource: declarationSource)
        let sweepsByName = try isSweptByName(declarations, query: query, semantic: semantic, options: options, undeclared: undeclared)
        if sweepsByName {
            undeclared.paging = paging
        }
        switch semantic {
        case let .inactive(note):
            lines.append("\(SiftEngine.degradedModeOpening)\(note)")
        case let .unavailable(note):
            // One short line naming the tree and the help topic, never the recipe itself: a tree with no store is
            // asked of again and again, and the recipe on every answer was most of what each one said.
            lines.append("\(SiftEngine.degradedModeOpening)\(SiftEngine.whereNoStoreNote(from: note))")
            axis = .noStore
        case let .warming(note):
            lines.append("\(SiftEngine.degradedModeOpening)\(note)")
            axis = .warming
        case let .openFailed(note):
            lines.append("\(SiftEngine.degradedModeOpening)\(note)")
            axis = .openFailed
        case let .active(context):
            // Named here too, not only on the no-store path: a rejected setting did not act whether or not
            // some other probe went on to find a store, and "found via DerivedData" alone reads as the key
            // having never been seen at all.
            lines.append(WhereStoreLines.modeLine(context, answeredBy: []))
            boundaryPoint = lines.count
        }
        // Callers and overrides come only from the index store, so a query without one is not answering half
        // the question at all — and `mode: syntactic` alone leaves that to be inferred. The inference a reader
        // makes is that a short list is a small answer rather than a partial one, which is how a rename sweep
        // run in a git worktree — where there is never a store, because a worktree has no build directory of
        // its own — silently misses every site it should have found.
        //
        // Skipped for `.inactive`: that case is `--syntactic`, which turned callers/overrides off on purpose,
        // so there is nothing withheld to disclose — the notice would be announcing a refusal nobody asked
        // to be spared.
        if !semantic.isActive, !semantic.isInactive {
            let sample = declarations.prefix(Self.semanticDeclCap)
            lines.append(Self.absenceNotice(
                standIn: standIn(for: sample),
                isType: sample.contains { $0.kind.isTypeDeclaration || $0.kind == .associatedType || $0.kind == .extensionKind }
            ))
        }
        if options.includeReferences, let line = referencesLine(semantic: semantic, sweepsByName: sweepsByName, declares: !declarations.isEmpty) {
            lines.append(line)
        }
        let narrowingSlot = lines.count
        // The banner is resolved last but printed here, above the answer it qualifies — the same placement lesson refusals taught: a caveat below the content is a caveat read after the decision.
        var bannerSlot = lines.count
        var citedPaths: [String] = []
        lines.append("")

        if declarations.isEmpty {
            // A type built only through an initializer nobody declared under it is answered with where it is built,
            // never as a path that does not resolve: the other types' inits that answer listed are not what was asked.
            if let answer = try await undeclared.answer(for: query) {
                lines += paging.settle(answer.body)
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
                lines.append(contentsOf: siblingPointerLines(for: query))
                return Output(body: lines.joined(separator: "\n"), axis: axis)
            }
            // A near-miss list is still an answer whose headline is "not here", and a fuzzy candidate is not the
            // declaration that was asked for — so this one is in the class too, rather than left as the one
            // absence answer where the reader has to know the rule to apply it.
            if let absence {
                lines.insert(absence, at: bannerSlot)
            }
            lines.append("no exact match; nearest symbols:")
            for row in candidates {
                lines.append("  \(row.name) — \(row.kind.rawValue) — \(row.module) — \(row.path):\(row.line)")
            }
            lines.append(contentsOf: siblingPointerLines(for: query))
            return Output(body: lines.joined(separator: "\n"), axis: axis)
        }

        // A bare name unrelated owners each declare is answered with its declarations and the query that narrows to
        // each; a sweep asked for by name with --refs still lists everything it asked for, and so does a caller that
        // stands the answer in for a search's lines.
        if options.collapsesSeveralOwners, !options.includeReferences, let output = try await severalOwnersOutput(lines, bannerSlot: bannerSlot, axis: axis, query: query, declarations: declarations, semantic: semantic) {
            return output
        }

        let compact = declarations.count > Self.compactDeclarationThreshold
        lines.append("declarations (\(declarations.count)):")
        for row in declarations.prefix(Self.listCap) {
            citedPaths.append(row.path)
            try lines.append(row.declarationLine(qualifiedName: qualifiedName(of: row), compact: compact, condition: IfConfigLabel.label(for: row, source: fileSource)))
        }
        if declarations.count > Self.listCap {
            lines.append("  truncated: \(declarations.count - Self.listCap) more declarations")
        }
        if compact {
            lines.append("  signatures: digest \(query) for any one of these")
        }

        // Which symbols are left with no caller answer at all — the refused ones under an open store, or every callable declaration when there is no store to refuse from.
        var unanswered: [SymbolRow] = []
        var listedAbove: (SyntacticCallSite) -> Bool = { _ in false }
        var typeUseListedAbove: (SyntacticCallSite) -> Bool = { _ in false }
        var conformerBlocks: [String: ConformersOnce] = [:]
        var writtenNameChecks: [String: WrittenNameCheck] = [:]
        if case let .active(context) = semantic {
            let wrapperSites = try await WrapperAttributeSites.find(for: declarations.prefix(Self.semanticDeclCap), in: store, callSites: callSites, context: context)
            let outcome = try appendSemanticSections(for: declarations, context: context, wrapperSites: wrapperSites, options: options, into: &lines)
            axis = outcome.axis
            unanswered = outcome.refused + declarations.prefix(Self.semanticDeclCap).filter { $0.kind == .operatorKind }
            listedAbove = { site in
                outcome.listsAlready(site) { path in ((try? store.fileRow(path: path))?.mtime ?? 0) > context.buildAnchor }
            }
            typeUseListedAbove = outcome.listsTypeUse
            conformerBlocks = outcome.conformerBlocks
            writtenNameChecks = outcome.writtenNameChecks
            if !outcome.answeredBy.isEmpty, let modeIndex = lines.firstIndex(where: { $0.hasPrefix("mode: ") }) {
                lines[modeIndex] = WhereStoreLines.modeLine(context, answeredBy: outcome.answeredBy)
            }
            WhereStoreLines.appendProjectHintsIfAllowed(to: &lines, for: outcome.uncovered, owner: projectOwner, inTreeWarming: context.inTreeWarming, primaryProvenance: context.store.provenance)
            // Said once for both views. The default type section reads the same store rows the sweep does and is read
            // for the same decision, so the same two boundaries bound it; printing them twice when --refs is also on
            // would say one thing under two headings.
            if outcome.boundsReferences, let boundaryPoint {
                // Both boundaries on one line: the store holds code occurrences of what *this* build compiled, so a comment, a string literal or a consumer outside the build is not a missing occurrence — it was never a candidate.
                lines.insert(Self.referenceBoundaryLine, at: boundaryPoint)
                // bannerSlot was captured at the same index before this line went in; advance it past it so a
                // banner inserted later at bannerSlot lands below the boundary it was meant to sit beneath, not above it.
                if boundaryPoint <= bannerSlot {
                    bannerSlot += 1
                }
            }
        } else {
            unanswered = declarations.prefix(Self.semanticDeclCap).filter { isAskedOfTheStore($0.kind) || $0.kind == .operatorKind }
            // Suppressed once the mode line already says the in-tree walk was cut short: the hint's advice —
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
            ? typeUseRows(of: unanswered.filter { SyntacticTypeUsage.standsIn(for: $0.kind) } + declarations.prefix(Self.semanticDeclCap).filter { $0.kind == .extensionKind }, among: declarations)
            : typeUseRows(of: unanswered, among: declarations)
        let typeUseIDs = Set(typeUse.map(\.id))
        try await lines += SyntacticTypeUsage(store: store, callSites: callSites, expandsAtFileScope: expandsAtFileScope)
            .lines(for: typeUse, qualifiedName: qualifiedName(of:), listedAbove: typeUseListedAbove, paging: sweepsByName ? paging : nil)
        let fallbackRows = unanswered.filter { !typeUseIDs.contains($0.id) && $0.kind != .extensionKind }
        let sameNamed = SameNamedTypes(store: store)
        try await lines.append(contentsOf: SyntacticCallerFallback.lines(
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
            listsLabelCalls: options.includeReferences
        ))
        // A type of the name that declares no init of its own is built all the same, and its sites are not the initializers' above.
        try await lines += undeclared.lines(beside: declarations, for: query)
        // Every paged list is in now, so the one window they all show is known and each list's slot is filled.
        lines = paging.settle(lines)
        if sweepsByName, paging.spansPages, let line = try narrowingLine(declarations, query: query) {
            lines.insert(line, at: narrowingSlot)
            bannerSlot += 1
        }

        try appendTypeRelations(of: declarations, conformerBlocks: conformerBlocks, writtenNameChecks: writtenNameChecks, citing: &citedPaths, into: &lines, qualifiedName: qualifiedName(of:))
        // Every count in this answer is read out of a repository-wide lookup: `declarations (N)` through
        // `resolveDeclarations` → `symbols(named:)`, `extensions of X (N)` through `ExtensionPaths.extensions(ofTypeNamed:in:)`,
        // and `conformers of X (N, …)` through `conformers(of:)`. A row lost with the tail of a truncated file
        // is missing from its number *and* from the cited paths, so the banner below goes quiet about the only
        // file that could explain it. One note for all three, because three would be the noise a single one
        // avoids — and counted rather than listed, because that banner is often present here and a wider list
        // printed beside it nests one inside the other; see `ParseErrorNotice.floorNote(about:)` for the rule.
        //
        // Inserted before the banner so that the banner ends up above it: both go in at `bannerSlot`, and the
        // later insert takes the line. `bannerSlot` itself was advanced past the reference boundaries above, so
        // both land below them rather than above.
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

    private func qualifiedName(of row: SymbolRow) throws -> String {
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
        let sample = declarations.prefix(Self.semanticDeclCap)
        return sample.contains { isAskedOfTheStore($0.kind) } && standIn(for: sample) != .nothing
    }

    /// The line a sweep by name of a bare name several unrelated owners declare carries once it runs past one page: a written name cannot tell the owners' sites apart, so the query that narrows to one is named; `nil` where the name has one owner.
    private func narrowingLine(_ declarations: [SymbolRow], query: String) throws -> String? {
        guard let owners = try unrelatedOwners(of: declarations, query: query), let first = declarations.first(where: { owners[$0.id] != nil }), let owner = owners[first.id] else { return nil }
        let narrowing = try narrowingQuery(to: owner, query: query, owners: owners)
        return "references: \(Set(owners.values).count) unrelated owners declare \"\(query)\", and a match by written name cannot tell their sites apart, so this sweep pages through every owner's — "
            + (narrowing.hasPrefix("where ") ? "narrow it to one owner's, as `\(narrowing) --refs`" : "narrow it to one owner by qualifying the name with its type")
    }

    /// The line a `--refs` answer carries about where its references come from, or `nil` where the store answers them.
    ///
    /// References come only from the index store, so asking for them without it must say so — a sweep that silently returns nothing reads as "nothing to change", which is the one way this flag can do harm. What to do about it depends on why the store is not in use, and the line must agree with the header above it: a store still loading is a wait, never a grep or a build, and one that failed to open is not fixed by building.
    ///
    /// A name the tree declares nowhere, with no store at all, gets no line: a store would not turn that miss into an answer, and blaming its absence sends the reader to build for nothing.
    private func referencesLine(semantic: SemanticInput, sweepsByName: Bool, declares: Bool) -> String? {
        if sweepsByName {
            return WhereStoreLines.syntacticSweepLine
        }
        if case .unavailable = semantic, !declares {
            return nil
        }
        return switch semantic {
        case .active:
            nil
        case .inactive:
            // Whether a store exists is not known here — `--syntactic` never probes for one — so the advice
            // cannot say "build": where a store is already on disk, dropping the flag is the whole remedy.
            "references: UNAVAILABLE — they come from the index store, which this query is not using; grep instead, or drop --syntactic (a query without it says how to build a store if there is none yet)"
        case .unavailable:
            // `.inactive` is `--syntactic`, given by the caller; `.unavailable` is a store that was
            // never found at all, and telling that caller to "drop --syntactic" names a flag they
            // never passed. The mode line above already carries the real remedy — this points at it
            // rather than repeating (and risking drifting from) its own copy of the advice.
            "references: UNAVAILABLE — there is no index store for this tree yet; grep instead, or see the mode line above for how to build one"
        case .warming:
            "references: UNAVAILABLE until the index store finishes loading — ask again shortly; no build or grep will get them sooner"
        case .openFailed:
            "references: UNAVAILABLE — the index store was found but failed to open (the mode line says why); grep for them instead"
        }
    }

    /// What stands in for the store's callers under the absence notice, which is what an empty list of it means.
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

    /// Resolves relations for the first `semanticDeclCap` declarations, rendering only what it actually found.
    ///
    /// Emptiness is summarised, never itemised: a declaration with no recorded callers contributes one name to a single trailing line instead of its own three-line block, and refusals group by file rather than repeating for every declaration in it. Density is the product — five "none recorded in the store" blocks cost the reader more than the answer is worth.
    private func appendSemanticSections(
        for declarations: [SymbolRow],
        context primary: SemanticContext,
        wrapperSites: WrapperAttributeSites,
        options: WhereOptions,
        into lines: inout [String]
    ) throws -> SemanticOutcome {
        // The same anchor the declaring-file refusal uses, applied to the *cited* files: a store keeps every
        // occurrence the last build recorded, including ones in files the tree no longer has (Docs/Design.md §2).
        // One judge per store, since each store's own build is what its occurrences are judged against.
        var judges = [primary.store.cache.directory.path: OccurrenceFreshness(store: store, buildAnchor: primary.buildAnchor, relativePath: primary.relativePath)]
        var answeredBy: [String] = []
        var uncovered: [SymbolRow] = []
        let targets = declarations.prefix(Self.semanticDeclCap)
        let names = try DeclarationShortNames(declarations, qualifiedName: qualifiedName(of:))
        var refusals: [SemanticRefusal] = []
        var refusedRows: [SymbolRow] = []
        var listedSites: [SyntacticCallSite] = []
        var recordedCalls: Set<String> = []
        var listedTypeUses: Set<String> = []
        // A protocol's conformers, one block per name, rendered where the scan by written name would have put its own.
        var conformerBlocks: [String: ConformersOnce] = [:]
        var writtenNameChecks: [String: WrittenNameCheck] = [:]
        var sections: [String] = []
        var withoutCallers: [String] = []
        var implementersWithoutCallers: [String] = []
        let verdicts = try ZeroUseVerdict(store: store, context: primary, projectDirectories: projectDirectories)
        var callerEligible = 0
        // A property or subscript is never called — the store records its reads and writes on its own USR and the call on an accessor's — so it is asked for those instead, and its empty case says that is what was looked for: "no callers" said of one reads as dead code, which is how a live constant gets deleted.
        var withoutUses: [String] = []
        var implementersWithoutUses: [String] = []
        var useEligible = 0
        // Whether a property — not only a subscript — was asked for its reads and writes: what a synthesized conformance reads is never recorded, and that is said beside the answer.
        var askedProperty = false
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
            let mtime = file?.mtime ?? 0
            // The first store that resolves the declaration owns it — the primary, then each in-tree store in path
            // order — and everything below is read from that store alone, against its own build.
            guard let owned = primary.owner(of: row) else {
                refusals.append(SemanticRefusal.unowned(row, symbol: qualified, imports: file?.imports ?? [], modified: mtime > primary.buildAnchor, context: primary, source: fileSource))
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
            if mtime > context.buildAnchor {
                let rebuild = SemanticRefusal.Rebuild(provenance: context.store.provenance, imports: file?.imports ?? [])
                refusals.append(SemanticRefusal(path: row.path, reason: .modifiedSinceBuild, symbol: qualified, kind: row.kind, rebuild: rebuild))
                refusedRows.append(row)
                continue
            }
            let judgeKey = context.store.cache.directory.path
            let occurrences = judges[judgeKey] ?? OccurrenceFreshness(store: store, buildAnchor: context.buildAnchor, relativePath: context.relativePath)
            judges[judgeKey] = occurrences
            // A type use listed on a line of its own, at the column its name is written, which a refused declaration of the name's stand-in lists no second time — only while its file is unchanged since the build.
            let listTypeUse: (SemanticStore.Hit) -> Void = { hit in
                if row.kind.isTypeDeclaration || row.kind == .typealiasKind, occurrences.state(of: hit.path).isLive {
                    listedTypeUses.insert("\(context.relativePath(hit.path)):\(hit.line):\(hit.column)")
                }
            }
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
                    sections.append(contentsOf: hitSection(heading.title, hits: callers, noun: "call site", qualifier: heading.qualifier, foldByCaller: true, context: context, occurrences: occurrences) { hit in
                        ownLines.insert("\(hit.path):\(hit.line)")
                    })
                    recordedCalls.formUnion(callers.filter { ownLines.contains("\($0.path):\($0.line)") }.map { "\(context.relativePath($0.path)):\($0.line):\($0.column)" })
                }
                sections.append(contentsOf: wrapperSites.lines(for: row, owner: names.name(of: row), cap: Self.callSiteCap, judgedBy: occurrences, under: context.repoRoot))
                listedSites += wrapperSites.sites(for: row, cap: Self.callSiteCap)
            }
            if row.kind.isReadAndWritten {
                useEligible += 1
                askedProperty = askedProperty || row.kind == .variable
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
            if row.kind.isTypeDeclaration {
                usageEligible += 1
                let references = context.store.references(ofUSR: usr, sources: &sourceLines)
                typeReferences = references
                // A use written through a typealias is recorded against the alias, so references to the type's own USR
                // cannot see it — and `1 production · 0 tests` said of a type three tests use through an alias, the
                // one line being the alias declaration itself, is this section's own defect wearing a number. The
                // aliases are discovered from the references themselves, where the store records the aliasing, and
                // folded in before anything is counted or denied.
                let fold = try aliasFold(referencedAt: references, named: row.name, context: context, sources: &sourceLines)
                let spans = try ownSpans(of: row, extendedAt: context.store.extensionSites(ofUSR: usr), relativePath: context.relativePath)
                let own = Self.excludingSites(references + fold.hits, inside: spans.spans, relativePath: context.relativePath)
                // A `typealias Crate = Gizmo` names the type without using it, the same as an `extension Gizmo`
                // header, and is taken out on the same ground — whatever uses the alias is a use and was folded in
                // just above. Counted, it made a type nothing at all uses read as `2 production`.
                let usage = Self.excludingSites(own.sites, inside: fold.declarationSpans, relativePath: context.relativePath)
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
                        sweepFollows: options.includeReferences,
                        aliasFoldCapped: fold.reachedCap,
                        conformanceLines: conformance?.clauseLines ?? [],
                        offset: options.offset,
                        context: context,
                        occurrences: occurrences,
                        shown: listTypeUse
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
                let references = context.store.references(ofUSR: usr, sources: &sourceLines)
                typeReferences = references
                let fold = try aliasFold(referencedAt: references, named: row.name, excluding: usr, context: context, sources: &sourceLines)
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
                        excludedLines: 0,
                        aliasDeclarationLines: usage.excluded,
                        sweepFollows: options.includeReferences,
                        aliasFoldCapped: fold.reachedCap,
                        isAlias: true,
                        offset: options.offset,
                        context: context,
                        occurrences: occurrences,
                        shown: listTypeUse
                    ))
                }
            }
            if options.includeReferences {
                let references = typeReferences ?? context.store.references(ofUSR: usr, sources: &sourceLines)
                // A type's (or a typealias's) emptiness has already been said by its usage line, in the noun that
                // decision is made in; repeating it here would read as a second finding rather than the same one.
                if !row.kind.isTypeDeclaration, row.kind != .typealiasKind {
                    referenceEligible += 1
                    if references.isEmpty {
                        withoutReferences.append(qualified)
                    }
                }
                if !references.isEmpty {
                    sections.append(contentsOf: referenceSection(for: qualified, hits: references, offset: options.offset, context: context, occurrences: occurrences, shown: listTypeUse))
                }
            }
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
        lines.append(contentsOf: sections)
        let callerSummary = [verdicts.summary(withoutCallers, eligible: callerEligible, noun: "callers", preposition: "of")].compactMap(\.self) + implementersWithoutCallers
        lines += callerSummary.isEmpty ? [] : [""] + callerSummary
        // What the store cannot record is said beside what it did, and under the empty case above all: "no reads or
        // writes" of a field only a Codable conformance reads is how a saved format silently changes.
        let useSummary = [verdicts.summary(withoutUses, eligible: useEligible, noun: "reads or writes", preposition: "of")].compactMap(\.self) + implementersWithoutUses
        if !useSummary.isEmpty || askedProperty {
            lines.append("")
            lines.append(contentsOf: useSummary + [
                askedProperty ? Self.propertyUseBoundary : nil,
                listedMovedObserver ? Self.movedObserverBoundary : nil,
            ].compactMap(\.self))
        }
        let caseSummary = verdicts.summary(withoutCaseUses, eligible: caseEligible, noun: "uses", preposition: "of")
        if caseSummary != nil || caseEligible > 0 {
            lines.append("")
            lines.append(contentsOf: [caseSummary].compactMap(\.self) + implementersWithoutCaseUses + [caseEligible > 0 ? Self.caseUseBoundary : nil].compactMap(\.self))
        }
        // A type that nothing uses is the one answer this section exists to make sayable out loud, so it is said in
        // the same words the sweep view uses for an empty result — and a type whose every recorded reference sits
        // inside its own declaration or its extensions in this module is a different finding, not the same one:
        // references exist, and none of them is a use.
        if let summary = verdicts.summary(withoutUsage, eligible: usageEligible, noun: "references", preposition: "to") {
            lines.append("")
            lines.append(summary + " — check comments and strings with grep")
        }
        if let summary = verdicts.summary(usedOnlyByItself, eligible: usageEligible, noun: "uses", preposition: "of") {
            lines.append("")
            // Under `--refs` the sweep lists exactly the lines this sentence is disowning, and a reader not told so
            // reads the two as contradicting each other rather than as one finding and its evidence. It is *above*
            // this sentence: the sections are appended before every summary line, so a sentence pointing downward
            // points at the extensions block and leaves the listing it owns unclaimed.
            let evidence = options.includeReferences ? " — the references listed above are those lines" : ""
            lines.append(summary + " — every reference recorded falls inside its own declaration or its extensions in this module, which is the type spelling its own name\(evidence); check comments and strings with grep")
        }
        // A third finding, not either of the two above: references exist, and every one of them is the type being
        // given another name rather than being used. It is worth its own sentence because the deletion it clears is
        // bigger than the type — the aliases go with it — and because "2 production" was what this used to say.
        if let summary = verdicts.summary(namedOnlyByItsAliases, eligible: usageEligible, noun: "uses", preposition: "of") {
            lines.append("")
            let evidence = options.includeReferences ? " — the references listed above are those lines" : ""
            let aliasesGo = namedOnlyByItsAliasesCapped ? Self.foldStoppedShort : "and nothing uses those aliases either, so they go with it"
            lines.append(summary + " — every reference recorded is the type declaring itself or a typealias declaration naming it, which is another name for the type rather than use of it, \(aliasesGo)\(evidence); check comments and strings with grep")
        }
        if let summary = verdicts.summary(withoutReferences, eligible: referenceEligible, noun: "references", preposition: "to") {
            lines.append("")
            lines.append(summary + " — check comments and strings with grep")
        }
        // The alias's own three findings, worded exactly like the type's above, with one clause added throughout:
        // which name this counted. Without it, "no references to Nickname" reads as "nothing uses Gizmo either",
        // which is the type's answer given under the alias's name.
        let aliasCounts = " — counts the alias's own name, and any typealias of it, not the type it names, which may still be used directly, under its own name, without it"
        if let summary = verdicts.summary(withoutAliasUsage, eligible: aliasUsageEligible, noun: "references", preposition: "to") {
            lines.append("")
            lines.append(summary + aliasCounts + "; check comments and strings with grep")
        }
        if let summary = verdicts.summary(aliasNamedOnlyByItsAliases, eligible: aliasUsageEligible, noun: "uses", preposition: "of") {
            lines.append("")
            let evidence = options.includeReferences ? " — the references listed above are those lines" : ""
            let aliasesGo = aliasNamedOnlyByItsAliasesCapped ? Self.foldStoppedShort : "and nothing uses those either, so they go with it"
            lines.append(summary + " — every reference recorded is another typealias naming it, which is another name for it rather than use of it, \(aliasesGo)\(evidence)" + aliasCounts + "; check comments and strings with grep")
        }
        if declarations.count > Self.semanticDeclCap {
            lines.append("")
            lines.append("(semantic relations resolved for the first \(Self.semanticDeclCap) declarations only)")
        }
        // A declaration no open store resolves, while an in-tree store is still loading, may be that store's to answer: said as warming, a wait, rather than as unresolved, a build — but never where a refusal here is already the stronger, unconditional fact a loading store could never change.
        let waitsOnInTree = primary.inTreeWarming && !uncovered.isEmpty && !refusals.contains { $0.reason == .modifiedSinceBuild }
        return try SemanticOutcome(
            axis: waitsOnInTree ? .warming : .of(refusals: refusals, occurrences: Array(judges.values), testFilesWithoutUnit: primary.testFileCoverage(in: store).partialCount),
            refused: refusedRows,
            boundsReferences: usageEligible > 0 || aliasUsageEligible > 0 || referenceEligible > 0,
            answeredBy: answeredBy,
            uncovered: uncovered,
            listedSites: listedSites,
            recordedCalls: recordedCalls,
            listedTypeUses: listedTypeUses,
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
        let displayed = foldByCaller ? Self.foldedByCaller(ordered) : ordered.map { DisplayRow(entry: $0.entry, state: $0.state, sites: 1) }
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

    /// One row of a rendered block after folding: the row to print, and how many of the input rows it stands for — always 1 unfolded.
    private struct DisplayRow {
        let entry: ListedRow
        let state: OccurrenceState
        let sites: Int
    }

    /// Groups rows by calling function — name and declaring file — keeping the first call site (by line) of each and counting the rest, so a caller that calls the subject nine times prints once.
    ///
    /// Grouping is by identity, not adjacency: the store's own ordering is not relied on to keep one caller's sites together.
    private static func foldedByCaller(
        _ judged: [(entry: ListedRow, state: OccurrenceState)]
    ) -> [DisplayRow] {
        var order: [String] = []
        var groups: [String: [(entry: ListedRow, state: OccurrenceState)]] = [:]
        for row in judged {
            let key = "\(row.entry.hit.name)\u{0}\(row.entry.hit.path)"
            if groups[key] == nil {
                order.append(key)
            }
            groups[key, default: []].append(row)
        }
        return order.map { key in
            let group = groups[key] ?? []
            let first = group.min { $0.entry.hit.line < $1.entry.hit.line } ?? group[0]
            // The first site's "referenced, not called" is the caller's only where none of its sites calls the subject.
            var entry = first.entry
            let uncalled = group.count { $0.entry.hit.uncalled }
            if uncalled > 0, uncalled < group.count {
                entry.access = "called and referenced"
            }
            return DisplayRow(entry: entry, state: first.state, sites: group.count)
        }
    }

    /// The heading clauses that disown part of what the section is nevertheless listing — never omitted when they apply, since a count that silently includes dead rows is the defect this whole path exists to end.
    ///
    /// Counted in **files**, whatever the section lists, and worded identically in both: the header's own count is in files, and two sections disowning in different units invite the reader to compare numbers that were never the same measurement. One `states` entry per distinct file is the caller's job.
    static func driftDetails(states: [OccurrenceState]) -> [String] {
        var details: [String] = []
        let deleted = states.count { $0 == .deleted }
        let modified = states.count { $0 == .modifiedSinceBuild }
        if deleted > 0 {
            details.append("\(deleted) file\(deleted == 1 ? "" : "s") deleted since last build")
        }
        if modified > 0 {
            details.append("\(modified) file\(modified == 1 ? "" : "s") changed since last build")
        }
        return details
    }

    /// What a property's reads and writes cannot show, stated beside them — not only on the empty case, since a short list read as complete does the same harm: a field only a `Codable` conformance reads, listed with its one write, reads as write-only.
    static var propertyUseBoundary: String {
        "reads and writes: written code only — the store records none made by a synthesized conformance (Equatable, Hashable, Codable) or by name at runtime, so a short or empty list is not proof a property is unused"
    }

    /// What a use inside an observer a macro moved cannot show — where it is written — stated wherever one is listed: its row sits on the macro's line, and a reference sweep drops it, since there is nothing to rename there.
    static var movedObserverBoundary: String {
        "observers: a macro that moves a property into generated storage, as @Observable does, moves its didSet and willSet with it — the store records their uses at the macro's line, never where they are written, so a reference sweep lists none of their lines"
    }

    /// What an enum case's uses cannot show, stated beside them for the same reason.
    static var caseUseBoundary: String {
        "uses: written code only — the store records none made by a synthesized conformance (CaseIterable, a raw value's init(rawValue:), Codable) or by name at runtime, so a short or empty list is not proof a case is unused"
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
