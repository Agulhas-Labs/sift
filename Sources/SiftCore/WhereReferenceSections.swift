//
// Copyright © Agulhas Labs
//

/// How a `where` answer reports references: the grouping both views count in, the compact usage verdict a type's answer opens with, and the paged sweep `--refs` prints.
extension WhereRenderer {
    /// References grouped one line per file, `path (count): line, line, …`, paged by `offset` in files.
    ///
    /// Grouped rather than listed flat because the caller is sweeping: a rename or delete is done file by file, and a flat list of 103 hits would spend 63 of them past the list cap. Counts are of *distinct lines*, matching what the lines actually list, so the header and the listing always reconcile; two occurrences on one line are one place to edit.
    ///
    /// The file list pages on the same offset cursor digest uses, so a sweep bigger than one page stays in-tool. No file's lines are capped: a line left to a grep is a site the rename misses, the one failure mode this section exists to prevent.
    ///
    /// A file the tree no longer has keeps its line list — a delete sweep reads this section precisely to tell a reference the unit itself orphaned from one that was already orphaned — but it is labelled, and within a page it sorts after the surviving files so the actionable ones are read first.
    ///
    /// **The cursor pages the alphabetical list, never the display order.** Liveness changes *as the sweep runs*: page one's files get edited, drop out of the live group, and a cursor keyed to that order then skips as many files as moved — silently, in the multi-page sweep this section exists for. A page's contents must depend only on the offset and the file names, so live-first ordering is applied to the page after it is cut.
    ///
    /// **A function's references are folded against its callers** (Docs/Design.md §2, *The callers/references fold*): the store records a call and a function handed on unapplied alike as references, so `callers of` above has already listed most of these lines. `callSitesAbove` holds each line it listed on a row of its own, `path:line`; those are counted in the heading, `K of them the call sites above`, and not listed again, and the files and the cursor are the rest's. A line `callers of` only counted — a caller's later sites, a caller past its cap — is listed here, so every line is listed once, above or here, on every page.
    func referenceSection(
        for qualified: String,
        hits: [SemanticStore.Hit],
        offset: Int,
        context: SemanticContext,
        occurrences: OccurrenceFreshness,
        paging: SyntacticSweepPaging? = nil,
        callSitesAbove: Set<String> = [],
        conformanceLines: Set<String> = [],
        generatedMentions: Int = 0,
        shown: (SemanticStore.Hit) -> Void = { _ in }
    ) -> [String] {
        let all = ReferencedFiles(hits: hits, context: context, occurrences: occurrences)
        let afterCalls = hits.filter { !callSitesAbove.contains("\(context.relativePath($0.path)):\($0.line)") }
        let afterCallsGrouped = afterCalls.count == hits.count ? all : ReferencedFiles(hits: afterCalls, context: context, occurrences: occurrences)
        // A protocol's conformance lines are listed once, in its conformers block, and counted here rather than listed twice; `--files` still names their files, recorded from `all` below.
        let rest = conformanceLines.isEmpty ? afterCalls : afterCalls.filter { !conformanceLines.contains("\(context.relativePath($0.path)):\($0.line)") }
        let grouped = rest.count == afterCalls.count ? afterCallsGrouped : ReferencedFiles(hits: rest, context: context, occurrences: occurrences)
        let files = grouped.paths
        var details = ["\(all.sites) in \(all.paths.count) file\(all.paths.count == 1 ? "" : "s")"]
        if all.sites > afterCallsGrouped.sites {
            details.append("\(all.sites - afterCallsGrouped.sites) of them the call sites above")
        }
        let conformances = afterCallsGrouped.sites - grouped.sites
        if conformances > 0 {
            details.append("\(conformances) of them the conformance\(conformances == 1 ? "" : "s") listed below")
        }
        // A rename sweeps the wrapper's `$flag` and `_flag` spellings too, so the heading names the ones its lines hold.
        if !all.siblings.isEmpty {
            details.append("including \(all.siblings.joined(separator: " and "))")
        }
        details.append(contentsOf: Self.driftDetails(states: all.states))
        // The store records the storage and accessors a macro generates as references written nowhere, so they are not listed, and the count says how many were left out.
        if generatedMentions > 0 {
            details.append("\(generatedMentions) more line\(generatedMentions == 1 ? "" : "s") a macro generated, not listed")
        }
        var block = ["", "references to \(qualified) (\(details.joined(separator: ", "))):"]
        // Every file and line, the call sites above too, before the page is cut.
        if let filesCollector {
            for path in all.paths {
                filesCollector.recordCode(path: path, lines: all.lines(in: path), state: all.state(of: path))
            }
            filesCollector.recordReferenceDetails(siblings: all.siblings, generatedLines: generatedMentions, heading: block[1])
        }
        let skipped = min(max(0, offset), files.count)
        // Registered with the answer's pager on every page, so a list past its end elsewhere knows this one continues.
        let pastEnd = paging?.pastEnd(ofOutsideList: files.count)
        if PastEndLine.applies(offset: offset, count: files.count) {
            block.append("  " + (pastEnd ?? PastEndLine.text(offset: offset, count: files.count, noun: "files")))
        } else if skipped > 0 {
            block.append("  (…\(skipped) file\(skipped == 1 ? "" : "s") skipped)")
        }
        // Cut the page alphabetically — an order-invariant cursor — then order only what it holds.
        let cut = Array(files.dropFirst(skipped).prefix(Self.listCap))
        let page = grouped.liveFirst(cut)
        // A sweep is the rename view: a line left to a grep is a site the rename misses, so no file's lines are capped.
        let listed = grouped.fileLines(page, listsEveryLine: true)
        grouped.handOn(rest, listedIn: page, relativePath: context.relativePath, listsEveryLine: true, to: shown)
        block.append(contentsOf: listed.rows)
        let hiddenFiles = max(0, files.count - skipped - page.count)
        if hiddenFiles > 0 {
            block.append("  truncated: \(hiddenFiles) more file\(hiddenFiles == 1 ? "" : "s") — pass offset \(skipped + page.count) to continue")
        }
        return block
    }

    /// Uses a plain answer on a type lists under the verdict, beyond a protocol's conformances, before it hands the listing to `--refs`.
    static let listedInPlaceCap = 8

    /// A type's usage: the verdict a deletion decision is made from, then the files that back it.
    ///
    /// Compact rather than the sweep's full paged listing, because this one is on *every* answer about a type. The question it settles is not "which lines do I edit" but "is anything using this, and is any of it production" — a count. In a plain answer the count stands alone, ending `— where --refs <pointing> lists them`, since a question about where a type is did not ask for its uses; under `standsInForSearch` the lines follow so the count can be checked rather than believed, for a caller standing the answer in for a search's lines. `--refs` stays the rename view, and the truncation marker points there rather than at a cursor this section does not carry.
    ///
    /// The split is read from the file's own imports (``TestFileRecognition/isTestFile(imports:)``), the signal the rest of the index already uses, never from where the file sits: a path prefix would be this repo's layout asserted about somebody else's. A path the index has no row for is counted apart rather than guessed into either side, and named for which of the two it is: a file the deletion ledger saw leave the tree, or one the index never held, such as a build-generated source. **The verdict names that rule beside the number**, because the rule has an edge a reader has to know about: a helper written inside a test target that imports neither framework — a fixture builder, a deadline — counts as production, and a deletion is decided on that number.
    ///
    /// A use written through a typealias is recorded against the alias, so the verdict says how many of its lines were reached that way and which alias reached them — a fold that cannot be read is a number that is merely larger.
    ///
    /// **A typealias declaration of the type is not a use of it**, so those lines arrive already taken out of `hits`, counted apart in their own parameter and said in the verdict rather than dropped in silence. The reasoning is ``WhereRenderer/AliasFold/declarationSpans``'.
    func usageSection(
        for qualified: String,
        hits: [SemanticStore.Hit],
        excludedLines: Int = 0,
        otherModuleExtensions: Int = 0,
        otherModuleExtensionsGuessed: Set<GuessedModuleNotice.Reason> = [],
        aliasDeclarationLines: Int = 0,
        options: WhereOptions,
        aliasFoldCapped: Bool = false,
        conformanceLines: Set<String> = [],
        isAlias: Bool = false,
        pointing: String,
        context: SemanticContext,
        occurrences: OccurrenceFreshness,
        targetsNotBuilt: [String] = [],
        shown: (SemanticStore.Hit, _ listed: Bool) -> Void = { _, _ in }
    ) throws -> [String] {
        let sweepFollows = options.includeReferences
        let offset = options.offset
        let grouped = ReferencedFiles(hits: hits, context: context, occurrences: occurrences)
        let files = grouped.paths
        let deleted = try Set(store.deletionLedger().entries.keys)
        let split = try countingUnbuiltTests(in: Self.usageSplit(
            sitesByPath: grouped.paths.map { ($0, grouped.lines(in: $0).count) },
            deleted: deleted
        ) { try store.fileRow(path: $0)?.imports }, context: context, targetsNotBuilt: targetsNotBuilt)
        var verdict = "used by \(qualified): \(grouped.sites) reference\(grouped.sites == 1 ? "" : "s") in \(files.count) file\(files.count == 1 ? "" : "s")"
        // A protocol's conformance lines are listed once, in its conformers block below, and counted here rather than listed twice, under `--refs` too.
        let listedHits = conformanceLines.isEmpty ? hits : hits.filter { !conformanceLines.contains("\(context.relativePath($0.path)):\($0.line)") }
        let rest = listedHits.count == hits.count ? grouped : ReferencedFiles(hits: listedHits, context: context, occurrences: occurrences)
        let conformances = grouped.sites - rest.sites
        // Few enough uses beyond the conformances are listed in place, so a reader is not sent to --refs for a handful of lines.
        let pointer = sweepFollows || options.standsInForSearch || rest.sites <= WhereRenderer.listedInPlaceCap ? nil : pointing
        if conformances > 0 {
            verdict += ", \(conformances) of them the conformance\(conformances == 1 ? "" : "s") listed below"
        }
        // What decides the split, the XCTest or Testing import and never the path, is said by the standing caveats (``StandingCaveats``) on an empty verdict, not here.
        verdict += " — " + split.tally.joined(separator: " · ")
        var clauses = Self.driftDetails(states: grouped.states)
        // A folded line is named for what it is written as, because the reader who goes to check it will not find
        // this type's name there: the alias is what is spelled at the site, and the store recorded the use on it.
        if grouped.aliased.lines > 0 {
            let spellings = Self.namedSpellings(grouped.aliased.spellings)
            let naming = grouped.aliased.spellings.count == 1 ? "a typealias naming it" : "typealiases naming it"
            var clause = "\(grouped.aliased.lines) written as \(spellings), \(naming) — recorded against the alias, folded in here"
            // Under `--refs` the sweep below lists this type's own spellings, which a rename edits; an alias's use
            // sites spell nothing a rename of this type touches, so they are not there and the verdict says where.
            if sweepFollows {
                let pointer = grouped.aliased.spellings.count == 1
                    ? "`where \(spellings) --refs` lists those lines"
                    : "a `--refs` sweep of each alias lists them"
                clause += ", and not in the sweep below — \(pointer)"
            }
            clauses.append(clause)
        }
        if aliasFoldCapped {
            clauses.append("more typealiases than the \(Self.typealiasFoldCap) this follows, so the count is a lower bound")
        }
        // Counted, an alias declaration made a type nothing whatever uses read as `2 production` — the deletion this
        // section exists to unblock, blocked by the aliases of the thing being deleted. Excluded, it is still said,
        // because an alias is a line the deletion has to edit even though it is not a use.
        if aliasDeclarationLines > 0 {
            clauses.append("\(aliasDeclarationLines) more line\(aliasDeclarationLines == 1 ? "" : "s") declaring a typealias of it, which is another name for the type rather than use of it")
        }
        // Never dropped in silence: a count that quietly excluded sites is the same defect as a count that never existed.
        if excludedLines > 0 {
            clauses.append("\(excludedLines) more line\(excludedLines == 1 ? "" : "s") inside its own declaration or its extensions in this module")
        }
        // The other half of the same rule, said beside it: an extension in another module is that module building
        // on the type, so it breaks when the type goes and is counted — and a reader who sees its header in the
        // listing needs telling why it is not "its own".
        if otherModuleExtensions > 0 {
            let guessedNote = GuessedModuleNotice.Reason.countNote(for: otherModuleExtensionsGuessed)
            clauses.append(otherModuleExtensions == 1
                ? "1 extension in another module counted as use — deleting the type breaks that module\(guessedNote)"
                : "\(otherModuleExtensions) extensions in other modules counted as uses — deleting the type breaks those modules\(guessedNote)")
        }
        // The question `where <alias>` answers is the alias's own deletion unit — is anything still spelling this
        // name, or a name that resolves to it — never the type it names, which can go on being used directly under
        // its own name after the alias is gone. Said of the type, "used by" would make a used-but-not-through-this-
        // alias type look as though the alias is what keeps it alive, which is the reading this clause exists to
        // close off. It names the aliases of the alias too, because the count folds them in: a reader told only
        // "its own name" greps for that name, finds fewer lines than the number, and has to guess which is wrong.
        if isAlias {
            clauses.append("counts \(qualified)'s own name, and any typealias of it, not the type it names — that type may still be used directly, under its own name, without this alias")
        }
        if !clauses.isEmpty {
            verdict += "; " + clauses.joined(separator: "; ")
        }
        var block = ["", verdict + (sweepFollows ? "" : pointer.map { " — where --refs \($0) lists them" } ?? "")]
        // Under `--refs` the verdict stands alone and the sweep's own listing, the next section, carries the lines.
        // The two sets are deliberately not the same — the sweep lists every reference, the type's own declaration
        // and extensions included, where usage lists only the ones that are use — and listing a subset directly
        // above the superset it came from reads as the answer contradicting itself. The verdict already says how
        // many lines the difference is, in the clause that names them.
        guard !sweepFollows else { return block }
        // This listing has no cursor of its own — the truncation marker below points at --refs, the paged
        // sweep, rather than at a page this section could serve — so an offset sent without --refs is served
        // anyway, named as unused, the same as digest's single-page neighbours block.
        if offset > 0 {
            block.append("(offset \(offset) unused — this section pages under --refs, not here)")
        }
        guard pointer == nil else {
            // Every use is handed on though none is listed, as counted, so a refused declaration's scan by name still leaves out the lines this one resolved and says it counted them.
            listedHits.forEach { shown($0, false) }
            return block
        }
        let page = rest.liveFirst(Array(rest.paths.prefix(Self.listCap)))
        let listed = rest.fileLines(page, namingAliases: true)
        rest.handOn(listedHits, listedIn: page, relativePath: context.relativePath) { shown($0, true) }
        block.append(contentsOf: listed.rows)
        let hiddenFiles = rest.paths.count - page.count
        if hiddenFiles > 0 {
            block.append("  truncated: \(hiddenFiles) more file\(hiddenFiles == 1 ? "" : "s") — --refs lists them all, paged")
        }
        if listed.hiddenLines > 0 {
            block.append("  note: \(listed.hiddenLines) line\(listed.hiddenLines == 1 ? "" : "s") past the per-file cap in the files above — grep those files before sweeping")
        }
        return block
    }

    /// How many of a type's use sites are written in test files, how many in production, and how many in paths the index has no row for, counted in the same distinct lines the verdict counts.
    ///
    /// The closure answers a repo-relative path's imports, `nil` for a path the index has no row for; such a path is `deleted` when the deletion ledger recorded it leaving the tree, and never held otherwise.
    static func usageSplit(
        sitesByPath: [(path: String, sites: Int)],
        deleted: Set<String>,
        importsOf: (String) throws -> [String]?
    ) rethrows -> UsageSplit {
        var split = UsageSplit()
        for (path, sites) in sitesByPath {
            guard let imports = try importsOf(path) else {
                if deleted.contains(path) {
                    split.deleted += sites
                } else {
                    split.neverHeld += sites
                }
                continue
            }
            if TestFileRecognition.isTestFile(imports: imports) {
                split.tests += sites
            } else {
                split.production += sites
            }
        }
        return split
    }

    /// `split` with the test files no store holds a unit for, and the answer's `targetsNotBuilt`, recorded on it, so its tally does not state `0 tests` of code the store never indexed, nor a production count as whole.
    func countingUnbuiltTests(in split: UsageSplit, context: SemanticContext, targetsNotBuilt: [String]) throws -> UsageSplit {
        var marked = split
        marked.targetsNotBuilt = targetsNotBuilt
        defer { filesCollector?.recordLowerBound(marked.lowerBoundReasons) }
        let coverage = try context.testFileCoverage(in: store)
        guard coverage.withoutUnit > 0 else { return marked }
        marked.unbuiltTestBuild = coverage.build
        if coverage.neverBuilt {
            marked.unbuiltTestFiles = coverage.withoutUnit
        } else {
            // The classification `affected` reads: a file the last build skipped is told apart from one no build would add.
            let classified = try context.testFilesWithoutUnit(in: store, projectDirectories: projectDirectories)
            marked.unbuiltTestFiles = classified.unbuilt.count
            marked.outsideTestFiles = classified.outsideTargets.count
        }
        return marked
    }

    /// Typealiases followed out from one type's references before the fold stops — a chain deeper than this, or a type with more aliases than this, is answered as a lower bound rather than followed further.
    static var typealiasFoldCap: Int {
        16
    }

    /// What replaces "nothing uses those either, so they go with it" in a verdict whose fold stopped at ``typealiasFoldCap``.
    ///
    /// Under the cap that clause is a finding: every alias was followed, none of them is referenced, and they are deleted along with the thing they name. At the cap it is a guess — the chain has links this never looked at, and one of those may hold the use that stops the deletion — so the sentence stops short of the claim and says what it did not read. Both verdicts that make the claim, a type's and an alias's, replace it with this.
    static var foldStoppedShort: String {
        "and nothing uses the ones this followed either, though the fold stopped at \(typealiasFoldCap) typealiases, so an alias past that may still be used"
    }

    /// Typealias spellings a usage answer names one by one before the rest are only counted.
    ///
    /// The list is printed twice — once in the verdict clause, once in the per-file row — so sixteen qualified names is about 600 characters of an answer whose whole point is to be a line. Three names say what kind of thing reached the type, which is all a reader does with them before going to the lines themselves.
    static var aliasSpellingListCap: Int {
        3
    }

    /// The typealias spellings a fold reached, named up to ``aliasSpellingListCap`` and counted past it: `Lib.Box and Lib.Crate`, or `Lib.L1, Lib.L10, Lib.L11 and 13 more`.
    static func namedSpellings(_ spellings: [String]) -> String {
        guard spellings.count > aliasSpellingListCap else {
            guard let last = spellings.last else { return "" }
            let earlier = spellings.dropLast()
            return earlier.isEmpty ? last : earlier.joined(separator: ", ") + " and " + last
        }
        let named = spellings.prefix(aliasSpellingListCap)
        return named.joined(separator: ", ") + " and \(spellings.count - named.count) more"
    }

    /// The uses of the type that are written as one of its typealiases, each carrying the spelling it is written as.
    ///
    /// **A use written through an alias is recorded against the alias, not the type**, so `references(ofUSR:)` alone cannot see it: a type with a `typealias` in front of it and three tests behind that answered `1 production · 0 tests` — the alias declaration line, and nothing the tests wrote — which is the deletion verdict this section exists to make trustworthy saying the one thing it must never say wrongly, and saying it in a number rather than in silence. So the aliases are folded in: the store's own record that `typealias Crate = Gizmo` names `Gizmo` is a reference to `Gizmo` *inside the alias declaration's span*, and every reference to that alias is then a line that breaks when the type goes.
    ///
    /// **An alias of an alias is followed to a fixed point**, over a visited set of alias USRs — cheaper than it sounds, and honest where one level is not: `typealias Box = Crate` makes `Crate`'s own declaration the only thing one level can see, so a test using `Box` would be missed by exactly the reasoning that missed it through `Crate`. ``typealiasFoldCap`` bounds it whatever the tree does, cycles included, and a fold that reaches the cap says so in the verdict instead of quietly reporting a number.
    ///
    /// **Cost is one statement per round, not one per reference file** — the store binds every path the references touch into one query — plus two store reads per alias actually found. A type with no alias anywhere near it pays one query for the whole check.
    ///
    /// A `typealias Pair = (Gizmo, Widget)` names the type without being an alias *of* it, and its uses are folded in too — deleting `Gizmo` breaks them, which is the question being answered, and the verdict says "a typealias naming it" rather than claiming to have resolved an alias chain.
    ///
    /// **The symbol being asked about passes its own USR as `excluding`, and an alias asked about itself must.** A covering declaration is found by span and by the name its own text spells, both of which an alias satisfies about itself: a use written on the declaration's own line — `typealias Crate = Gizmo; func f(_ c: Crate) {}` — falls inside `Crate`'s span, and `Crate`'s signature spells `Crate`. Followed, the alias becomes an alias of itself, and the span it contributes then excludes the very use that discovered it: `no uses of Lib.Crate` said of a line that stops compiling without it.
    func aliasFold(
        referencedAt hits: [SemanticStore.Hit],
        named: String,
        excluding asked: String? = nil,
        context: SemanticContext,
        sources: inout SemanticStore.SourceLines
    ) throws -> AliasFold {
        var fold = AliasFold()
        var followed: Set<String> = []
        var frontier = hits.map { Aliasing(hit: $0, name: named) }
        while !frontier.isEmpty, !fold.reachedCap {
            var next: [Aliasing] = []
            for row in try aliasDeclarations(covering: frontier, context: context) {
                guard let aliasUSR = context.store.usr(for: row), aliasUSR != asked, !followed.contains(aliasUSR) else { continue }
                guard followed.count < Self.typealiasFoldCap else {
                    fold.reachedCap = true
                    filesCollector?.recordAliasFoldCapped()
                    break
                }
                followed.insert(aliasUSR)
                try fold.aliases.append(AliasFold.Alias(name: row.name, spelling: store.qualifiedName(of: row), row: row))
                fold.declarationSpans[row.path, default: []].append(row.line ... max(row.line, row.endLine))
                let spelling = try store.qualifiedName(of: row)
                let (aliasHits, aliasGenerated) = context.store.referencesAndGeneratedMentions(ofUSR: aliasUSR, sources: &sources)
                fold.generatedLines.formUnion(aliasGenerated)
                let written = aliasHits.map { hit in
                    var marked = hit
                    marked.writtenAs = spelling
                    return marked
                }
                // A clause written as an alias of this alias is recorded, implicit, against this one too, at the same site: the later alias is the spelling written there.
                fold.hits = AliasFold.excluding(fold.hits, recordedAt: written) + written
                // The next round looks for aliases of *this* alias, so what a covering declaration must spell is
                // its name, not the original type's: `typealias Box = Crate` names `Crate` and never names `Gizmo`.
                next.append(contentsOf: written.map { Aliasing(hit: $0, name: row.name) })
            }
            frontier = next
        }
        return fold
    }

    /// The store's references to `usr`, less its implicit records of a site written as one of its typealiases (``AliasFold/ownReferences(_:)``), with the fold of those typealiases (``aliasFold(referencedAt:named:excluding:context:sources:)``), which `asked` is passed on to.
    func foldedReferences(
        ofUSR usr: String,
        named: String,
        excluding asked: String? = nil,
        context: SemanticContext,
        sources: inout SemanticStore.SourceLines
    ) throws -> (own: [SemanticStore.Hit], fold: AliasFold) {
        let (recorded, generatedLines) = context.store.referencesAndGeneratedMentions(ofUSR: usr, sources: &sources)
        var fold = try aliasFold(referencedAt: recorded, named: named, excluding: asked, context: context, sources: &sources)
        fold.generatedLines.formUnion(generatedLines)
        return (fold.ownReferences(recorded), fold)
    }

    /// The typealias declarations whose own span holds one of these reference hits **and whose own text spells the name the hit is a reference to** — the aliases these references are the aliasing of.
    ///
    /// **The span alone is not enough, and the line it is measured in is why.** Two declarations can share a line — `typealias Inner = Int; var s: Shadow?` — and the hit on `Shadow` then falls inside the span of an alias that names `Shadow` nowhere. Folded in, that alias put `1 written as Holder.Inner, a typealias naming it` into the verdict about a line that does not break when `Shadow` is deleted: a false statement in the one sentence a deletion is decided from, which is the single output this section must never produce. So the alias's own declaration text has to spell the name as a whole identifier as well — ``SymbolRow/signature``, which for a typealias runs to the end of the underlying type, so `typealias Crate = Outer.Shadow` names `Shadow` and `typealias Inner = Int` names nothing.
    private func aliasDeclarations(covering hits: [Aliasing], context: SemanticContext) throws -> [SymbolRow] {
        var namesByLine: [String: [Int: Set<String>]] = [:]
        for aliasing in hits {
            namesByLine[context.relativePath(aliasing.hit.path), default: [:]][aliasing.hit.line, default: []].insert(aliasing.name)
        }
        return try store.typealiases(inFiles: namesByLine.keys.sorted()).filter { row in
            let span = row.line ... max(row.line, row.endLine)
            guard let byLine = namesByLine[row.path] else { return false }
            return byLine.contains { line, names in
                span.contains(line) && names.contains(where: { ExactAnswer.containsWord($0, in: row.signature) })
            }
        }
    }

    /// The line spans a type's own name is written in as part of declaring itself — its declaration, and every extension **of this type in its own module** — and how many extensions of it other modules write.
    ///
    /// An `extension SimilarTarget` header is recorded as a reference to the type, so counting it would make every type with an extension look used by something. Anywhere else in the declaring file is a different matter and stays counted: a sibling type reaching for it is a real dependency, and sharing a file says nothing about that.
    ///
    /// **Which extensions are its own is decided by the extended type's USR, never by the name written after `extension`.** ``ExtensionPaths/extensions(ofTypeNamed:in:)`` matches a leaf name over the whole repo, generic arguments set aside — no module, no nesting — so another module's `extension Widget` over its *own* `Widget`, and an `extension Outer.Item` against a top-level `Item`, would both have their bodies' real uses dropped from the count and then positively denied: "every reference falls inside its own declaration or extensions", said of lines that are a second module breaking when this type is deleted. Silence read as "nothing uses this" was the defect this section exists to end, and a false claim is strictly worse than silence. So the name match only proposes the candidates, each carrying the end line the store does not record, and `sites` — the store's `extendedBy` occurrences of *this* type's USR (``SemanticStore/extensionSites(ofUSR:)``) — decides which of them are real, by the header line falling inside the candidate's span.
    ///
    /// **An extension of this type in another module is a use of it, never its own.** Deleting the type breaks that module, which is the question the verdict answers, so such an extension's span stays counted and the extension is only tallied, for the verdict to say which rule it followed. The module is the syntactic row's, and a module guessed from a path component can split one real module in two — that still errs toward "used", but `otherModuleExtensionsGuessed` records that the split itself is not to be trusted, so the verdict can say the module was guessed rather than state a second module as fact.
    ///
    /// An extension written through a typealias is proposed by neither, so its body's self-references count as uses. That errs toward saying "used", which is the direction a deletion can survive.
    func ownSpans(of row: SymbolRow, extendedAt sites: [SemanticStore.Hit], relativePath: (String) -> String) throws -> OwnSpans {
        var headers: [String: Set<Int>] = [:]
        for site in sites {
            headers[relativePath(site.path), default: []].insert(site.line)
        }
        let guessedModules = try GuessedModuleNotice.reasons(for: store.filesWithGuessedModule(), isUnreadablyRenamed: isUnreadablyRenamed)
        var own = OwnSpans(spans: [row.path: [row.line ... max(row.line, row.endLine)]])
        for extended in try ExtensionPaths.extensions(ofTypeNamed: row.name, in: store) {
            let span = extended.line ... max(extended.line, extended.endLine)
            guard headers[extended.path]?.contains(where: { span.contains($0) }) ?? false else { continue }
            guard extended.module == row.module else {
                own.otherModuleExtensions += 1
                // Either side's module can be the one that was guessed rather than declared — a single-target
                // project with no build file can guess the extension's own directory as a second module, or
                // guess the declaring type's directory as one while a build file names the extension's plainly.
                own.otherModuleExtensionsGuessed.formUnion([extended.path, row.path].compactMap { guessedModules[$0] })
                continue
            }
            own.spans[extended.path, default: []].append(span)
        }
        return own
    }

    /// The hits left once the ones inside the given line spans are taken out, and how many distinct lines that removed — the same unit the verdict counts in, so the two numbers can stand in one sentence.
    ///
    /// Run once per category of line that *names* the type without using it, each of which the verdict states in its own words: the type's own declaration and extensions (``ownSpans(of:extendedAt:relativePath:)``), then the typealias declarations that give it a second name (``AliasFold/declarationSpans``).
    static func excludingSites(
        _ hits: [SemanticStore.Hit],
        inside spans: [String: [ClosedRange<Int>]],
        relativePath: (String) -> String
    ) -> (sites: [SemanticStore.Hit], excluded: Int) {
        var kept: [SemanticStore.Hit] = []
        var dropped: Set<String> = []
        for hit in hits {
            let relative = relativePath(hit.path)
            if spans[relative]?.contains(where: { $0.contains(hit.line) }) ?? false {
                dropped.insert("\(relative):\(hit.line)")
            } else {
                kept.append(hit)
            }
        }
        return (kept, dropped.count)
    }
}

extension WhereRenderer {
    /// What folding a type's typealiases into its usage found: the use sites written as an alias, where the alias declarations themselves are, and whether the fold stopped at its cap with aliases still unfollowed.
    struct AliasFold {
        var hits: [SemanticStore.Hit] = []
        /// Per file, repo-relative, the line spans of the typealias declarations the fold followed — **lines that name the type without using it**, counted apart from the verdict's total the way an `extension Gizmo` header is.
        ///
        /// `typealias Crate = Gizmo` breaks when `Gizmo` is deleted, but so does `extension Gizmo`, and neither is something *using* `Gizmo`: the alias is another name for the type, and it is dead exactly when the type is unless something uses the alias — which the fold has already counted, above, as a use. Counted instead, a type with two unreferenced aliases and nothing else near it answered `2 references in 1 file — 2 production`, and an agent reading `2 production` leaves dead code in place; a twenty-deep chain answered `17 production`, every one of the seventeen an alias declaration.
        ///
        /// Measured in whole lines, like every other span here, so a declaration sharing its line with a real use hands that line to the declaration. The verdict says how many lines it excluded and on what ground, which is the contract: never dropped in silence.
        var declarationSpans: [String: [ClosedRange<Int>]] = [:]
        /// `true` when ``WhereRenderer/typealiasFoldCap`` stopped the fold, which makes the count a lower bound and is said in the verdict.
        var reachedCap = false
        /// The `path:line` of each mention a macro generated that the sweep sets aside, on the symbol asked about and on every alias the fold followed.
        var generatedLines: Set<String> = []

        /// The alias declarations the fold followed.
        var aliases: [Alias] = []
    }
}

extension WhereRenderer.AliasFold {
    /// The type's own `references` less each one the store recorded at the site of one of the fold's hits: what the fold's hits are merged with, and what a sweep of the type's own name lists.
    ///
    /// A clause written through an alias, `class Via: Footing`, is recorded against the alias where it is written and again, implicit, against the class the alias names, at the same file, line and column. The second record is no line that spells the type's own name: counted with the alias's, it made the line the type's own and lost its "written as" attribution, and a rename sweep listed a line a rename leaves alone.
    func ownReferences(_ references: [SemanticStore.Hit]) -> [SemanticStore.Hit] {
        Self.excluding(references, recordedAt: hits)
    }

    /// `hits` less each one a hit of `others` was recorded at by the same unit — file, line and column — which no two names written in code share: the implicit record the store makes of a name an alias stands for, beside the alias's own.
    static func excluding(_ hits: [SemanticStore.Hit], recordedAt others: [SemanticStore.Hit]) -> [SemanticStore.Hit] {
        let sites = Set(others.filter { $0.column > 0 }.map(Site.init))
        return hits.filter { $0.column == 0 || !sites.contains(Site($0)) }
    }

    /// A typealias declaration the fold followed.
    struct Alias {
        /// The name an inheritance clause writes.
        let name: String
        /// The qualified spelling the rows are marked with.
        let spelling: String
        /// The declaration's row, whose file, line and column place it in a parse of that file.
        let row: SymbolRow
    }

    /// Where one unit recorded a hit: what an alias's reference and the store's implicit record of the name it stands for share.
    struct Site: Hashable {
        let unit: String
        let path: String
        let line: Int
        let column: Int

        init(_ hit: SemanticStore.Hit) {
            unit = hit.unit
            path = hit.path
            line = hit.line
            column = hit.column
        }
    }
}

extension WhereRenderer {
    /// The spans a type's own name is written in as part of declaring itself, and how many extensions of it in other modules were left counted as uses.
    struct OwnSpans {
        /// Per file, repo-relative, the line spans of the type's declaration and of its extensions in its own module.
        var spans: [String: [ClosedRange<Int>]]
        var otherModuleExtensions = 0
        /// Why any of `otherModuleExtensions` was counted only because its file's module was guessed rather than declared — a single-target project can guess two directories into two "modules" and split one real module in two, so the count is real but its reason is worth saying.
        var otherModuleExtensionsGuessed: Set<GuessedModuleNotice.Reason> = []
    }

    /// A reference hit together with the name written at it — what a typealias declaration covering that hit must itself spell for the hit to be that alias's aliasing of it.
    struct Aliasing {
        let hit: SemanticStore.Hit
        let name: String
    }

    /// A type's use sites divided the way a deletion weighs them: what production does with it, what the tests do, and what is left over from a path the index has no row for — counted apart rather than guessed into either side.
    struct UsageSplit: Equatable {
        var production = 0
        var tests = 0
        /// Sites in a path with no row that the deletion ledger recorded leaving the tree.
        var deleted = 0
        /// Sites in a path with no row that the deletion ledger never saw go — a generated source, an excluded file, a path outside the repository.
        var neverHeld = 0
        /// How many indexed test files no store holds a unit for, and the build that adds them, empty where no build would (``TestFileCoverage``): the store records no reference from such a file, so the test bucket cannot be read as a count.
        var unbuiltTestFiles = 0
        var unbuiltTestBuild = ""
        /// Of the files with no unit where a test build ran, how many sit outside any target a build of the store's project compiles, so `unbuiltTestFiles` holds only those the last build skipped.
        var outsideTestFiles = 0
        /// The non-test targets no store holds a unit for, so the production bucket is a lower bound.
        var targetsNotBuilt: [String] = []

        /// The split as the verdict states it, one entry per bucket, the two row-less buckets only when they hold a site.
        ///
        /// A path with no row is one of two causes, and each is named for what it counts: a label taken from the first cause explained a generated source's real count with a deletion that never happened. The test bucket never states a count the store cannot back: where test files have no unit, `0 tests` would be said of code nobody indexed, so it says that tests were not counted, and a nonzero count says it is a lower bound.
        var tally: [String] {
            let productionEntry = targetsNotBuilt.isEmpty ? "\(production) production" : "\(production) production, a lower bound (\(SemanticAxis.namingTargets(targetsNotBuilt)) not built)"
            var tally = [productionEntry, testsEntry]
            if deleted > 0 {
                tally.append("\(deleted) in files deleted from the tree")
            }
            if neverHeld > 0 {
                tally.append("\(neverHeld) in files the index never held")
            }
            return tally
        }

        /// What keeps the production or test count from being whole, in the words the verdict puts in its parentheses; empty where every count is complete.
        var lowerBoundReasons: [String] {
            (targetsNotBuilt.isEmpty ? [] : ["\(SemanticAxis.namingTargets(targetsNotBuilt)) not built"]) + (testsReason.map { [$0] } ?? [])
        }

        private var testsReason: String? {
            guard unbuiltTestFiles + outsideTestFiles > 0 else { return nil }
            var reasons: [String] = []
            if unbuiltTestFiles > 0 {
                let plural = unbuiltTestFiles == 1 ? "" : "s"
                reasons.append(unbuiltTestBuild.isEmpty
                    ? "\(unbuiltTestFiles) test file\(plural) not in the last build — rebuild the tests to count them"
                    : "\(unbuiltTestFiles) test file\(unbuiltTestFiles == 1 ? " has" : "s have") no unit in the store; \(unbuiltTestBuild)")
            }
            if outsideTestFiles > 0 {
                reasons.append(unbuiltTestFiles > 0 ? "\(outsideTestFiles) outside any built target" : TestFileCoverage.outsideTargets(outsideTestFiles))
            }
            return reasons.joined(separator: "; ")
        }

        private var testsEntry: String {
            let counted = "\(tests) test\(tests == 1 ? "" : "s")"
            guard let why = testsReason else { return counted }
            return tests == 0 ? "tests not counted (\(why))" : "\(counted), a lower bound (\(why))"
        }
    }

    /// Reference hits grouped one entry per file, holding the distinct lines recorded in it.
    ///
    /// Shared by the two views that report references — the compact usage verdict and the paged sweep — so the counting rule lives in one place and the two can never disagree about how many sites a set of hits is. **Distinct lines, never occurrences**: two occurrences on one line are one place to edit, and it is what the per-file lists enumerate, so a header and its listing always reconcile.
    struct ReferencedFiles {
        /// Every file the hits touch, repo-relative, in alphabetical order — an order that depends on nothing but the file names, which is what makes a cursor over it survive the sweep editing the files it already served.
        let paths: [String]
        private let linesByPath: [String: [Int]]
        /// Per file and line, the declarations the store records the hits there inside, sorted; a hit the store records inside none is left out.
        private let enclosingByPath: [String: [Int: [String]]]
        private let stateByPath: [String: OccurrenceState]
        /// The property wrapper's siblings a reference went through, `$flag` and `_count`, which a heading names because a rename sweeps their spellings too.
        let siblings: [String]
        /// Per file, the typealias spellings its folded lines are written as and how many of its counted lines only an alias reached — a line spelling the type's own name as well is the type's own, never the alias's.
        private let aliasedByPath: [String: Aliased]
        /// Each file as the store names it, absolute, which is where a row's text is read from.
        private let absoluteByPath: [String: String]

        /// The name the store's reference hits carry when it records no declaration around them.
        private static var noEnclosing: String {
            "(top level)"
        }

        init(hits: [SemanticStore.Hit], context: SemanticContext, occurrences: OccurrenceFreshness) {
            var byPath: [String: Set<Int>] = [:]
            var states: [String: OccurrenceState] = [:]
            var absolute: [String: String] = [:]
            var directLines: [String: Set<Int>] = [:]
            var enclosing: [String: [Int: Set<String>]] = [:]
            var spellingsByLine: [String: [Int: Set<String>]] = [:]
            for hit in hits {
                let relative = context.relativePath(hit.path)
                byPath[relative, default: []].insert(hit.line)
                states[relative] = occurrences.state(of: hit.path)
                absolute[relative] = absolute[relative] ?? hit.path
                if hit.name != Self.noEnclosing {
                    enclosing[relative, default: [:]][hit.line, default: []].insert(hit.name)
                }
                if let spelling = hit.writtenAs {
                    spellingsByLine[relative, default: [:]][hit.line, default: []].insert(spelling)
                } else {
                    directLines[relative, default: []].insert(hit.line)
                }
            }
            paths = byPath.keys.sorted()
            linesByPath = byPath.mapValues { $0.sorted() }
            enclosingByPath = enclosing.mapValues { $0.mapValues { $0.sorted() } }
            stateByPath = states
            absoluteByPath = absolute
            siblings = Set(hits.compactMap(\.through)).sorted()
            var folded: [String: Aliased] = [:]
            for (path, byLine) in spellingsByLine {
                let onlyAliased = byLine.filter { !(directLines[path]?.contains($0.key) ?? false) }
                guard !onlyAliased.isEmpty else { continue }
                folded[path] = Aliased(spellings: Set(onlyAliased.values.joined()).sorted(), lines: onlyAliased.count)
            }
            aliasedByPath = folded
        }

        /// Every typealias spelling the counted lines are written as, and how many of them an alias is the only spelling of — the fold, as the verdict states it.
        var aliased: Aliased {
            Aliased(
                spellings: Set(aliasedByPath.values.flatMap(\.spellings)).sorted(),
                lines: aliasedByPath.values.reduce(0) { $0 + $1.lines }
            )
        }

        var sites: Int {
            linesByPath.values.reduce(0) { $0 + $1.count }
        }

        /// One state per distinct file, the unit ``WhereRenderer/driftDetails(states:)`` counts in.
        var states: [OccurrenceState] {
            paths.compactMap { stateByPath[$0] }
        }

        func lines(in path: String) -> [Int] {
            linesByPath[path] ?? []
        }

        /// Where the repo-relative `path` stands against the build.
        func state(of path: String) -> OccurrenceState {
            stateByPath[path] ?? .live
        }

        /// The given files with the ones the tree still backs first, so a truncated listing spends its room on the rows that can still be acted on.
        func liveFirst(_ subset: [String]) -> [String] {
            subset.filter { stateByPath[$0]?.isLive ?? true } + subset.filter { !(stateByPath[$0]?.isLive ?? true) }
        }

        /// Whether the lines are few enough to list one row per line with its source text, every line of every file kept: at most ``WhereRenderer/siteTextLineCap``, which no cap on files or on lines per file reaches.
        var listsSiteText: Bool {
            sites <= WhereRenderer.siteTextLineCap
        }

        /// `path (count): line, line, …` per file, a file with at most ``WhereRenderer/rowedFileSiteCap`` lines listed as rows instead, and how many lines the per-file cap hid across them all — or, where ``listsSiteText``, each file's `path (count):` heading and one `:line` row per line under it, closing on the line's text, with nothing hidden.
        ///
        /// Marking the rows a typealias fold reached with the spelling written there is what the usage verdict asks for and the rename sweep does not: a sweep's siblings are named in its heading, where a folded row is a line that spells no form of this type's name at all and is unfindable from the row without it.
        ///
        /// A row's text is read from the file as it stands, so a file the tree has written since the build, or no longer has, prints its rows without it: the line the store names may have moved, and the text now on it would be another line's.
        func fileLines(_ subset: [String], namingAliases: Bool = false, listsEveryLine: Bool = false) -> (rows: [String], hiddenLines: Int) {
            var rows: [String] = []
            var hiddenLines = 0
            if listsSiteText {
                return (subset.flatMap { siteRows($0, namingAliases: namingAliases) }, 0)
            }
            let cap = listsEveryLine ? Int.max : WhereRenderer.lineListCap
            for path in subset {
                let recorded = lines(in: path)
                // A file the type is used in once or twice is where a lone production use sits, and its line number alone sends the reader back to find what encloses it.
                if recorded.count <= WhereRenderer.rowedFileSiteCap {
                    rows.append(contentsOf: siteRows(path, namingAliases: namingAliases))
                    continue
                }
                var rendered = recorded.prefix(cap).map(String.init).joined(separator: ", ")
                if recorded.count > cap {
                    hiddenLines += recorded.count - cap
                    rendered += ", +\(recorded.count - cap) more"
                }
                rows.append("  \(path) (\(recorded.count)): \(rendered)\(stateByPath[path]?.marker ?? "")\(namingAliases ? aliasSuffix(path) : "")")
            }
            return (rows, hiddenLines)
        }

        /// A file's `path (count):` heading and one `:line` row per line under it, naming the declaration around the line and closing on its text.
        private func siteRows(_ path: String, namingAliases: Bool) -> [String] {
            let recorded = lines(in: path)
            let state = stateByPath[path] ?? .live
            let source = WhereRenderer.StoreSiteText(path: absoluteByPath[path] ?? path, state: state)
            let heading = "  \(path) (\(recorded.count)):\(state.marker ?? "")\(namingAliases ? aliasSuffix(path) : "")"
            return [heading] + recorded.map { line in
                let text = source.text(at: line)
                return "    :\(line)\(enclosingSuffix(path, line: line, text: text))" + NameMatchedSites.textSuffix(text)
            }
        }

        /// The declarations around a row's line, after two spaces as the callers rows print theirs, or nothing where the store records none.
        ///
        /// A declaration whose own line the row is — a parameter's type or default in a function's signature, a property's annotation — is named by the text the row closes on already, so naming it again only makes the answer longer than the search it stands in for.
        private func enclosingSuffix(_ path: String, line: Int, text: String?) -> String {
            guard let names = enclosingByPath[path]?[line]?.filter({ !Self.declares($0, on: text) }), !names.isEmpty else { return "" }
            return "  " + names.map(Self.shortened).joined(separator: ", ")
        }

        /// The longest enclosing name a row prints whole: past it a row stops reading as a line of code, and the base name is enough for `digest Type.base` to find the declaration.
        static let enclosingNameLimit = 30

        /// A name past the limit with an argument-label list, as its base name and `(…)`; any other name as it is.
        private static func shortened(_ name: String) -> String {
            guard name.count > enclosingNameLimit, let open = name.firstIndex(of: "(") else { return name }
            return name[..<open] + "(…)"
        }

        /// Whether `text` is the line declaring `name`: its keyword and base name, or `init(` for an initializer.
        private static func declares(_ name: String, on text: String?) -> Bool {
            guard let text else { return false }
            let base = name.prefix { $0 != "(" }
            guard !base.isEmpty, base.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }) else { return false }
            if base == "init" || base == "subscript" {
                return text.contains("\(base)(") || text.contains("\(base)?(") || text.contains("\(base)<")
            }
            let keywords = "func|var|let|case|struct|class|enum|protocol|actor|typealias|macro|associatedtype"
            guard let pattern = try? Regex("\\b(?:\(keywords))\\s+`?\(base)`?\\b") else { return false }
            return text.contains(pattern)
        }

        /// What a file's row closes on where a typealias fold reached some of its lines: the spelling written there, and how many lines it reached when not all of them.
        private func aliasSuffix(_ path: String) -> String {
            guard let folded = aliasedByPath[path] else { return "" }
            let spellings = WhereRenderer.namedSpellings(folded.spellings)
            return folded.lines == lines(in: path).count ? " — written as \(spellings)" : " — \(folded.lines) written as \(spellings)"
        }

        /// Hands each of `hits` that `fileLines` prints a line number for, over the same `subset`, to `shown`: a line past the per-file cap is only counted, and listed with its text there is no such cap.
        func handOn(_ hits: [SemanticStore.Hit], listedIn subset: [String], relativePath: (String) -> String, listsEveryLine: Bool = false, to shown: (SemanticStore.Hit) -> Void) {
            let perFile = listsSiteText || listsEveryLine ? Int.max : WhereRenderer.lineListCap
            let listed = Set(subset.flatMap { path in lines(in: path).prefix(perFile).map { "\(path):\($0)" } })
            for hit in hits where listed.contains("\(relativePath(hit.path)):\(hit.line)") {
                shown(hit)
            }
        }
    }
}

extension WhereRenderer.ReferencedFiles {
    /// The typealias spellings a file's folded lines are written as, and how many of its lines they account for.
    struct Aliased {
        let spellings: [String]
        let lines: Int
    }
}
