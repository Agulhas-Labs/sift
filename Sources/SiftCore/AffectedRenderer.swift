//
// Copyright © Agulhas Labs
//

import Foundation

/// Which tests reference the symbols a diff changed, and the arguments a runner selects them by.
///
/// **It reports; it does not run, and it never decides what to skip.** There is no `--run` mode, nothing here wraps `xcodebuild`, and no invocation is filtered on a caller's behalf. The output is a list and the flags for it; choosing what to run stays with whoever is accountable for the result. A "your tests pass" that quietly did not run the failing one is the worst answer this tool could produce, and the rest of the codebase is built to refuse exactly that.
///
/// The answer is a **lower bound**, and `AffectedBlindSpots` says so above the list rather than below it. Everything in this type computes what can be found; that type says what cannot, and the two are only safe printed together.
struct AffectedRenderer {
    let store: IndexStore
    /// The checkout `TestInventory` reads under, whose declared inheritance says which XCTest cases run a reached test.
    let repositoryRoot: URL
    /// The resolver's project directories, which decide which unit-less test files belong to another project in the tree and so are never counted, advised or walked.
    let projectDirectories: [String]
    /// Supplies working-tree name mentions for the declarations the index store could not be asked about.
    var mentions: ((Set<String>) async -> [String: [NameMention]])?
    /// Supplies the call sites `where` lists for each name, in the shape asked for it, for the after-edit walk.
    var callSites: (([String: CallSiteScanner.SiteShape]) async -> [String: [SyntacticCallSite]])?
    /// Compares both sides of the named changed files, for the after-edit walk's seeds.
    var fileDiffs: ((Set<String>) throws -> [FileDiff])?
    /// When a file was last committed, for a comparison against `HEAD`.
    ///
    /// A file committed since the build has edits the working-tree diff no longer shows. `nil` for a range, whose diff spans every commit in it.
    var lastCommitTime: ((String) -> Double?)?
    /// When `HEAD` last moved other than by a commit made on it, for a comparison against the build.
    ///
    /// A checkout, a pull or a reset since the build brings in edits no commit time newer than the build dates. `nil` for a range.
    var headMoveTime: (() -> Double?)?
}

extension AffectedRenderer {
    /// Points the walks at the working tree: its written names for the fallback, and for the after-edit walk its call sites and both sides of each changed file, the before side read from the range's start or `HEAD`.
    mutating func readingWorkingTree(enumerator: FileEnumerator, git: GitContext, changes: [GitContext.Change], range: AffectedOptions.CommitRange?) {
        let scanner = NameMentionScanner(repoRoot: repositoryRoot, enumerator: enumerator)
        let callScanner = CallSiteScanner(repoRoot: repositoryRoot, enumerator: enumerator)
        mentions = { await scanner.mentions(of: $0) }
        callSites = { await callScanner.callSites(named: $0) }
        lastCommitTime = range == nil ? { git.lastCommitTime(of: $0) } : nil
        headMoveTime = range == nil ? { HeadReflog.lastMoveTime(in: git) } : nil
        fileDiffs = { [repositoryRoot] paths in
            try AffectedAfterEditSeeds.fileDiffs(of: changes.filter { paths.contains($0.path) }, range: range, git: git, repositoryRoot: repositoryRoot)
        }
    }

    /// Individual tests printed per target before the whole target is named instead.
    ///
    /// Past this the per-test list stops being usable and — much worse — a truncated flag list *looks* complete when pasted. Naming the target runs a superset, which is the safe direction, and the answer says which targets were coarsened and why.
    static var testListCap: Int {
        25
    }

    /// Changed files listed before the list is truncated; the count above it is always exact.
    static var changedFileListCap: Int {
        20
    }

    /// Changed declarations resolved against the store per query.
    static var declarationCap: Int {
        500
    }

    /// Total declarations expanded across every hop, the bound that keeps a change in a widely-used type from walking most of the repository.
    static var expansionCap: Int {
        1500
    }

    /// Names carried into the next hop of the working-tree scan — the same bound on the syntactic side, where a changed symbol called `id` would otherwise turn hop two into a scan for everything.
    static var nameFrontierCap: Int {
        200
    }

    /// The marker every limit in the block carries, so the sentence below the list can count them rather than name a number that drifts.
    static var limitBullet: String {
        "  · "
    }

    /// Files a single written name may appear in before the name stops counting as evidence at all.
    ///
    /// The case that sets it: a few refused enum cases named `active`, `stale` and `unresolved` are enough to make a small change select most of the suite. A written-name match is evidence only insofar as it narrows, and a name written in a quarter of the repository narrows nothing — it converts the fallback from "a lead worth checking" into "the whole suite, with a footnote". Dropped names are counted and named in the answer rather than silently skipped, because a reader has to be able to tell "nothing matched" from "the match was worthless".
    static var nameEvidenceFileCap: Int {
        40
    }
}

extension AffectedRenderer {
    /// What is known about one reached test: how far away it was, whether the store resolved it or a name merely matched, and where its evidence stands against the build.
    struct Evidence {
        var depth: Int
        var resolved: Bool
        var state: OccurrenceState
        var path: String
        var line: Int

        /// The stronger of two accounts of the same test — nearer, resolved rather than name-matched, and live rather than drifted.
        ///
        /// The declaring site is whichever account is kept, since a test has only one.
        func merged(with other: Evidence) -> Evidence {
            Evidence(
                depth: min(depth, other.depth),
                resolved: resolved || other.resolved,
                state: state.isLive || other.state.isLive ? .live : state,
                path: path,
                line: line
            )
        }
    }
}

extension AffectedRenderer {
    func render(
        changes: [GitContext.Change],
        excludedByConfig: [String],
        semantic: SemanticInput,
        options: AffectedOptions
    ) async throws -> Output {
        let reader = TestSymbolReader(store: store)
        let resolution = try resolveChangedDeclarations(changes, excludedByConfig: excludedByConfig)
        var lines = preamble(semantic: semantic, options: options)
        lines.append("")
        lines.append(contentsOf: resolution.summary)

        var semanticWalk = SemanticWalk(unanswered: resolution.declarations)
        var axis: SemanticAxis = .syntacticOnly
        var newerFiles: Set<String> = []
        var unbuiltTests = UnbuiltTestFiles()
        var declaringFiles: OccurrenceFreshness?
        if case let .unavailable(note) = semantic {
            axis = SiftEngine.noStoreAxis(from: note)
        }
        if case .warming = semantic {
            axis = .warming
        }
        if case .openFailed = semantic {
            axis = .openFailed
        }
        if case let .active(context) = semantic {
            let occurrences = OccurrenceFreshness(store: store, context: context, projectDirectories: projectDirectories, citedBy: context.store)
            let judge = OccurrenceFreshness(store: store, context: context, projectDirectories: projectDirectories)
            declaringFiles = judge
            semanticWalk = try self.semanticWalk(from: resolution.declarations, context: context, reader: reader, occurrences: occurrences, declaringFiles: judge, depth: options.depth)
            let withoutUnit = try context.testFilesWithoutUnit(in: store, projectDirectories: projectDirectories)
            unbuiltTests = UnbuiltTestFiles(paths: withoutUnit.unbuilt, outsideTargets: withoutUnit.outsideTargets, provenance: context.store.provenance, package: context.store.package)
            axis = .of(refusals: semanticWalk.refusals, occurrences: occurrences, testFilesWithoutUnit: unbuiltTests.paths.count)
            newerFiles = Set(semanticWalk.refusals.filter(\.reason.isStale).map(\.path)).union(occurrences.modifiedFiles).union(occurrences.newFiles)
        }
        // A file changed since the build is seeded from the declarations the diff touched in it and walked to their call sites, where both its sides could be compared; every other unanswered declaration keeps the written-name walk.
        let afterEdit = try afterEditSeeds(refusals: semanticWalk.refusals, declaringFiles: declaringFiles)
        let mentionInput = semanticWalk.unanswered.filter { !afterEdit.files.contains($0.path) }
        let nameWalk = try await nameWalk(from: Self.mentionSeeds(mentionInput), reader: reader, depth: options.depth, excluding: Set(unbuiltTests.outsideTargets))
        var callWalk = try await self.nameWalk(from: afterEdit.seeds, reader: reader, depth: options.depth, excluding: Set(unbuiltTests.outsideTargets), byCallSites: true, fallbacks: afterEdit.fallbacks)
        for row in afterEdit.rows {
            if let test = try reader.testSymbol(enclosing: row) {
                record(test, resolved: false, depth: 1, state: .live, into: &callWalk.reached)
            }
        }
        // The declarations the store did answer for, asked again by name of the test files it holds no unit for: the store's answer for them cannot include a reference from a target it never compiled.
        let unanswered = Set(semanticWalk.unanswered.map(\.id))
        let testSideWalk = unbuiltTests.paths.isEmpty ? NameWalk() : try await self.nameWalk(
            from: Self.mentionSeeds(resolution.declarations.filter { !unanswered.contains($0.id) && $0.kind != .extensionKind }),
            reader: reader,
            depth: options.depth,
            recordingOnlyIn: Set(unbuiltTests.paths),
            excluding: Set(unbuiltTests.outsideTargets)
        )
        // Appended here rather than beside the fallback's own notes further down, because the limits block
        // below points *upwards* at them: a note printed under the block it explains is a note the reader
        // reaches after the decision it was meant to inform.
        lines.append(contentsOf: [
            semanticWalk.walkedOn.note(depth: options.depth),
            semanticWalk.capNote(cap: Self.expansionCap),
            nameWalk.capNote(cap: Self.nameFrontierCap),
            testSideWalk.capNote(cap: Self.nameFrontierCap),
            callWalk.capNote(cap: Self.nameFrontierCap),
        ].compactMap(\.self).map { "  \($0)" })

        var reached = semanticWalk.reached
        merge(nameWalk.reached, into: &reached)
        merge(testSideWalk.reached, into: &reached)
        merge(callWalk.reached, into: &reached)
        // A suite reached whole stands for every test declared in it, in either style, and only the inventory knows how many; it also says whether every test of a target is reached, which names the target whole.
        let inventory = try reached.isEmpty ? nil : TestInventory.read(store: store, repositoryRoot: repositoryRoot)
        reached = collapsingSuites(namingInheritedTests(reached, in: inventory))
        let capped = resolution.capped || semanticWalk.capped || nameWalk.capped || testSideWalk.capped || callWalk.capped

        let answeredBy = afterEdit.files.isEmpty
            ? (reached.isEmpty ? "nothing reached" : reached.values.allSatisfy { !$0.resolved } ? "a name match" : "resolved references")
            : "the after-edit walk (syntactic, from the declarations the diff touched)"
        let provenance: DiscoveredStore.Provenance? = if case let .active(context) = semantic {
            context.store.provenance
        } else {
            nil
        }
        let package = if case let .active(context) = semantic {
            context.store.package
        } else {
            ""
        }
        let runners = AffectedRunners(provenance: provenance, package: package)
        let (limits, ways) = blindSpots(
            runners: runners,
            headline: (answeredBy: answeredBy, depthLine: AffectedBlindSpots.depthLine(options.depth, walkedOn: semanticWalk.walkedOn.outcomes.count)),
            resolution: resolution,
            excludedByConfig: excludedByConfig,
            reached: reached,
            capped: capped
        )
        lines.append("")
        lines.append(contentsOf: limits)
        lines.append(contentsOf: SemanticRefusal.lines(semanticWalk.refusals, namingDeclarations: false, declarationsSpanMultipleFiles: true))
        if !semanticWalk.refusals.isEmpty, nameWalk.scannedNames > 0 {
            lines.append("  the name match used \(mentionInput.count) declaration\(mentionInput.count == 1 ? "" : "s") from the files above, not listed here")
        }
        lines.append(contentsOf: nameWalk.notes(cap: Self.nameEvidenceFileCap))
        lines.append(contentsOf: callWalk.afterEditNotes(afterEdit, cap: Self.nameEvidenceFileCap))
        lines.append(contentsOf: unbuiltTests.notes(walk: testSideWalk, cap: Self.nameEvidenceFileCap))
        // Counted, not written by hand: the standing list plus this answer's own entries.
        lines.append(contentsOf: AffectedTestSections(reached: reached, inventory: inventory, options: options, ways: ways, package: package, runners: runners, provenance: provenance, afterEdit: afterEdit.files.isEmpty ? nil : (afterEdit, callWalk.scannedNames)).lines())
        let listed = reached.keys.sorted().map { test in
            let evidence = reached[test]
            return ReachedTest(
                target: test.target,
                described: test.described,
                depth: evidence?.depth ?? 1,
                nameMatch: evidence?.resolved == false,
                location: "\(evidence?.path ?? "?"):\(evidence?.line ?? 0)\(evidence?.state.marker ?? "")"
            )
        }
        if !options.probes.isEmpty {
            let members = AffectedProbe.members(of: reached.keys, in: inventory)
            for probe in options.probes {
                lines.append(contentsOf: AffectedProbe.lines(for: probe, reached: listed, members: members, depth: options.depth, walkedTo: semanticWalk.walkedOn.furthest))
            }
        }
        return Output(body: lines.joined(separator: "\n"), axis: axis, reached: listed, limitCount: ways, depth: options.depth, walkedOn: semanticWalk.walkedOn.outcomes.count, walkedTo: semanticWalk.walkedOn.furthest, newerFiles: newerFiles)
    }

    /// The declaration/callers/overrides clause every `noStoreNote` carries, worded for `where`, which answers with those.
    ///
    /// `affected` answers with tests, and says what stands in for semantic ones two lines down instead. Shares `SiftEngine.syntaxOnlyTail` rather than its own copy, so a reworded tail cannot silently stop matching here and leave the clause in the note unstripped.
    private static let declarationsVsCallersClause = " " + SiftEngine.syntaxOnlyTail

    /// The three lines that say what this answer is, and the one that says what it is not.
    private func preamble(semantic: SemanticInput, options: AffectedOptions) -> [String] {
        var lines = ["affected tests — changed: \(options.range?.described ?? "working tree vs HEAD")"]
        switch semantic {
        case let .inactive(note), let .unavailable(note), let .warming(note), let .openFailed(note):
            let note = note.hasSuffix(Self.declarationsVsCallersClause)
                ? String(note.dropLast(Self.declarationsVsCallersClause.count))
                : note
            lines.append("\(SiftEngine.degradedModeOpening)\(note)")
        case let .active(context):
            lines.append("mode: syntactic + semantic (index store via \(DiscoveredStore.label(provenance: context.store.provenance, package: context.store.package)))")
        }
        lines.append("depth: \(options.depth) reference hop\(options.depth == 1 ? "" : "s") from the changed declarations")
        // A sweep that silently returns nothing reads as "nothing to run", which is the one way this command can do harm.
        if !semantic.isActive {
            lines.append("resolved references: UNAVAILABLE — they come from the index store, which this query has none of; every test below is a NAME MATCH ONLY")
        }
        return lines
    }
}

extension AffectedRenderer {
    /// A test suite the walk reached from some declarations, spelled as `swift test --filter` takes it, and how many hops out.
    struct ReachedSuite: Equatable {
        let filter: String
        let depth: Int
    }

    /// The suites that reach one of `declarations`, `depth` hops out: the walk `render` runs, the semantic store's where it is open and the name walk for every declaration the store could not answer for, nearest suites first.
    ///
    /// A test declared at file scope is named by its own filter and a case nested in another type, which no `--filter` selects, is left out.
    func suitesReaching(_ declarations: [SymbolRow], semantic: SemanticInput, depth: Int) async throws -> [ReachedSuite] {
        let reader = TestSymbolReader(store: store)
        var reached: [TestSymbol: Evidence] = [:]
        var unanswered = declarations
        var excluded: Set<String> = []
        if case let .active(context) = semantic {
            let occurrences = OccurrenceFreshness(store: store, context: context, projectDirectories: projectDirectories, citedBy: context.store)
            let declaringFiles = OccurrenceFreshness(store: store, context: context, projectDirectories: projectDirectories)
            let walk = try semanticWalk(from: declarations, context: context, reader: reader, occurrences: occurrences, declaringFiles: declaringFiles, depth: depth)
            reached = walk.reached
            unanswered = walk.unanswered
            excluded = try Set(context.testFilesWithoutUnit(in: store, projectDirectories: projectDirectories).outsideTargets)
        }
        try await merge(nameWalk(from: Self.mentionSeeds(unanswered), reader: reader, depth: depth, excluding: excluded).reached, into: &reached)
        var nearest: [String: Int] = [:]
        for (test, evidence) in reached where !test.swiftTestFilterSelectsNothing {
            let filter = test.suite == nil ? test.swiftTestFilter : test.suiteOnly.described
            nearest[filter] = min(nearest[filter] ?? evidence.depth, evidence.depth)
        }
        return nearest.map { ReachedSuite(filter: $0.key, depth: $0.value) }.sorted { ($0.depth, $0.filter) < ($1.depth, $1.filter) }
    }
}

extension AffectedRenderer {
    /// What the change set resolved to, and what it could not.
    struct Resolution {
        var declarations: [SymbolRow]
        var unreadable: [String]
        var summary: [String]
        var capped: Bool
    }

    /// Every declaration in every changed file — **the whole file, not the changed lines**.
    ///
    /// The alternative, resolving only declarations overlapping a diff hunk, is under-inclusive in three ways that all fail dangerously. A hunk's line numbers refer to the *old* file for deletions and the new one for additions, while the index holds current-tree ranges, so a deletion has no extent to intersect at all — and a deleted method is precisely the change whose references break. A one-line edit to a stored property changes the meaning of every member that reads it. And an added file is entirely new, so every declaration in it is changed by definition. Erring wide costs a longer list; erring narrow costs a test that should have run and did not, and the second is the failure this command exists to prevent.
    ///
    /// Extensions are dropped for the same reason `where` drops them: an extension carries no USR of its own, so it can only ever refuse against something no build will resolve. Its *members* are separate rows and are kept.
    private func resolveChangedDeclarations(_ changes: [GitContext.Change], excludedByConfig: [String]) throws -> Resolution {
        var declarations: [SymbolRow] = []
        var unreadable: [String] = []
        var fileLines: [String] = []
        var saidOperators = false
        for change in changes.sorted(by: { $0.path < $1.path }) {
            let rows = try store.symbols(inFile: change.path).filter { $0.kind != .extensionKind }
            declarations.append(contentsOf: rows)
            // Split on whether the index has a *file* row, not on whether it has declarations. They are two
            // different facts and the answer says two different things about them: a file the index has
            // never heard of has left the working tree, while a file it holds that declares nothing — a
            // `main.swift` of top-level code, a file of nothing but extensions — is sitting on disk. Reading
            // the second as the first would make one answer say "added or modified" and "is not in the working
            // tree" about the same path, two lines apart.
            if rows.isEmpty, try store.fileRow(path: change.path) == nil {
                unreadable.append(change.path)
            }
            var detail = if rows.isEmpty, try store.fileRow(path: change.path) == nil {
                "no longer in the working tree (renamed or deleted since), so nothing was resolved"
            } else {
                rows.isEmpty ? "no declarations in the index" : "\(rows.count) declarations"
            }
            // Said in full on the first file holding one, then counted: no build records an operator declaration, so it is neither followed nor refused.
            let operators = rows.count { $0.kind == .operatorKind }
            if operators > 0 {
                let noun = operators == 1 ? "operator declaration" : "operator declarations"
                detail += saidOperators ? " (\(operators) \(noun))" : " (\(operators) \(noun), which the index store does not record, so no build answers for \(operators == 1 ? "it" : "them"))"
                saidOperators = true
            }
            fileLines.append("  \(change.path) — \(Self.described(change.kind)), \(detail)")
        }
        var summary = ["changed files (\(changes.count)), declarations resolved (\(declarations.count)):"]
        summary.append(contentsOf: fileLines.prefix(Self.changedFileListCap))
        if fileLines.count > Self.changedFileListCap {
            summary.append("  truncated: \(fileLines.count - Self.changedFileListCap) more changed files")
        }
        if changes.isEmpty {
            // Two different nothings, and a reader acts on each differently. "No .swift file differs" is a
            // claim about the working tree, and it is false whenever this repository's own `roots` or
            // `exclude` dropped a changed file before it was counted — which the block below then names.
            summary.append(excludedByConfig.isEmpty
                ? "  (nothing changed — no .swift file differs)"
                : "  (nothing examined — every changed .swift file is outside what this repository indexes; see the limits below)")
        }
        let capped = declarations.count > Self.declarationCap
        if capped {
            summary.append("  note: only the first \(Self.declarationCap) declarations were followed; the rest of the change set is unexamined")
        }
        return Resolution(declarations: Array(declarations.prefix(Self.declarationCap)), unreadable: unreadable, summary: summary, capped: capped)
    }

    private static func described(_ kind: GitContext.Change.Kind) -> String {
        switch kind {
        case .addedOrModified: "added or modified"
        case .deleted: "deleted"
        case let .renamed(from): "renamed from \(from)"
        }
    }
}

private extension AffectedRenderer {
    /// Everything one resolved walk produced — returned rather than accumulated through `inout` parameters, so the two walks compose by merging their results instead of by sharing a mutable box.
    struct SemanticWalk {
        var reached: [TestSymbol: Evidence] = [:]
        var refusals: [SemanticRefusal] = []
        var unanswered: [SymbolRow] = []
        var capped = false
        var walkedOn = ResolvedWalkOn.Result()

        /// What this walk has to say when its own bound stopped it, in the wording and the place the declaration cap already uses.
        ///
        /// Each walk carries its own because the limits block says "the notes above say which cap": a change concentrated in a widely-referenced type trips this one with the declaration cap untouched, and without its own note the answer would say a cap had fired, name none, and point at nothing.
        func capNote(cap: Int) -> String? {
            if let note = walkedOn.capNote(cap: cap) {
                return note
            }
            return capped ? "note: the resolved walk stopped after expanding \(cap) declarations; references from the rest of its frontier were not followed" : nil
        }
    }

    /// Follows recorded references outward from the changed declarations, recording the tests it lands in and expanding everything else.
    ///
    /// The frontier is expanded through every declaration but a test function and a suite's type (``leadsOn(_:from:)``). A helper that references changed code is a route to the tests that use the helper, a suite's own helper included, which also names its suite; a test that references it is a destination, and expanding it would follow whatever happens to reference the test — which is nothing, or another test, and neither is evidence of anything.
    ///
    /// Refusals are the same per-symbol rule `where` applies, for the same reason and in the same words: a declaration whose file was written since the build cannot have its USR resolved safely, so it is refused rather than answered from stale data (Docs/Design.md §2). This command meets that case far more often than `where` does — the files it is asked about are by definition the ones just edited — which is exactly why the name-matched fallback exists downstream.
    func semanticWalk(
        from roots: [SymbolRow],
        context: SemanticContext,
        reader: TestSymbolReader,
        occurrences: OccurrenceFreshness,
        declaringFiles: OccurrenceFreshness,
        depth: Int
    ) throws -> SemanticWalk {
        var walk = SemanticWalk()
        var visited: Set<Int64> = []
        var frontier = roots
        var expanded = 0
        var expansions: [Int64: [ResolvedWalkOn.Hit]] = [:]

        // The rows reached through a suite's helper, kept apart so each hop expands the ordinary ones first: under the cap the helper's routes take only the room the ordinary ones leave.
        var helperFrontier: [SymbolRow] = []

        for hop in 1 ... depth {
            var next: [SymbolRow] = []
            var nextHelpers: [SymbolRow] = []
            // A row reached through a helper leads on as a helper route too, so everything past a helper is expanded after the ordinary rows of its hop.
            let ordinary = frontier.count
            for (index, row) in (frontier + helperFrontier).enumerated() where visited.insert(row.id).inserted {
                let viaHelper = index >= ordinary
                guard expanded < Self.expansionCap else {
                    // Handed to the fallback, not dropped. The `where` clause above has already marked this
                    // row visited, so a `break` left it expanded by neither walk and asked about by neither:
                    // `unanswered` is what feeds the name-matched fallback, and a declaration the store could
                    // not be asked about *because the cap stopped it* is precisely the case that fallback
                    // exists for. Returning rather than breaking stops the same thing happening again to the
                    // first row of every remaining hop; the rest of this frontier is what the cap note above
                    // already says was not followed.
                    walk.capped = true
                    walk.unanswered.append(row)
                    return walk
                }
                // An extension carries no USR of its own — the store anchors the type's canonical occurrence at the type's declaration — so refusing it would print "build this target, then retry" against something no build can ever resolve, and would then feed the extended type's name into the name-matched fallback as if it were a changed symbol. `where` skips it for the first half of that reason; this one has both.
                // An operator declaration (`infix operator <~>`) is never recorded by the store, so no build answers for it either; the changed-files list says so beside its file.
                guard row.kind != .extensionKind, row.kind != .operatorKind else { continue }
                expanded += 1
                let qualified = try store.qualifiedName(of: row)
                let file = try store.fileRow(path: row.path)
                // A file outside a nested package's store is refused as outside it, edited or not: no build of that package covers it.
                let outside = context.packagesPassingOver(file: row.path) != nil
                // Judged against the file's own build, so an edit a later build of another target skipped is refused too.
                let fileKind = outside ? FileKind.current : declaringFiles.kind(ofFile: row.path, citedBy: context.store)
                let stale = fileKind == .new
                    ? SemanticRefusal.unowned(row, symbol: qualified, file: file, kind: fileKind, context: context, source: nil)
                    : SemanticRefusal.changed(row, symbol: qualified, file: file, kind: fileKind, holder: context.store)
                if let stale {
                    walk.refusals.append(stale)
                    walk.unanswered.append(row)
                    continue
                }
                guard let usr = context.store.usr(for: row) else {
                    // The same reason `where` gives: a declaration under `#if` in a file the build did compile is not sent to build.
                    let source = { [repositoryRoot] (path: String) in try? String(contentsOf: repositoryRoot.appendingPathComponent(path), encoding: .utf8) }
                    walk.refusals.append(SemanticRefusal.unowned(row, symbol: qualified, file: file, kind: .current, context: context, source: source))
                    walk.unanswered.append(row)
                    continue
                }
                let rowHits = try hits(ofUSR: usr, context: context, reader: reader, occurrences: occurrences)
                expansions[row.id] = rowHits
                for hit in rowHits {
                    if let test = hit.test {
                        record(test, resolved: true, depth: hop, state: hit.state, into: &walk.reached)
                    }
                    if hit.leadsOn, !visited.contains(hit.enclosing.id) {
                        if viaHelper || hit.test != nil {
                            nextHelpers.append(hit.enclosing)
                        } else {
                            next.append(hit.enclosing)
                        }
                    }
                    // A reference inside a type nested in a suite also leads on to that type and the initialisers it declares, on the helper route: another suite that builds the type reaches the change without touching the member the reference sits in.
                    if let helper = hit.test?.helperType {
                        let routes = try [helper] + store.children(of: helper.id).filter { $0.kind == .initializer }
                        nextHelpers.append(contentsOf: routes.filter { !visited.contains($0.id) })
                    }
                }
            }
            frontier = next
            helperFrontier = nextHelpers
        }
        // Reached only when the cap did not stop the walk above, which returns from inside the loop: a capped walk is already wider than its bound can show.
        var walkOn = ResolvedWalkOn(hits: expansions) { row in
            guard row.kind != .extensionKind, row.kind != .operatorKind,
                  !declaringFiles.writtenSinceBuild(file: row.path),
                  let usr = context.store.usr(for: row) else { return nil }
            return try hits(ofUSR: usr, context: context, reader: reader, occurrences: occurrences)
        }
        var budget = Self.expansionCap - expanded
        let walkedOn = try walkOn.run(from: changedFilesOutsideTests(roots), depth: depth, budget: &budget)
        for reached in walkedOn.reached {
            record(reached.test, resolved: true, depth: reached.hop, state: reached.state, into: &walk.reached)
        }
        walk.walkedOn = walkedOn
        walk.capped = walkedOn.capped
        return walk
    }

    /// The references the store recorded to one USR, each as the declaration it landed in, the test that is or encloses it, and whether the walk follows it on.
    func hits(ofUSR usr: String, context: SemanticContext, reader: TestSymbolReader, occurrences: OccurrenceFreshness) throws -> [ResolvedWalkOn.Hit] {
        try context.store.references(ofUSR: usr).compactMap { hit in
            // Every cited path is judged, so the header's axis sees the deleted and drifted files this answer drew on (Docs/Design.md §2).
            let state = occurrences.state(of: hit.path)
            guard state != .deleted else { return nil }
            let path = context.relativePath(hit.path)
            guard let enclosing = try reader.enclosingSymbol(path: path, line: hit.line) else { return nil }
            let test = try reader.testSymbol(enclosing: enclosing)
            return ResolvedWalkOn.Hit(enclosing: enclosing, test: test, state: state, leadsOn: Self.leadsOn(enclosing, from: test))
        }
    }

    /// The after-edit walk's seeds: the declarations the diff touched in each file the store refused as changed since the build.
    ///
    /// A file committed since its own build is seeded whole, the diff against `HEAD` showing only the edits after that commit; so is one whose last commit time cannot be read, and so is every refused file built before `HEAD` last moved, or every one when that cannot be read.
    func afterEditSeeds(refusals: [SemanticRefusal], declaringFiles: OccurrenceFreshness?) throws -> AffectedAfterEditSeeds {
        let refused = Set(refusals.filter(\.reason.isStale).map(\.path))
        guard !refused.isEmpty, callSites != nil, let fileDiffs, let declaringFiles else { return AffectedAfterEditSeeds() }
        let anchors = Dictionary(uniqueKeysWithValues: refused.map { ($0, declaringFiles.buildAnchor(ofFile: $0)) })
        let headMove = headMoveTime.map { $0() }
        let movedPast: Set<String> = headMove.map { time in refused.filter { AffectedAfterEditSeeds.isSinceBuild(time, anchor: anchors[$0] ?? 0) } } ?? []
        let headMoved = movedPast == refused
        let committed: Set<String> = headMoved ? [] : lastCommitTime.map { time in refused.filter { AffectedAfterEditSeeds.isSinceBuild(time($0), anchor: anchors[$0] ?? 0) } } ?? []
        let whole = movedPast.union(committed)
        var seeds = try AffectedAfterEditSeeds.of(fileDiffs(refused.subtracting(whole)), store: store)
        (seeds.committedSinceBuild, seeds.headMovedSinceBuild) = (whole, headMoved)
        return seeds
    }

    /// The changed declarations by file, for the files outside the test files: a changed test file is where tests already are, so it is never walked on.
    func changedFilesOutsideTests(_ roots: [SymbolRow]) throws -> [String: [SymbolRow]] {
        var files: [String: [SymbolRow]] = [:]
        for row in roots where row.kind != .extensionKind && row.kind != .operatorKind {
            files[row.path, default: []].append(row)
        }
        return try files.filter { path, _ in
            try !TestFileRecognition.isTestFile(imports: store.fileRow(path: path)?.imports ?? [])
        }
    }
}

private extension AffectedRenderer {
    struct NameWalk {
        var reached: [TestSymbol: Evidence] = [:]

        /// Every name carried into a scan, summed over the hops that ran — not the seed set, which is only the first of them.
        var scannedNames = 0

        var tooCommon: Set<String> = []
        var capped = false

        /// Tests a name turned up in from a module that cannot load the module declaring the name, which the walk did not record.
        var setAside: Set<TestSymbol> = []

        /// The same note for the syntactic side, and printed in the same place — beside the resolved walk's, above the block that refers to both.
        func capNote(cap: Int) -> String? {
            capped ? "note: the name-matched fallback carried only \(cap) names into the next hop; the ones it dropped were not scanned" : nil
        }

        /// What the fallback has to say about itself, in the answer: that a name is not a symbol, and which names it threw away for being too common to mean anything.
        ///
        /// The two numbers are over one population by construction, which is the whole reason ``scannedNames`` counts per hop rather than once. Holding the seed count while `tooCommon` accumulated across every hop would let a `--depth 2` answer read "3 written names … were scanned" and, on the very next line, "10 names in that scan were … dropped" — ten out of three, in a command whose contract is that the reader can check its arithmetic against the limits block.
        func notes(cap: Int) -> [String] {
            guard scannedNames > 0 else { return [] }
            var lines = ["", "name-matched fallback: \(scannedNames) written name\(scannedNames == 1 ? "" : "s") \(scannedNames == 1 ? "was" : "were") scanned across the working tree instead — the base names of the declarations the store could not be asked about, and at each further hop the names of the declarations those turned up in. **A name is not a symbol** — same-named members of unrelated types are included, and dynamically dispatched uses are missed. Those tests are marked `name match` below."]
            lines.append(contentsOf: [tooCommonNote(cap: cap), setAsideNote()].compactMap(\.self))
            return lines
        }

        /// What the after-edit walk says of itself: what it was seeded from, and that a call site found by its written name is not a resolved reference.
        func afterEditNotes(_ seeds: AffectedAfterEditSeeds, cap: Int) -> [String] {
            let reason = seeds.headMovedSinceBuild ? "HEAD moved since the build" : "committed since the build"
            let committed = seeds.committedSinceBuild.isEmpty ? [] : ["", "after-edit walk — seeded whole: \(reason): \(seeds.committedSinceBuild.sorted().joined(separator: ", "))"]
            guard !seeds.files.isEmpty else { return committed }
            let files = seeds.files.count
            let names = "\(seeds.nameCount) name\(seeds.nameCount == 1 ? "" : "s")"
            let note = "after-edit walk — syntactic, lower bound: the \(files) file\(files == 1 ? "" : "s") changed since the build \(files == 1 ? "was" : "were") seeded from the \(names) the diff touched there (\(seeds.namesListed)), not every declaration in \(files == 1 ? "it" : "them"), and followed to the call sites `where` finds by written name, \(scannedNames) name\(scannedNames == 1 ? "" : "s") over every hop. **A call site found by name is not a resolved reference** — same-named members of unrelated types are included, and dynamically dispatched uses are missed. Those tests are marked `name match` below, and a test the diff touched is listed itself."
            return ["", note] + committed + [tooCommonNote(cap: cap), setAsideNote()].compactMap(\.self)
        }

        /// The names dropped for being written in more than `cap` files, named.
        func tooCommonNote(cap: Int) -> String? {
            guard !tooCommon.isEmpty else { return nil }
            let names = tooCommon.sorted()
            return "  \(names.count) name\(names.count == 1 ? "" : "s") in that scan \(names.count == 1 ? "was" : "were") written in more than \(cap) files and dropped rather than admitted — a match that broad narrows nothing, so NOTHING is reported for \(names.count == 1 ? "it" : "them"): \(names.joined(separator: ", "))"
        }

        /// The line counting the tests set aside because their module cannot load the module declaring the name, with their targets named.
        func setAsideNote() -> String? {
            let unreached = setAside.filter { test in reached[test] == nil && !reached.keys.contains { $0.wholeSuiteRuns(test) } }
            guard !unreached.isEmpty else { return nil }
            let targets = Set(unreached.map(\.target)).sorted()
            let count = unreached.count
            return "  \(count) name-matched test\(count == 1 ? "" : "s") or suite\(count == 1 ? "" : "s") set aside in \(targets.joined(separator: ", ")): \(count == 1 ? "its" : "their") module cannot load the module declaring the name written there, since no import in it names that module or a tree module that loads it"
        }
    }

    /// The test files no store holds a unit for, and what the answer says of them: the store records no reference from a target it never compiled, so its answer is a lower bound and those files are name-matched instead.
    struct UnbuiltTestFiles {
        var paths: [String] = []

        /// The test files another project in the tree holds, after a test build ran: no build of the store's project compiles them, so they are counted on one line and never walked, since their tests would land in runner lines naming a target that build does not have.
        var outsideTargets: [String] = []

        var provenance: DiscoveredStore.Provenance?
        var package = ""

        /// The one note saying so, with the build that adds them where it is known: SwiftPM's own store, since a plain `swift build` builds no test target.
        func notes(walk: NameWalk, cap: Int) -> [String] {
            var outside: [String] = []
            if !outsideTargets.isEmpty {
                let them = outsideTargets.count == 1 ? "it" : "them"
                outside = ["", "\(TestFileCoverage.outsideTargets(outsideTargets.count)): no build of the store's project compiles \(them), so no test in \(them) was matched"]
            }
            guard !paths.isEmpty else { return outside }
            let count = paths.count
            let build = provenance == .swiftPMBuild ? "build \(count == 1 ? "it" : "them") with `\(DiscoveredStore.swiftPMBuildCommand(package: package, buildTests: true))`" : "build \(count == 1 ? "its" : "their") target"
            let names = "\(walk.scannedNames) written name\(walk.scannedNames == 1 ? "" : "s")"
            var lines = [
                "",
                "test files without a unit: \(count) test file\(count == 1 ? " has" : "s have") no unit in the store, so it records no reference from \(count == 1 ? "it" : "them") — \(build); until then the tests there were matched by \(names) of the declarations it did answer for, and are marked `name match` below. **A name is not a symbol** — same-named members of unrelated types are included, and dynamically dispatched uses are missed.",
            ]
            if !walk.tooCommon.isEmpty {
                let dropped = walk.tooCommon.sorted()
                lines.append("  \(dropped.count) name\(dropped.count == 1 ? "" : "s") in that scan \(dropped.count == 1 ? "was" : "were") written in more than \(cap) files and dropped, so NOTHING is reported for \(dropped.count == 1 ? "it" : "them"): \(dropped.joined(separator: ", "))")
            }
            lines.append(contentsOf: [walk.setAsideNote()].compactMap(\.self))
            return lines + outside
        }
    }

    /// The same walk over written names, for the declarations the store could not be asked about.
    ///
    /// It honours the same `--depth` as the resolved walk rather than stopping at direct mentions, because the shape it most needs to reach is the same one: a suite that builds its fixture through a test helper mentions the helper and never the changed symbol. Each hop is one pass over the working tree, and a file that never spells any of the names is skipped before it is parsed.
    ///
    /// Given files to record from, it keeps only the tests written in those files, for the test files the store has no unit for; every other declaration a name turns up in is still carried into the next hop, since a helper anywhere is how a test reaches the change.
    ///
    /// `byCallSites` is the after-edit walk: each name is followed to the call sites `where` lists for it rather than to every token spelling it, so a declaration's own name, a same-named parameter or a label is no match. Its `fallbacks` are the types a seed name is followed through instead when the first hop finds no site of it.
    func nameWalk(
        from seeds: [AffectedNameSeed],
        reader: TestSymbolReader,
        depth: Int,
        recordingOnlyIn: Set<String>? = nil,
        excluding: Set<String> = [],
        byCallSites: Bool = false,
        fallbacks: [String: Set<AffectedNameSeed>] = [:]
    ) async throws -> NameWalk {
        guard !seeds.isEmpty, byCallSites ? callSites != nil : mentions != nil else { return NameWalk() }
        // Operators are dropped before the scan rather than after it: `<` is not an identifier token, so it can never match, while its substring pre-filter matches nearly every file in the repository and buys a full parse of all of them for nothing.
        var frontier: [String: Set<String>] = [:]
        // The shape each name's call sites take, which only the call-site scan reads.
        var shapes: [String: CallSiteScanner.SiteShape] = [:]
        for seed in seeds where AffectedNameSeed.isIdentifier(seed.name) {
            frontier[seed.name, default: []].insert(seed.module)
            shapes[seed.name] = seed.shape.widened(by: shapes[seed.name])
        }
        var walk = NameWalk()
        var seen = frontier
        // Names the previous hop admitted through a helper's sites. Their enclosing names are helper routes too, so a name reached through a helper never enters the ordinary cut on any later hop.
        var helperRouted: Set<String> = []
        let fileRows = try store.fileInventory()
        let reach = ModuleReach(files: fileRows.values)

        for hop in 1 ... depth where !frontier.isEmpty {
            var next: [String: Set<String>] = [:]
            var helpers: [String: Set<String>] = [:]
            // Counted here rather than once from the seed set, so the number the answer prints is the names
            // this walk actually carried into a scan — which is the population `tooCommon` is a subset of.
            walk.scannedNames += frontier.count
            var found = await sites(of: Set(frontier.keys), shapes: shapes, byCallSites: byCallSites)
            if hop == 1, !fallbacks.isEmpty {
                let scanned = frontier.count
                let rescan = AffectedAfterEditSeeds.fallingBack(to: fallbacks, found: found, excluding: excluding, frontier: &frontier, shapes: &shapes)
                seen.merge(frontier) { $0.union($1) }
                walk.scannedNames += frontier.count - scanned
                await found.merge(rescan.isEmpty ? [:] : sites(of: rescan, shapes: shapes, byCallSites: byCallSites)) { $1 }
            }
            // Sorted, because the site printed beside a test is whichever account `record` sees first and a
            // Dictionary hands its keys back in hash order. A suite declared in one file and extended in
            // another is the same `TestSymbol` reached from two names with two different sites, so the
            // `— path:line` beside it would flip between runs with the per-process hash seed. The sites
            // inside one name are sorted for exactly the same reason.
            for (name, written) in found.sorted(by: { $0.key < $1.key }) {
                // Another project's files are left out before the cap is counted: they are no part of what the walk reads, as a test or as a hop.
                let sites = written.filter { !excluding.contains($0.path) }
                let declaring = frontier[name] ?? []
                let viaHelper = helperRouted.contains(name)
                // A name written across a large share of the repository has stopped narrowing anything, and admitting its matches turns the fallback into "the whole suite, with a footnote".
                guard Set(sites.map(\.path)).count <= Self.nameEvidenceFileCap else {
                    walk.tooCommon.insert(name)
                    continue
                }
                for site in sites {
                    guard let enclosing = try reader.enclosingSymbol(path: site.path, line: site.line) else { continue }
                    let loadable = fileRows[site.path].map { file in declaring.contains { reach.canLoad($0, from: file.module) } } ?? true
                    let test = try reader.testSymbol(enclosing: enclosing)
                    if let test, recordingOnlyIn?.contains(site.path) ?? true {
                        if loadable {
                            record(test, resolved: false, depth: hop, state: .live, into: &walk.reached)
                        } else {
                            walk.setAside.insert(test.symbol)
                        }
                    }
                    // The same identifier test the seed set is filtered through, and for the same reason the
                    // comment above it gives: a changed type declaring a custom `==` puts `"=="` on the hop-two
                    // frontier, where the visitor can never match it (it compares against `.identifier`) but
                    // its `source.contains("==")` pre-filter matches nearly every Swift file — a full parse of
                    // the repository, every one of them returning nothing.
                    let onward = byCallSites
                        ? try AffectedNameSeed.callSite(of: enclosing, in: store)
                        : AffectedNameSeed(name: enclosing.baseName, module: enclosing.module, kind: enclosing.kind)
                    if loadable, Self.leadsOn(enclosing, from: test), AffectedNameSeed.isIdentifier(onward.name) {
                        shapes[onward.name] = onward.shape.widened(by: shapes[onward.name])
                        if test == nil, !viaHelper {
                            if seen[onward.name, default: []].insert(onward.module).inserted {
                                next[onward.name, default: []].insert(onward.module)
                            }
                        } else if !seen[onward.name, default: []].contains(onward.module) {
                            helpers[onward.name, default: []].insert(onward.module)
                        }
                    }
                }
            }
            // Only when a hop remains to carry them into. Applied on the last hop too, a walk with nowhere
            // left to go would still report "the ones it dropped were not scanned" and a blind spot saying a
            // cap stopped it — over a set the loop discards on the next line — and inflate the count of ways
            // the empty answer cites. At `--depth 1` that would be every run whose first hop widened.
            if hop < depth {
                if next.count > Self.nameFrontierCap {
                    walk.capped = true
                    let kept = Set(next.keys.sorted().prefix(Self.nameFrontierCap))
                    next = next.filter { kept.contains($0.key) }
                }
                // A suite's helper is a route the walk follows beyond what it once did, so its name takes only the room the ordinary names leave under the cap: every name the cut kept before is still kept, and on every later hop the names it reached stay on the helper route (`helperRouted`), so no ordinary name loses its place to one.
                var room = Self.nameFrontierCap - next.count
                var admitted: Set<String> = []
                for (name, modules) in helpers.sorted(by: { $0.key < $1.key }) {
                    let fresh = modules.subtracting(next[name] ?? [])
                    guard !fresh.isEmpty else { continue }
                    if next[name] == nil {
                        guard room > 0 else {
                            walk.capped = true
                            continue
                        }
                        room -= 1
                        admitted.insert(name)
                    }
                    next[name, default: []].formUnion(fresh)
                    seen[name, default: []].formUnion(fresh)
                }
                helperRouted = admitted
            }
            frontier = next
        }
        return walk
    }

    /// The written-name seeds for indexed declarations: each one's base name, as every token spelling it is matched.
    static func mentionSeeds(_ rows: [SymbolRow]) -> [AffectedNameSeed] {
        rows.map { AffectedNameSeed(name: $0.baseName, module: $0.module, kind: $0.kind) }
    }

    /// Where each of `names` is written: every identifier token spelling it, or, for the after-edit walk, the call sites `where` would list for it.
    ///
    /// A function's name written as a member with no call and no labels, `x.f`, is one `where` counts beside its list rather than in it, and the walk leaves it out the same way, as it is far more often another type's property; a call, `T.f`, `x.f(label:)` and a bare `f` handed to a call or bound as a value all stay.
    func sites(of names: Set<String>, shapes: [String: CallSiteScanner.SiteShape], byCallSites: Bool) async -> [String: [NameMention]] {
        guard byCallSites, let callSites else { return await mentions?(names) ?? [:] }
        let found = await callSites(shapes.filter { names.contains($0.key) })
        var sites: [String: [NameMention]] = [:]
        for (name, written) in found {
            let listed = shapes[name] == .callOrReference ? written.filter { !$0.nameOnly || $0.handedOnBare } : written
            sites[name] = listed.map { NameMention(path: $0.path, line: $0.line) }
        }
        return sites
    }

    /// Whether the walk follows a reference onward from the declaration it landed in, given the test that declaration is or sits in.
    ///
    /// Ordinary code always leads on. A test function is a destination: what references it is nothing, or another test. A suite's own helper or property is both: the suite is recorded whole, and the helper is followed too, since a test in another suite that calls it reaches the change through it. The suite's type itself is not followed, so a reference in an inheritance clause names the suite and stops.
    static func leadsOn(_ enclosing: SymbolRow, from test: TestDeclaration?) -> Bool {
        guard let test else { return true }
        return test.symbol.function == nil && !enclosing.kind.isTypeDeclaration && enclosing.kind != .extensionKind
    }

    func record(_ declaration: TestDeclaration, resolved: Bool, depth: Int, state: OccurrenceState, into reached: inout [TestSymbol: Evidence]) {
        let evidence = Evidence(depth: depth, resolved: resolved, state: state, path: declaration.path, line: declaration.line)
        reached[declaration.symbol] = reached[declaration.symbol].map { $0.merged(with: evidence) } ?? evidence
    }

    /// Folds the second walk's findings into the first's, keeping the stronger account of any test both reached.
    func merge(_ other: [TestSymbol: Evidence], into reached: inout [TestSymbol: Evidence]) {
        for (test, evidence) in other {
            reached[test] = reached[test].map { $0.merged(with: evidence) } ?? evidence
        }
    }

    /// Drops every test and suite that a suite the walk also reached as a whole runs — the suite selection already runs them, and listing both spends the per-target cap twice on one fact and counts its tests twice.
    ///
    /// Each folds into the outermost whole suite that runs it, which no other whole suite runs, so the surviving entry keeps the *suite's* declaring site rather than whichever of its members happened to be merged in first.
    func collapsingSuites(_ reached: [TestSymbol: Evidence]) -> [TestSymbol: Evidence] {
        let wholeSuites = reached.keys.filter { $0.function == nil && $0.suite != nil }
        guard !wholeSuites.isEmpty else { return reached }
        var collapsed = reached
        for (test, evidence) in reached {
            let runners = wholeSuites.filter { $0.wholeSuiteRuns(test) }
            guard let outermost = runners.min(by: { ($0.suite?.count ?? 0) < ($1.suite?.count ?? 0) }) else { continue }
            collapsed[test] = nil
            collapsed[outermost] = collapsed[outermost]?.merged(with: evidence) ?? evidence
        }
        return collapsed
    }
}

private extension AffectedRenderer {
    /// Names each reached XCTest test under every case that runs it, as `run`'s inventory declares them — a base's test under each subclass inheriting it, a generic base's under its subclasses alone.
    func namingInheritedTests(_ reached: [TestSymbol: Evidence], in inventory: TestInventory?) -> [TestSymbol: Evidence] {
        guard let inventory else { return reached }
        var named: [TestSymbol: Evidence] = [:]
        for (test, evidence) in reached {
            for runner in Self.runners(of: test, at: evidence, in: inventory) {
                named[runner] = named[runner]?.merged(with: evidence) ?? evidence
            }
        }
        return named
    }

    /// The cases that run one reached test or suite, which is the test itself unless it is an XCTest case with subclasses or generic parameters.
    ///
    /// A test is joined to the inventory by the site of the body that runs, which an inherited declaration keeps, so an override is its own test and not one of the base's. A generic case runs nothing itself, so a test only a generic case declares, in an extension XCTest never discovers, is run by no case at all.
    static func runners(of test: TestSymbol, at evidence: Evidence, in inventory: TestInventory) -> [TestSymbol] {
        guard test.style == .xcTest, let suite = test.suite else { return [test] }
        let key = "\(test.target)/\(suite)"
        let generic = inventory.genericCases.contains(key)
        guard let function = test.function else {
            let subclasses = (inventory.descendants[key] ?? []).map { descendant in
                let parts = descendant.split(separator: "/", maxSplits: 1).map(String.init)
                return TestSymbol(target: parts[0], suite: parts.last, function: nil, style: .xcTest)
            }
            return (generic ? [] : [test]) + subclasses
        }
        let running = inventory.tests.filter {
            $0.style == .xcTest && $0.path == evidence.path && $0.line == evidence.line && $0.function.prefix { $0 != "(" } == function
        }
        guard !running.isEmpty || generic else { return [test] }
        return running.map { TestSymbol(target: $0.target, suite: $0.suite, function: function, style: .xcTest) }
    }
}

extension AffectedRenderer {
    /// The limits block, printed above the list it qualifies: at most two lines, what is specific to this answer.
    ///
    /// The standing list of what the index cannot see is `sift help affected-limits`; `ways` counts it with the answer's own entries, so the empty answer can cite a number a reader can check there.
    func blindSpots(
        runners: AffectedRunners,
        headline: (answeredBy: String, depthLine: String),
        resolution: Resolution,
        excludedByConfig: [String],
        reached: [TestSymbol: Evidence],
        capped: Bool
    ) -> (lines: [String], ways: Int) {
        var entries = [headline.depthLine]
        if !excludedByConfig.isEmpty {
            entries.append(AffectedBlindSpots.excludedByConfig(excludedByConfig, listing: Self.changedFileListCap))
        }
        if !resolution.unreadable.isEmpty {
            entries.append(AffectedBlindSpots.unreadableFiles(resolution.unreadable))
        }
        if !reached.isEmpty, runners.xcodebuild {
            entries.append(AffectedBlindSpots.moduleNameClause)
        }
        if reached.keys.contains(where: \.swiftTestFilterSelectsNothing) {
            entries.append(AffectedBlindSpots.nestedXCTestClause(runners: runners))
        }
        if capped {
            entries.append("a size cap stopped the walk before it finished, so this answer is short of even what the index could have found — the notes above say which cap")
        }
        return (
            [
                "\(AffectedBlindSpots.heading) answered by \(headline.answeredBy). \(AffectedBlindSpots.lowerBoundLine) The standing limits: `sift help affected-limits`.",
                Self.limitBullet + entries.joined(separator: "; "),
            ],
            AffectedBlindSpots.permanent.count + entries.count
        )
    }
}
