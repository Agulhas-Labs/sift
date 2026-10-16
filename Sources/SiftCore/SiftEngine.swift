//
// Copyright © Agulhas Labs
//

import Foundation

/// The facade both front ends drive: opens a repo's index, keeps it fresh, and answers queries.
///
/// Freshness has two independent axes (Docs/Design.md §2): the syntactic index self-heals here — dirty files reparse before any answer, a HEAD move with a clean tree reparses exactly the commit range's diff, and a file *reverted* after a dirty parse is caught by diffing against the previous query's dirty set. Unchanged-content reparses are skipped via size + mtime + content hash, so a standing dirty set costs one stat per file per query, not a parse.
///
/// Concurrency contract: an engine belongs to one owner (the CLI's single task, or one MCP actor) — access is serialized by construction, which is what `@unchecked` asserts. Cross-*process* concurrency is SQLite's job (WAL + busy_timeout, Docs/Design.md §8); sharing one engine across in-process tasks is not supported.
public final class SiftEngine: @unchecked Sendable {
    public let repoRoot: URL
    /// Which checkout this engine answers about, resolved once — it spawns git, the header is built on every query, and a root does not move under an open engine.
    public let tree: WorkingTree
    let store: IndexStore
    private let git: GitContext
    private var config: SiftConfig
    private var configMtime: Double
    private var enumerator: FileEnumerator
    private var resolver: ModuleResolver
    private var indexer: Indexer
    /// mtimes of the resolver's input files (manifests + XcodeGen candidates) as of the last resolver build — statted each query so a mid-session manifest edit rebuilds the resolver without walking the repo.
    private var resolutionStamps: [String: Double]

    private let registry: RootsRegistry?
    /// Parsed catalogs live across the whole engine's lifetime, since the MCP server keeps one engine per root open across a session — repeated `strings` calls in one session reuse the parse rather than repeating it.
    private let stringCatalogCache = StringCatalogCache()
    /// The files this engine's digests found stale and reparsed (or could not) since the last ``ensureFresh()``, for a face whose header is framed after several digests have read, not after the one that reparsed (``framing(_:)``).
    private var servedReparses = ServedReparses()
    /// Whether the index is in memory because the caller asked for no file to be touched (``init(directory:registry:storesNothing:)``), not because the tree cannot be written.
    private let storesNothing: Bool

    /// Opens (or creates) the index for `root`, which git has already named as a work tree's top level, holding it in memory where the tree cannot be written (``IndexLocation``) or where `storesNothing` asks for it; the public doors are in the extension that follows the class.
    private init(discoveredRoot root: URL, registry: RootsRegistry?, storesNothing: Bool) throws {
        self.registry = registry
        self.storesNothing = storesNothing
        registry?.record(root.path)
        repoRoot = root
        // Asked once: the tree's name and the cache exclusion below both read the common directory.
        let gitDirectories = GitContext.directories(of: root)
        tree = WorkingTree.describing(root, directories: gitDirectories)
        let gitContext = GitContext(repoRoot: root)
        git = gitContext
        config = try SiftConfig.load(repoRoot: root)
        configMtime = Self.mtime(of: ConfigFile.url(repoRoot: root))
        store = try IndexStore(databasePath: storesNothing ? IndexLocation.memory.databasePath : IndexLocation.resolve(databasePath: Self.indexPath(in: root)).databasePath)
        enumerator = FileEnumerator(repoRoot: root, config: config, gitListing: { try gitContext.visibleSwiftFiles() }, markdownListing: { try gitContext.visibleMarkdownFiles() })
        resolver = ModuleResolver(repoRoot: root, config: config)
        indexer = Indexer(repoRoot: root, store: store, enumerator: enumerator, resolver: resolver)
        resolutionStamps = Self.stamps(of: resolver.inputPaths + resolver.watchedDirectories, under: root)
        if !storesNothing {
            git.ensureCacheExcluded(inCommonDirectory: gitDirectories?.common)
        }
    }

    /// Whether this engine's database file is still the one it opened.
    ///
    /// `false` once that file has been deleted or replaced underneath a long-lived process, which no amount of reindexing can recover from — the owner's move is to discard the engine and open a fresh one, not to report the failure.
    public var isUsable: Bool {
        store.isBackingFileIntact
    }

    // MARK: Freshness

    /// Brings the index up to date with the working tree and returns the header for this response.
    @discardableResult
    public func ensureFresh() async throws -> Freshness {
        servedReparses = ServedReparses()
        reloadConfigIfChanged()
        let head = try git.head() ?? Freshness.unbornHead
        let indexedHead = try store.metaValue("indexed_head")
        let dirty = try git.dirtySwiftFiles()
        rebuildResolverIfInputsChanged(dirty: dirty)
        let currentDirtyPaths = Set(dirty.compactMap { change -> String? in
            switch change.kind {
            case .addedOrModified, .renamed: change.path
            case .deleted: nil
            }
        })

        if try store.counts().files == 0 || indexedHead == nil {
            // Resuming: rows a killed or cancelled build stored are kept where their files still match them, so
            // successive attempts converge on a build none of them could finish alone (Docs/Design.md §6.9).
            try await indexer.fullIndex(storeBuiltAt: storeBuiltAt, resuming: true)
            try store.setMetaValue(currentDirtyPaths.sorted().joined(separator: "\n"), forKey: "last_dirty")
            try indexer.markBuilt(atHead: head)
            return try freshness(head: head, dirtyCount: dirty.count)
        }

        // Before anything below can drop a row: a store written before the deletion ledger existed is never
        // rebuilt, so a full index is not the only place a store can first be seen without one.
        try indexer.seedDeletionLedgerIfAbsent(storeBuiltAt: storeBuiltAt)
        try await reattributeIfResolutionChanged()

        var toReindex: Set<String> = []
        var toDelete: Set<String> = []
        try apply(changes: dirty, reindex: &toReindex, delete: &toDelete)

        if let indexedHead, indexedHead != head {
            if let rangeChanges = try? git.changedSwiftFiles(from: indexedHead, to: head) {
                try apply(changes: rangeChanges, reindex: &toReindex, delete: &toDelete)
            } else {
                // The recorded head no longer resolves (rebase, history rewrite, first commit after unborn) — converge via reconcile.
                try await indexer.reconcile()
            }
        }

        // A file that was dirty on the previous query but is dirty no longer was either committed or reverted — its indexed rows came from the dirty parse, so re-check it against disk (the hash skip below makes the committed case one stat + hash, not a parse).
        let previousDirty = try Set((store.metaValue("last_dirty") ?? "").split(separator: "\n").map(String.init))
        for settled in previousDirty.subtracting(currentDirtyPaths).subtracting(toDelete) where enumerator.isIndexable(relativePath: settled) {
            toReindex.insert(settled)
        }

        var confirmedReindex: [String] = []
        for path in toReindex.sorted() {
            switch try indexer.reparseNeed(of: path, row: store.fileRow(path: path)) {
            case .reparse: confirmedReindex.append(path)
            case .missing: toDelete.insert(path)
            case .unchanged: break
            }
        }

        try store.deleteFiles(paths: Array(toDelete).sorted(), stillOnDisk: indexer.stillOnDisk)
        try await indexer.indexPaths(confirmedReindex)
        try store.setMetaValue(head, forKey: "indexed_head")
        try store.setMetaValue(currentDirtyPaths.sorted().joined(separator: "\n"), forKey: "last_dirty")

        if !confirmedReindex.isEmpty || !toDelete.isEmpty {
            try await bumpReconcileCounter()
        }
        return try freshness(head: head, dirtyCount: dirty.count)
    }

    private func apply(changes: [GitContext.Change], reindex: inout Set<String>, delete: inout Set<String>) throws {
        for change in changes {
            switch change.kind {
            case .addedOrModified:
                if enumerator.isIndexable(relativePath: change.path) {
                    reindex.insert(change.path)
                } else if try store.fileRow(path: change.path) != nil {
                    // Changed into a path the index no longer covers — a file replaced by a symbolic link — so the rows from before it changed go.
                    delete.insert(change.path)
                }
            case .deleted:
                delete.insert(change.path)
            case let .renamed(from):
                delete.insert(from)
                if enumerator.isIndexable(relativePath: change.path) {
                    reindex.insert(change.path)
                }
            }
        }
    }

    /// Picks up config edits mid-session (the MCP server is long-lived; a config is edited by hand, or by `init --write` through the CLI).
    ///
    /// The file watched here has to be the file ``SiftConfig/load(repoRoot:)`` reads, and both go through ``ConfigFile/url(repoRoot:)`` to be sure of it. Two spellings of the same path drift the moment one of them changes, and the failure is silent: a stamp taken against one file and compared against another pins at its first value, after which no edit to the config actually in use is ever noticed again.
    private func reloadConfigIfChanged() {
        let configURL = ConfigFile.url(repoRoot: repoRoot)
        let current = Self.mtime(of: configURL)
        guard current != configMtime else { return }
        configMtime = current
        guard let reloaded = try? SiftConfig.load(repoRoot: repoRoot) else { return }
        config = reloaded
        let gitContext = git
        enumerator = FileEnumerator(repoRoot: repoRoot, config: config, gitListing: { try gitContext.visibleSwiftFiles() }, markdownListing: { try gitContext.visibleMarkdownFiles() })
        resolver = ModuleResolver(repoRoot: repoRoot, config: config)
        indexer = Indexer(repoRoot: repoRoot, store: store, enumerator: enumerator, resolver: resolver)
        resolutionStamps = Self.stamps(of: resolver.inputPaths + resolver.watchedDirectories, under: repoRoot)
        probedStore = nil
    }

    /// Rebuilds the resolver when a resolution input changed on disk mid-session — a stamped input whose mtime moved, or a manifest in the dirty set the stamps have never seen.
    ///
    /// A spec *appearing* is caught by the directory stamps rather than by the dirty set: `GitContext.dirtySwiftFiles()` runs with a `-- '*.swift'` pathspec, so no `.yml` path can ever reach here. Testing the dirty set for a spec name would therefore be dead code; `isManifestPath` works only because `Package.swift` ends in `.swift`. Stamping each discovered spec's parent directory closes the common case honestly, since adding or removing an entry moves a directory's mtime, and anything past that waits for the next engine open.
    private func rebuildResolverIfInputsChanged(dirty: [GitContext.Change]) {
        let newManifest = dirty.contains { change in
            SwiftPMManifest.isManifestPath(change.path) && resolutionStamps[change.path] == nil
        }
        let moved = resolutionStamps.contains { path, mtime in
            Self.mtime(of: repoRoot.appendingPathComponent(path)) != mtime
        }
        guard newManifest || moved else { return }
        resolver = ModuleResolver(repoRoot: repoRoot, config: config)
        indexer = Indexer(repoRoot: repoRoot, store: store, enumerator: enumerator, resolver: resolver)
        resolutionStamps = Self.stamps(of: resolver.inputPaths + resolver.watchedDirectories, under: repoRoot)
    }

    /// Re-attributes every stored file's module when the resolution fingerprint moved — an upgraded binary, an edited manifest, a changed `moduleMap`.
    ///
    /// Content-keyed invalidation can never catch these: the inputs live outside every source file, so without this an upgrade would leave wrong modules in place forever with no signal short of `reset`. Reconcile runs first so rows the enumerator no longer lists (build manifests above all) leave before re-attribution; the recompute itself is path→module only, no reparse, so running it unconditionally on mismatch is cheap.
    private func reattributeIfResolutionChanged() async throws {
        let fingerprint = resolver.fingerprint
        guard try store.metaValue("resolution_fingerprint") != fingerprint else { return }
        try await indexer.reconcile()
        _ = try store.reattributeModules { [resolver] path in
            (resolver.module(for: path), resolver.resolvedModule(for: path) == nil)
        }
        try store.setMetaValue(fingerprint, forKey: "resolution_fingerprint")
    }

    /// Mtimes for every resolution input and every directory the build-file walk entered.
    ///
    /// The directories are what notice a build file being *added*: a spec appearing where none existed is a path nothing has stamped, and only its parent directory's mtime moving reveals it. Stamping the repository root alone is not enough — `Apps/project.yml` appearing would leave a running server guessing for the rest of the session.
    private static func stamps(of paths: [String], under root: URL) -> [String: Double] {
        var stamps: [String: Double] = [:]
        for path in paths {
            stamps[path] = mtime(of: root.appendingPathComponent(path))
        }
        stamps[""] = mtime(of: root)
        return stamps
    }

    /// A file's mtime, via `stat` rather than `attributesOfItem` — this runs across the whole stamp map on every query, and the dictionary-building form measured ~20x the cost.
    private static func mtime(of url: URL) -> Double {
        var info = stat()
        guard stat(url.path, &info) == 0 else { return 0 }
        return Double(info.st_mtimespec.tv_sec) + Double(info.st_mtimespec.tv_nsec) / 1_000_000_000
    }

    /// Every 20th incremental update runs the reconcile backstop (Docs/Design.md §6.4).
    private func bumpReconcileCounter() async throws {
        let count = try Int(store.metaValue("incremental_count") ?? "0") ?? 0
        let next = count + 1
        try store.setMetaValue(String(next), forKey: "incremental_count")
        if next % 20 == 0 {
            try await indexer.reconcile()
        }
    }

    private func freshness(head: String, dirtyCount: Int) throws -> Freshness {
        let counts = try store.counts()
        return Freshness(
            tree: tree,
            headShort: String(head.prefix(7)),
            dirtyCount: dirtyCount,
            parseErrorFiles: counts.parseErrorFiles
        )
    }

    // MARK: Commands

    /// Rebuilds the index from scratch; returns the number of files indexed.
    @discardableResult
    public func fullIndex() async throws -> Int {
        let indexed = try await indexer.fullIndex(storeBuiltAt: storeBuiltAt)
        try indexer.markBuilt(atHead: git.head() ?? Freshness.unbornHead)
        return indexed
    }

    /// Runs the reconcile sweep; returns what it had to fix (zero/zero on a converged index).
    public func reconcile() async throws -> (removed: Int, reindexed: Int) {
        try indexer.seedDeletionLedgerIfAbsent(storeBuiltAt: storeBuiltAt)
        return try await indexer.reconcile()
    }

    /// Deletes the whole `.sift/` directory and reports the repository root it looked in and which directory it removed, `nil` when there was none: the index and the semantic cache, which the next query rebuilds, and the run transcripts under `runs/`, which are receipts and are not rebuilt (Docs/Design.md §6.6).
    ///
    /// Throws when the cache exists but cannot be removed, so "removed" is never printed over a failure.
    ///
    /// **Refuses while `.sift/` holds a set-aside record**, which is the one thing in it that is neither a cache nor a receipt: it is the only copy of changes `run --without` took out of the tree, and deleting it would delete them. The refusal names `sift run --restore`, the same as `run`'s. **And while a `run --without` holds the set-aside lock** — its second pass included, when no record stands — in the words a busy run is refused in: deleting the lock with the rest would let a second run set the tree aside under the first. The deletion itself holds that lock, so no run can start under it.
    @discardableResult
    public static func reset(directory: URL) throws -> (root: URL, removed: String?) {
        guard let root = GitContext.discoverRoot(from: directory) else {
            throw EngineError.notAGitRepository(directory.path)
        }
        let cache = SiftPaths.cache(in: root)
        guard PathKind.of(cache) != .absent else { return (root, nil) }
        try SetAsideSession.clearCache(in: root)
        return (root, cache.lastPathComponent)
    }

    // MARK: Queries

    public func digest(target: String, options: DigestOptions) throws -> String {
        try measuredDigest(target: target, options: options).text
    }

    /// The same digest, carrying what it measured itself against — the bytes served and the bytes of source they stand in for, where the renderer counted both.
    ///
    /// For the face that logs the call: an answer's saving is only knowable at the moment it is built, and this is how it leaves the engine instead of being discarded there.
    public func measuredDigest(target: String, options: DigestOptions) throws -> MeasuredAnswer {
        try notingMemoryIndex(checkedDigest { try $0.measured(target: target, options: options) })
    }

    /// For each of `ranges` in the file at `path`, the file digest's lines for the members the range overlaps, or `nil` where the index holds no file there.
    public func membersAnswers(overlapping ranges: [ClosedRange<Int>], inFile path: String, options: DigestOptions) throws -> [String]? {
        try WindowMembersAnswer(renderer: makeDigestRenderer()).answers(overlapping: ranges, inFile: path, options: options)
    }

    /// Whether every line of `range` in the file at `path` lies in the doc comment directly above one of its declarations, or `false` where the index holds no file there.
    public func liesInLeadingDocComment(_ range: ClosedRange<Int>, inFile path: String) throws -> Bool {
        try WindowMembersAnswer(renderer: makeDigestRenderer()).liesInLeadingDocComment(range, inFile: path)
    }

    /// Whether the members answer for `range` in the file at `path` would name exactly one member beneath the headers of the containers enclosing it, and nothing else — no view outline among them — or `false` where the index holds no file there.
    public func namesOneMember(_ range: ClosedRange<Int>, inFile path: String, options: DigestOptions) throws -> Bool {
        try WindowMembersAnswer(renderer: makeDigestRenderer()).namesOneMember(range, inFile: path, options: options)
    }

    /// The other registered roots whose *existing* index accounts for `target` — the cross-root pointer's data, declaring roots ahead of extension-only ones.
    ///
    /// Consulted only on a miss, and strictly read-only per root: a root that was recorded but never indexed is skipped, never indexed as a side effect of this repo's miss.
    ///
    /// A dotted target is checked as a *path*, and only as a path. Checking its last component and printing the whole target is a claim about something never asked — the shape that answered `Type.column` with three repositories whose only connection to it was a symbol called `column`. An extension-only pointer stays a bare-name answer for the same reason: extending a type is evidence about the type, and says nothing about a member path through it.
    private func siblingPointers(target: String) -> [SiblingPointer] {
        guard let registry else { return [] }
        let own = repoRoot.standardizedFileURL.path
        // Scoped to this one call: `own` and every root this call asks about are resolved at most once each while an answer for it is known, whether the question is "is it own's repository" or "which repository is it, once collapsed" — a failed resolution is retried, and nothing here survives to answer a later call, so a root that changes identity between misses is asked about fresh.
        let identities = RepositoryIdentity.CallMemo()
        // A worktree of this very repository is not a sibling: pointing at it would answer a miss with the same code the miss came from.
        let others = registry.knownRoots()
            .filter { $0 != own }
            .filter { !RepositoryIdentity.sameRepository($0, own, memo: identities) }
        guard QualifiedPath.components(of: target).count == 1 else {
            let declaringPath = others.filter { SiblingIndexProbe.declares(path: target, atRoot: $0) }
            return RepositoryIdentity.collapsingWorktrees(of: declaringPath, memo: identities).map { SiblingPointer(root: $0, declares: true) }
        }
        let name = QualifiedPath.baseName(of: target)
        let declaring = others.filter { SiblingIndexProbe.declares(name: name, atRoot: $0) }
        let declared = Set(declaring)
        let extending = others.filter { !declared.contains($0) && SiblingIndexProbe.extends(name: name, atRoot: $0) }
        return RepositoryIdentity.collapsingWorktrees(of: declaring, memo: identities).map { SiblingPointer(root: $0, declares: true) }
            + RepositoryIdentity.collapsingWorktrees(of: extending, memo: identities).map { SiblingPointer(root: $0, declares: false) }
    }

    /// Resolves a symbol; with `options.includeSemantic`, callers/overrides/store-conformers join via the lazily opened index store, and the returned text INCLUDES the freshness header (the semantic axis is only known after the query ran).
    ///
    /// The renderer is handed a working-tree call-site scanner for the symbols semantics cannot answer for. It runs at most once per query — the renderer batches every unanswered name into a single scan — and only when something actually went unanswered or an initializer of a property wrapper was asked, whose `@T` sites the store may not record, so any other fully resolved query never pays for it.
    public func lookup(symbol: String, freshness: Freshness, options: WhereOptions = WhereOptions()) async throws -> String {
        let scanner = CallSiteScanner(repoRoot: repoRoot, enumerator: enumerator)
        var renderer = WhereRenderer(store: store, callSites: { await scanner.callSites(named: $0) })
        renderer.expandsAtFileScope = { [repoRoot, enumerator] in await BareNameOutsideTypes.expandsAtFileScope(paths: enumerator.swiftFiles(), under: repoRoot) }
        renderer.siblingRoots = { [weak self] target in self?.siblingPointers(target: target) ?? [] }
        let owner = XcodeProjectOwner(repoRoot: repoRoot)
        renderer.projectOwner = { owner.hint(forFileAt: $0) }
        renderer.takeModuleFacts(from: resolver)
        renderer.declarationSource = { [repoRoot] row in
            guard case let .lines(lines, _) = SourceSlicer.slice(of: row, under: repoRoot) else { return nil }
            return lines
        }
        renderer.fileSource = { [repoRoot] path in try? String(contentsOf: repoRoot.appendingPathComponent(path), encoding: .utf8) }
        renderer.readsWorkingTree(under: repoRoot, enumerator: enumerator, bounds: textSearchBounds)
        // `--decl` never opens or asks the store, so its header is the syntactic one and carries no `semantic:` field.
        let input: SemanticInput = options.includeSemantic && !options.declarationsOnly ? whereSemanticInput() : .inactive(note: "semantic disabled (--syntactic)")
        let output = try await renderer.render(query: symbol, semantic: input, options: options)
        var updated = freshness
        updated.semantic = output.axis
        let header = options.declarationsOnly ? freshness.syntacticHeaderLine : updated.headerLine
        return Freshness.placing([memoryIndexNote], under: header + "\n" + output.body)
    }

    /// Which tests reference the symbols a diff changed, with the arguments a runner selects them by — and never a decision about what to run.
    ///
    /// The change set comes from `GitContext`, not from a third git runner: the dirty set for the working tree, `git diff --name-status` for a range. Both already honour renames and deletes and both already read their pipes without deadlocking, which is the whole reason this reaches for them rather than shelling out again.
    ///
    /// Like `lookup`, the returned text INCLUDES the freshness header, because the semantic axis is only known after the query has run.
    public func affected(options: AffectedOptions, freshness: Freshness) async throws -> String {
        // Filtered through the same rule the indexer applies, so a path the tool would never index is not part of this question at all — a generated `.build` source is neither a changed file nor an honest gap, it is out of scope. What survives the filter and still has no rows is the gap the answer must name.
        //
        // The filter's *other* half is not out of scope, and must not be dropped just as quietly: `exclude`
        // and `roots` are this repository's own narrowing, so on a two-surface product configured
        // `roots: ["app"]` every edit under `web/` would leave an answer reading "nothing changed — no .swift
        // file differs", which is a statement about the working tree and a false one. Those paths are counted
        // here and named in the answer's blind-spot block instead.
        let diff = try options.range.map { try git.changedSwiftFiles(from: $0.from, to: $0.to) } ?? git.dirtySwiftFiles()
        // A range reads each path's link mode from its two revisions, which the working tree says nothing about.
        let links = try options.range.flatMap { diff.isEmpty ? nil : try RangeLinks(from: $0.from, to: .revision($0.to), git: git) }
        let changes = links.map { $0.kept(diff, enumerator: enumerator) } ?? diff.filter { enumerator.isIndexable(relativePath: $0.path) }
        let excludedByConfig = diff.filter { enumerator.isNarrowedAwayByConfig(relativePath: $0.path) }.map(\.path)
        var renderer = AffectedRenderer(store: store, repositoryRoot: repoRoot, projectDirectories: resolver.projectDirectories)
        renderer.readingWorkingTree(enumerator: enumerator, git: git, changes: changes, range: options.range)
        let output = try await renderer.render(
            changes: changes,
            excludedByConfig: excludedByConfig,
            semantic: semanticInput(),
            options: options
        )
        var updated = freshness
        updated.semantic = output.axis
        return try updated.headerLine + "\n" + options.uncommittedNote(git: git, enumerator: enumerator) + output.body
    }

    /// The suites that reference the type or top-level function `name` declares, for the line `sift run` adds under a refused `--filter`; `nil` where the index declares no such thing or no test reaches it.
    ///
    /// The walk is `affected`'s, at its own depth and seeded from the declarations rather than from a diff: the semantic store's references where the store opens within the engine's budget, written names where it does not.
    func filterHint(named name: String) async throws -> UnmatchedFilterHint? {
        let declared = try store.typeDeclarations(named: name) + store.symbols(named: name).filter { $0.kind == .function && $0.parentID == nil }
        guard !declared.isEmpty else { return nil }
        let scanner = NameMentionScanner(repoRoot: repoRoot, enumerator: enumerator)
        var renderer = AffectedRenderer(store: store, repositoryRoot: repoRoot, projectDirectories: resolver.projectDirectories)
        renderer.mentions = { await scanner.mentions(of: $0) }
        let reached = try await renderer.suitesReaching(declared, semantic: semanticInput(), depth: AffectedOptions.defaultDepth)
        guard !reached.isEmpty else { return nil }
        return UnmatchedFilterHint(name: name, declaredIn: Set(declared.map(\.path)).sorted(), suites: reached.map(\.filter), direct: reached.prefix { $0.depth == 1 }.count)
    }

    /// How many tests are *supposed* to run: the declared inventory joined to the test plans, and the gaps between the two.
    ///
    /// Only the declared side comes from stored rows, which is what the header measures. The plans and the schemes are read live off disk on every call rather than indexed — small JSON and small XML, so a file edited a minute ago is answered on and there is nothing stored for either to go stale.
    ///
    /// Like `affected`, the returned text INCLUDES the freshness header, so a front end has one string to place its own notes under.
    public func analyseTests(plan: String?, freshness: Freshness) throws -> String {
        let inventory = try TestInventory.read(store: store, repositoryRoot: repoRoot)
        let survey = try TestPlanDiscovery.plans(under: repoRoot)
        let schemes = try SchemeDiscovery.schemes(under: repoRoot)
        let analysis = try TestAnalysis.of(inventory: inventory, survey: survey, schemes: schemes, plan: plan)
        return freshness.headerLine + "\n" + TestAnalysisRenderer().render(analysis)
    }

    /// What a run *did*, set against what the index says was supposed to run: the same question `--analyse` answers statically, closed at the other end.
    ///
    /// A runner's own tally counts whatever reported, so a process that dies part-way takes the tests that never started out of the arithmetic and the summary can read green over a suite half of which never executed. Only the static side holds the other number.
    ///
    /// The reading and the scoping are ``RunReconciliationReader``'s, its own type for the reason `DiffGatherer` and `WhereRenderer` are theirs. Returns the answer with the freshness header on it, and the verdict, which is the caller's exit code.
    public func reconcileTests(against logURL: URL, freshness: Freshness) throws -> (answer: String, isGreen: Bool) {
        let reader = RunReconciliationReader(store: store, repositoryRoot: repoRoot)
        let reconciliation = try reader.reconcile(against: logURL)
        return (freshness.headerLine + "\n" + RunReconciliationRenderer().render(reconciliation), reconciliation.isGreen)
    }

    /// The same join over outcomes a wrapped run has already parsed, for `sift run` to note under its answer; `logURL` only names the run, `packageDirectory` is the repository-relative directory of the package it tested (empty for the root), and `executedNothing` says its closing counts showed a run of no test, which reconciles as zero reported.
    public func reconcileRun(_ outcomes: RunTestOutcomes, loggedAt logURL: URL?, packageDirectory: String = "", executedNothing: Bool = false) throws -> RunReconciliation {
        try RunReconciliationReader(store: store, repositoryRoot: repoRoot, packageDirectory: packageDirectory).reconcile(outcomes, loggedAt: logURL, executedNothing: executedNothing)
    }

    /// A structural digest of a change for review: which declarations a range added, removed, or changed, who calls the changed ones, and everything else it touched.
    ///
    /// The gathering itself is `DiffGatherer`'s (its own type, for the same reason `AffectedRenderer`/`WhereRenderer` are their own types rather than more of this file). `notes` go under the header here rather than in the front end, because the size line prices the whole answer and they are part of it.
    public func diff(options: DiffOptions, freshness: Freshness, notes: [String?] = []) async throws -> String {
        let gatherer = DiffGatherer(git: git, enumerator: enumerator, store: store, repoRoot: repoRoot, projectDirectories: resolver.projectDirectories)
        let output = try await gatherer.diff(options: options, semantic: semanticInput())
        return DiffRenderer.answer(output, freshness: freshness, notes: notes)
    }

    // MARK: Semantic store (lazy — never opened for syntactic queries, Docs/Design.md §2)

    var probedStore: DiscoveredStore??
    private var openedSemanticStore: SemanticStore?
    /// The last open that failed, remembered so the next query does not pay for it again — for that store only, since another store is another open.
    private var semanticFailure: SemanticFailure?
    private var semanticOpener = BudgetedOpen<SemanticStore>()
    /// The in-tree stores `where` reads beside the primary, and the walk that found them.
    private(set) var inTree = InTreeStoreSet()

    /// How long a query waits for a cold index-store open before answering without it.
    ///
    /// Set from both ends. Above it, a warm-cache reopen and an ordinary single-app cold open (a few seconds) still land inside the call, so the common case is unchanged. Below it, the cost of guessing wrong is one retry a few seconds later against a store that is by then warm — where the cost of no budget at all can be a 95-second call that reads as a hang.
    ///
    /// Not tuned finer than that on purpose: the tail it exists to cut is two orders of magnitude away from the threshold. Anywhere in single-digit seconds does the same job.
    static let semanticOpenBudget: TimeInterval = 5

    /// This engine's budget: the one above everywhere but a test, which sets zero to hold a real open in its warming state — deterministically, since the open cannot settle while the budget check holds its lock.
    var openBudget = SiftEngine.semanticOpenBudget

    /// How far the conformers block's text search may read before its line is left out: the scan's own bounds everywhere but a test, which narrows them or steps their clock.
    var textSearchBounds = TextSearchFiles.Bounds()

    /// Runs on the opening thread as each open of the store succeeds, before the engine reads what it opened.
    ///
    /// A test's way of replacing the store in the moment a rebuild during a cold import would, which no real build can be timed to hit. Nothing everywhere else.
    var afterSemanticOpen: @Sendable () -> Void = {}

    /// Runs on the opening thread once the store's cache is ready, before the store is read.
    ///
    /// A test's way of replacing the store as a rebuild landing at the start of a cold import would, so that the open fills the cache named for one store with another's units. Nothing everywhere else.
    var beforeSemanticRead: @Sendable () -> Void = {}

    /// Discovery without opening — cheap filesystem probing, cached for status; the semantic path re-probes every query.
    private func probeStore() -> DiscoveredStore? {
        if let probed = probedStore {
            return probed
        }
        let discovered = storeDiscovery().discover()
        probedStore = .some(discovered)
        return discovered
    }

    /// Re-probes and re-anchors on every semantic query, so "build the project, then retry" actually works: a store appearing, or new units landing after a build, reopens the layer instead of serving a frozen answer for the engine's lifetime.
    private func semanticInput() -> SemanticInput {
        semanticInput(budget: openBudget)
    }

    /// The same, waiting at most `budget` for an open to finish.
    ///
    /// Asked again with what is left of it when the store is replaced during the open, so a query that has to open the store there now still waits no longer than one budget in all — past it, that open goes on in the background and the answer says warming, which is then true.
    private func semanticInput(budget: TimeInterval) -> SemanticInput {
        let started = Date()
        let discovery = storeDiscovery()
        let discovered = discovery.discover()
        probedStore = .some(discovered)
        // A store with no cache to name is one whose units directory went between discovery and now, and "no store" is
        // what is true this instant.
        guard let discovered, let cache = SemanticCache(store: discovered.path, in: SiftPaths.cache(in: repoRoot)) else {
            openedSemanticStore = nil
            return .unavailable(note: Self.noStoreNote(for: tree, rejected: discovery.rejectedSettings(), root: repoRoot))
        }
        let rejected = discovery.rejectedSettings()
        let anchor = IndexStoreDiscovery.newestUnitDate(in: discovered.path) ?? .distantPast
        // Reused only while discovery yields the same cache, which names the store's directory as well as its path: a
        // store deleted and rebuilt at one path is another store, even when its newest unit is no newer.
        if let opened = openedSemanticStore, opened.cache == cache, opened.newestUnitDate >= anchor {
            return .active(SemanticContext(store: opened, repoRoot: repoRoot, rejectedSettings: rejected, outsideNote: outsideNote(of: discovered, rejected: rejected)))
        }
        if let failure = semanticFailure, failure.cache == cache, failure.anchor >= anchor {
            return .openFailed(note: failure.note)
        }
        let afterOpen = afterSemanticOpen
        let beforeRead = beforeSemanticRead
        let root = repoRoot
        let key = BudgetedOpen<SemanticStore>.Key(path: cache.directory.path, anchor: anchor)
        let outcome = semanticOpener.open(key: key, budget: budget) {
            let opened = try SemanticStore(discovered: discovered, repoRoot: root, newestUnitDate: anchor, cache: cache, beforeRead: beforeRead)
            afterOpen()
            return opened
        }

        switch outcome {
        case let .warming(seconds):
            // Deliberately not recorded as a failure. A failure is cached against the anchor so the next
            // query does not pay for it again, which is exactly the wrong treatment here: the open is still
            // running, and the whole point is that the query after this one finds it finished.
            return .warming(note: Self.warmingNote(provenance: discovered.provenance, seconds: seconds))
        case _ where SemanticCache(store: discovered.path, in: SiftPaths.cache(in: repoRoot)) != cache:
            // The cache was named before the open, and IndexStoreDB reads the store during it: a store replaced in
            // between — `rm -rf .build` and a build landing in a cold import — fills the cache named for the old
            // store with the new one's units beside its own, and the open discards that cache itself
            // (``SemanticStore``). One replaced after the read leaves the open the old store's units alone. Either
            // way what that open produced is never answered from, and how it ended is not remembered, since neither
            // belongs to the store there now: that store is opened instead. An open that overran the budget and
            // lands later is never read at all, because every query after it names the new cache.
            return semanticInput(budget: max(0, budget - Date().timeIntervalSince(started)))
        case let .failed(error) where error is SemanticStore.ReplacedWhileRead:
            // The store this open read was replaced while it read, and is back now: moved away and back, its key
            // with it. The open discarded its cache, and how it ended is no failure of this store, which is opened
            // afresh rather than refused until the next build.
            semanticOpener.forget(key)
            return semanticInput(budget: max(0, budget - Date().timeIntervalSince(started)))
        case let .opened(opened):
            openedSemanticStore = opened
            semanticFailure = nil
            return .active(SemanticContext(store: opened, repoRoot: repoRoot, rejectedSettings: rejected, outsideNote: outsideNote(of: discovered, rejected: rejected)))
        case let .failed(error):
            let note = "index store found (\(discovered.label)) but failed to open: \(SemanticOpenFailure.cause(of: error))"
            semanticFailure = SemanticFailure(note: note, cache: cache, anchor: anchor)
            return .openFailed(note: note)
        }
    }

    /// The semantic axis a query in this tree would see right now, judged from discovery and file state alone — never by opening the index store.
    ///
    /// A doctor command cannot pay the cost a real open can carry: on a store another process already holds warm, opening it here means ingesting it again from cold, which is exactly the ingestion the freshness contract exists to avoid paying twice (Docs/Design.md §2). So this runs the two comparisons a resolved query runs per cited file, over every file at once, since a report naming no declaration has no smaller set to check: a stored file's own change moment (``FileChangeStat``), refreshed by `ensureFresh` whenever the working tree edits it, against the store's build anchor (`SemanticContext.buildAnchor(newestUnit:)`, which a query measures only a file with no unit of its own against, so a file a partial build skipped shows only on a query); and a file gone from the tree, which here means one the ``DeletionLedger`` names — dropped by this index, or seeded from what git still recorded when the store had no ledger — that is still missing and that the store may still cite: dated after that anchor, or named by a unit still on disk (``StoreUnitMentions``), since a build keeps a deleted file's unit until a clean build and a query goes on citing it whichever came first, the deletion or the build. Both are worded as what file state showed (`SemanticAxis.staleByFileState`). `unresolved` is a per-declaration fact a resolved query computes from refusals no report without a declaration can have (`SemanticAxis.of(refusals:occurrences:)`), and whether the store opens at all, or is still reading past a query's budget, only a real open can tell — all three are left unclaimed rather than guessed, and the note beside the store line names the help topic that says so (``statusAxisNote``).
    ///
    /// `unitKeepsADeletedFile` says whether a unit on disk names one of the deleted files counted, the one case the store's record was read for; a file counted on the ledger's date alone was never checked against the record.
    private func statusAxis(discovered: DiscoveredStore?) throws -> (semantic: SemanticAxis, unitKeepsADeletedFile: Bool) {
        guard let discovered else { return (.noStoreInStatus, false) }
        let newestUnit = Self.newestUnit(of: discovered) ?? .distantPast
        let buildAnchor = SemanticContext.buildAnchor(newestUnit: newestUnit)
        let newerFiles = try store.fileInventory().values.filter { $0.mtime > buildAnchor }.map(\.path)
        let deleted = try Self.deletedFilesTheStoreMayCite(ledger: store.deletionLedger(), anchor: buildAnchor, in: discovered, root: repoRoot)
        guard !newerFiles.isEmpty || !deleted.paths.isEmpty else { return (.fresh, false) }
        let files = StaleFiles(changed: newerFiles.count, deleted: deleted.paths.count, path: newerFiles.first ?? deleted.paths.first)
        return (.staleByFileState(files), deleted.namedByAUnit)
    }

    /// The status/doctor report: freshness, counts, size, modules, config presence.
    public func statusText(freshness: Freshness) throws -> String {
        var freshness = freshness
        let discovered = probeStore()
        let axis = try statusAxis(discovered: discovered)
        freshness.semantic = axis.semantic
        let counts = try store.counts()
        let modules = try store.moduleNames()
        let size = store.isInMemory ? "in memory (this tree cannot be written)" : String(format: "%.1f MB", Double(store.databaseSizeBytes) / 1_048_576)
        var lines: [String] = [freshness.headerLine]
        lines.append("root: \(repoRoot.path)")
        lines.append("files: \(counts.files)  symbols: \(counts.symbols)  db: \(size)")
        lines.append("modules (\(modules.count)): \(modules.joined(separator: " "))")
        let configPath = repoRoot.appendingPathComponent(".sift.json").path
        let hasConfig = FileManager.default.fileExists(atPath: configPath)
        lines.append("config: \(hasConfig ? ".sift.json" : "none (defaults)")")
        let rejected = storeDiscovery().rejectedSettings()
        lines.append(Self.storeStatusLine(discovered: discovered, rejected: rejected))
        lines.append(contentsOf: Self.statusAxisLines(discovered: discovered, unitKeepsADeletedFile: axis.unitKeepsADeletedFile))
        try lines.append(contentsOf: ParseErrorNotice.statusLines(files: store.filesWithParseErrors()))
        let guessed = try store.filesWithGuessedModule()
        // What was searched for, beside what it produced: "100% guessed" alone never says whether the build files were
        // unreadable, absent, or simply not where the tool looked. Gated on the same proportion as every other
        // module-health surface — every repository has a few loose files outside any manifest, and a total-failure-
        // shaped line printed beside two of them trains the reader to skip the line that matters.
        if SessionPrimer.ModuleHealth(guessed: guessed.count, files: counts.files).isMostlyGuessed {
            lines.append(resolver.survey.line)
        }
        lines.append(contentsOf: GuessedModuleNotice.statusLines(files: guessed))
        return lines.joined(separator: "\n")
    }
}

// MARK: Opening

public extension SiftEngine {
    /// Opens (or creates) the index for the repository enclosing `directory`; a `registry` (production faces pass `.standard()`) records this root for cross-root answers and is consulted on name misses.
    ///
    /// `storesNothing` holds the index in memory whatever the tree allows, so the question is answered from the source as it stands and the file under `.sift/` is neither opened nor written: what `where --syntactic` asks for.
    convenience init(directory: URL, registry: RootsRegistry? = nil, storesNothing: Bool = false) throws {
        guard let root = GitContext.discoverRoot(from: directory) else {
            throw EngineError.notAGitRepository(directory.path, knownRoots: registry?.knownRoots() ?? [])
        }
        try self.init(discoveredRoot: root, registry: registry, storesNothing: storesNothing)
    }

    /// Opens the index for a root ``RootResolver`` has already resolved, without asking git for it a second time.
    ///
    /// An enclosing root is the one git named for the working directory a moment ago, and git names a work tree's top level as its own, so discovering it again from itself is one more git process on every command's fixed cost with nothing it could change. A root adopted from the registry is a recorded path, not git's answer, so it is still discovered.
    convenience init(resolved: ResolvedRoot, registry: RootsRegistry? = nil, storesNothing: Bool = false) throws {
        if case let .enclosing(root) = resolved {
            try self.init(discoveredRoot: root, registry: registry, storesNothing: storesNothing)
            return
        }
        try self.init(directory: resolved.url, registry: registry, storesNothing: storesNothing)
    }
}

// MARK: What a query says about the index store it is not using

extension SiftEngine {
    /// What a query says when there is no store to open — which in a linked worktree means something other than what it means in a checkout.
    ///
    /// Naming the build command is true in both and sufficient in only one. A worktree has no build directory of its own, so a repository whose checkout answers semantically every day answers nothing here, and the caller is in a state they did not create and probably have not noticed. **The obvious repair is the one thing this must never do.** The checkout's store describes a *different tree*: at a different commit it would name callers that do not exist here and miss ones that do, which is the confidently wrong answer that pinning the root to the caller's tree exists to kill — an honest gap turned into a lie, in exchange for looking more complete.
    ///
    /// The worktree case is the one every builder agent hits, on every `where` and every `digest`, so the note it gets stays one line: which state this is, and where the rest of the reasoning lives (``HelpTopics``' `worktree-index` topic — the checkout not being borrowed, and why, is said there in full, not dropped). A plain checkout still gets the build command and the config key inline, on `affected`; `where` carries the degraded note ``whereNoStoreCause(from:)`` reads from it in its place.
    ///
    /// No path is named, per the Answer Contract's Wording rule. The header already names the tree.
    ///
    /// `rejected` carries each `indexStorePath` discovery read and passed over (``IndexStoreDiscovery/rejectedSettings()``): without it, a reader who set the key is told only to set it, which reads as "your setting was never seen" when it was seen and refused.
    ///
    /// Where a `Package.swift` sits at `root`, a worktree's note names the one command that builds its store rather than only the topic, since a pointer alone sent readers to `grep` instead.
    static func noStoreNote(for tree: WorkingTree, rejected: [String] = [], root: URL? = nil) -> String {
        let rejection = rejected.isEmpty ? "" : rejected.joined(separator: "; ") + "; "
        guard tree.worktree != nil else {
            return "\(noStoreLead)\(rejection)\(checkoutRecipeOpening)\(buildCommandNote). "
                + "\(nestedStoreNote). \(syntaxOnlyTail)"
        }
        let packageAtRoot = root.map { FileManager.default.fileExists(atPath: $0.appendingPathComponent("Package.swift").path) } ?? false
        let howToBuild = packageAtRoot
            ? "\(worktreePackageBuild) (`sift help worktree-index` has why the checkout's is not used)"
            : "run `sift help worktree-index` for how to build one"
        return "\(noStoreLead)\(rejection)\(worktreeOpening)\(howToBuild). \(syntaxOnlyTail)"
    }

    /// The header's reading of a ``noStoreNote(for:rejected:root:)``: no store in this worktree, or none for this tree yet.
    ///
    /// Read back from the note by the same marker ``whereNoStoreCause(from:)`` reads, so the header and the note cannot name different trees.
    static func noStoreAxis(from note: String) -> SemanticAxis {
        if note.hasPrefix(outsideLead), let end = note.range(of: outsideRemedyOpening) {
            return .noStoreCovering(String(note[note.index(note.startIndex, offsetBy: outsideLead.count) ..< end.lowerBound]))
        }
        return .noStore(inWorktree: note.hasPrefix(noStoreLead) && note.dropFirst(noStoreLead.count).contains(worktreeOpening))
    }

    /// The cause `where`'s degraded note gives for a ``noStoreNote(for:rejected:root:)``: the build remedy, each setting passed over, and a cut-short in-tree walk.
    ///
    /// Read back from the note by the markers it is written with, as ``noStoreAxis(from:)`` reads it, so the header and the note cannot name different trees. A note it does not recognise is kept whole as the remedy.
    static func whereNoStoreCause(from note: String) -> DegradedNote.Cause {
        if note.hasPrefix(outsideLead) {
            let tail = note.range(of: ". " + syntaxOnlyTail)?.lowerBound ?? note.endIndex
            let passedOver = note.range(of: "; passed over: ").map { String(note[$0.upperBound ..< tail]) }
            return .noStore(remedy: DegradedNote.outsideRemedy, passedOver: passedOver.map { [$0] } ?? [], cutShort: "")
        }
        guard note.hasPrefix(noStoreLead) else { return .noStore(remedy: note, passedOver: [], cutShort: "") }
        let body = note.dropFirst(noStoreLead.count)
        let worktree = body.range(of: worktreeOpening)
        let rejection = (worktree ?? body.range(of: checkoutRecipeOpening)).map { String(body[..<$0.lowerBound].dropLast(2)) } ?? ""
        let remedy = if worktree == nil {
            DegradedNote.checkoutRemedy
        } else if note.contains(worktreePackageBuild) {
            DegradedNote.packageRemedy
        } else {
            DegradedNote.worktreeRemedy
        }
        let cutShort = note.hasSuffix(inTreeWalkTruncatedClause) ? inTreeWalkTruncatedClause : ""
        return .noStore(remedy: remedy, passedOver: rejection.isEmpty ? [] : [rejection], cutShort: cutShort)
    }

    /// Why a store failed to open, as the note an `.openFailed` input carries says it: the text after `failed to open: `, or the whole note.
    static func openFailureCause(of note: String) -> String {
        note.range(of: "failed to open: ").map { String(note[$0.upperBound...]) } ?? note
    }

    /// Which store failed to open, as the note an `.openFailed` input carries names it: the primary store's label (`index store found (<label>) but …`) or the in-tree store's path (`in-tree store <path> failed …`); `nil` when the note names none.
    static func openFailureStore(of note: String) -> String? {
        for (prefix, terminator) in [("index store found (", ")"), ("in-tree store ", " failed to open")] where note.hasPrefix(prefix) {
            let rest = note.dropFirst(prefix.count)
            return rest.range(of: terminator).map { String(rest[..<$0.lowerBound]) }
        }
        return nil
    }

    /// How the degraded note of a `where` or `affected` answer opens when no store answered: the mode, and where to read what it means.
    ///
    /// What matching by written name gives up is the same on every such answer, so it is said once in the `answers` help topic and not on each one. What follows this opening is the part that differs between answers: no store, still warming, or failed to open.
    static var degradedModeOpening: String {
        "mode: syntactic (sift help answers); "
    }

    /// How a ``noStoreNote(for:rejected:root:)`` opens, before any rejected setting.
    private static var noStoreLead: String {
        "no index store for this tree yet — "
    }

    /// How the note opens for a query about files outside every open store's package, before the store's own scope.
    private static var outsideLead: String {
        "no index store covers these files; "
    }

    /// What follows the store's scope in that note, before its remedy.
    private static var outsideRemedyOpening: String {
        " — "
    }

    /// What opens a checkout's recipe in a ``noStoreNote(for:rejected:root:)``, after any rejected setting.
    private static var checkoutRecipeOpening: String {
        "build one: "
    }

    /// What opens a worktree's remedy in a ``noStoreNote(for:rejected:root:)``, after any rejected setting.
    private static var worktreeOpening: String {
        "a worktree has none; "
    }

    /// The one build command a worktree with a `Package.swift` at its root is told.
    private static var worktreePackageBuild: String {
        "build one with `sift run -- swift build --build-tests`"
    }

    /// `status`'s one line about the store: where it was found, or how to get one — and, either way, each `indexStorePath` discovery read and rejected.
    ///
    /// A rejection is named whether or not another probe found a store: either way the setting did not act, and "none found", or another provenance, alone reads as the key never having been read.
    static func storeStatusLine(discovered: DiscoveredStore?, rejected: [String]) -> String {
        guard let discovered else {
            let rejection = rejected.isEmpty ? "" : rejected.joined(separator: "; ") + "; "
            return "index store: none found — \(rejection)build one: \(buildCommandNote). \(nestedStoreNote)."
        }
        let passedOver = rejected.isEmpty ? "" : "; passed over: " + rejected.joined(separator: "; ")
        return "index store: \(discovered.label) — \(discovered.path.path)\(passedOver)"
    }

    /// The deleted paths the ledger names that are still missing and that the store may still cite: dropped after the build `anchor`, or named by a unit still on disk, since a build keeps a deleted file's unit until a clean build; sorted, as the ledger's own list is.
    ///
    /// `namedByAUnit` says whether a unit names any of them, every missing path asked, those dated after the build too.
    static func deletedFilesTheStoreMayCite(ledger: DeletionLedger, anchor: Double, in discovered: DiscoveredStore, root: URL) -> (paths: [String], namedByAUnit: Bool) {
        let droppedAfterBuild = Set(ledger.paths(droppedAfter: anchor))
        let mentions = StoreUnitMentions(store: discovered.path, root: root)
        var paths: [String] = []
        var namedByAUnit = false
        for path in ledger.entries.keys.sorted() where !FileManager.default.fileExists(atPath: root.appendingPathComponent(path).path) {
            let named = mentions.names(file: path)
            namedByAUnit = namedByAUnit || named
            if named || droppedAfterBuild.contains(path) {
                paths.append(path)
            }
        }
        return (paths, namedByAUnit)
    }

    /// The lines `status` prints after its store line about its semantic field: beside the store it was judged against rather than under the header, where a list printed on every run buried that line.
    ///
    /// The line about a deleted file's record prints only when `unitKeepsADeletedFile`, a unit on disk read and found naming one.
    static func statusAxisLines(discovered: DiscoveredStore?, unitKeepsADeletedFile: Bool) -> [String] {
        guard discovered != nil else { return [] }
        return unitKeepsADeletedFile ? [statusAxisNote, statusDeletedNote] : [statusAxisNote]
    }

    /// What `status` says beside its store line whenever it found one: how its semantic field was judged, and where the cases it cannot see are listed.
    ///
    /// One line, since it prints on every run: the list itself is the help topic's (``HelpTopics``, `answers`), which names each gap Docs/Design.md §2 leaves this reading, and the two must change together.
    static var statusAxisNote: String {
        "The semantic field is judged from files, without opening the index store; `sift help answers` lists what only a query shows."
    }

    /// What `status` adds when it counts a deleted file: a build does not clear one, since the store keeps a deleted file's unit, and a query citing it goes on marking it, until a clean build.
    static var statusDeletedNote: String {
        "A deleted file stays in the store's record, and in each query citing it, until a clean build; a build without cleaning keeps it."
    }

    /// The one true way to get an index store, said identically everywhere that offers it (Docs/Design.md §2).
    ///
    /// `where`'s no-store note, `status`'s own line, `Design.md` and `INSTALL.md` all quote this same command pair rather than each inventing its own. Carries no trailing period: every call site supplies its own. Kept apart from ``nestedStoreNote`` so a sentence offering an alternative to building can sit after the commands without reading as an alternative to the config key.
    ///
    /// SwiftPM's command carries `--build-tests`: a plain `swift build` compiles no test target, so its store records no reference from a test and every answer about tests reads `partial`.
    ///
    /// Not `private`: ``HelpTopics``' `worktree-index` topic quotes it too, so the command it tells a reader to run cannot drift from what a per-call note says.
    ///
    /// `-destination 'generic/platform=iOS Simulator'` alone builds both `arm64` and `x86_64` — the simulator SDK's `ARCHS_STANDARD` carries the Intel slice even though `sift` itself never ships one — so the note narrows to ``hostArchitecture`` and pays for one architecture instead of two.
    static let buildCommandNote = "sift run -- swift build --build-tests for a SwiftPM package at the root, or "
        + "sift run -- xcodebuild -scheme <Scheme> build (add -workspace <W>.xcworkspace when the "
        + "project has one) for a macOS project — an iOS project also needs -destination "
        + "'generic/platform=iOS Simulator' ARCHS=\(hostArchitecture)"

    /// The architecture this binary is running on, for narrowing a simulator destination to the one slice that will ever execute (Docs/Design.md §2, `Distribution/make-dist.sh`'s own arm64-only build).
    private static let hostArchitecture: String = {
        #if arch(arm64)
        "arm64"
        #elseif arch(x86_64)
        "x86_64"
        #else
        "arm64"
        #endif
    }()

    /// Where discovery looks, and for a store anywhere else, the config line that points at it.
    ///
    /// The places are named so a reader who built into a directory of their own choosing can tell whether it is one of them, and each is one ``IndexStoreDiscovery/discover()`` probes: an ignored directory in general is not, since the in-tree walk serves only `where`, beside a primary. The key resolves against the repository root, so the example carries the build directory's own path. A SwiftPM build of a nested package is searched, so only a custom `-derivedDataPath` needs the key. No trailing period, as ``buildCommandNote``.
    ///
    /// Not `private`, for the same reason as ``buildCommandNote``: ``HelpTopics``' `worktree-index` topic quotes it rather than keeping a second copy that could drift.
    static let nestedStoreNote = "Discovery searches the repo root's .build, the .build of each package nested below "
        + "it (a directory holding a Package.swift), Xcode's own DerivedData, and "
        + "-derivedDataPath <Pkg>/.build/DerivedData where <Pkg> is the repo root or a directory holding a Package.swift; "
        + "any other custom -derivedDataPath needs indexStorePath set in .sift.json, "
        + "pointing at the store directory itself — the one holding v<N>/units, relative to the repo root: "
        + "<path>/Index.noindex/DataStore for a custom -derivedDataPath <path>, "
        + "as in {\"indexStorePath\": \"<path>/Index.noindex/DataStore\"}"

    /// How ``inMemoryIndexNote`` opens, public so the transcript reader that skips the line (`SourcePassthrough.firstPartLine(of:)`) matches the renderer's own text rather than a retyped copy.
    public static var inMemoryIndexNoteOpening: String {
        "index: in memory"
    }

    /// What ``memoryIndexNote`` says of an index held in memory because the question asked for nothing to be stored.
    static var syntacticIndexNote: String {
        "\(inMemoryIndexNoteOpening) — --syntactic answers from the source as it stands and stores nothing under this tree"
    }

    /// What ``memoryIndexNote`` says.
    static var inMemoryIndexNote: String {
        "\(inMemoryIndexNoteOpening) — this tree cannot be written, so nothing is stored under it and the index lasts only as long as this process"
    }

    /// Internal rather than `private`: `AffectedRenderer`'s own no-store preamble strips this exact clause off the shared note (it answers with tests, not declarations/callers/overrides), and a second copy of the string would let the wording drift out of what the strip matches.
    static let syntaxOnlyTail = "Until then, declarations still answer from syntax; callers, "
        + "overrides and references do not."

    /// What the degraded `where` note adds when the in-tree walk (``InTreeStoreWalk``) hit its cap with directories still unvisited (Docs/Design.md §2) — a store beyond where it stopped may exist.
    ///
    /// Not `private`: `WhereRenderer` matches this exact suffix to suppress the project hint in that case, since "build it with -derivedDataPath inside the tree" is exactly the advice a reader who already did that does not need repeated.
    static let inTreeWalkTruncatedClause = "; in-tree walk cut short at \(InTreeStoreWalk.visitCap) directories"

    /// What a query says while the store is still ingesting.
    ///
    /// It has to separate itself from the refusal standing beside it, because the two read alike and mean opposite things. "Build the project" means the data does not exist yet and re-asking is pointless; this means the data exists and is being read, and re-asking is the entire remedy. Saying so plainly is what stops a caller treating a slow store as a broken one and going back to grep.
    static func warmingNote(provenance: DiscoveredStore.Provenance, seconds: TimeInterval) -> String {
        "index store found (\(provenance.name)) but still warming — \(Int(seconds.rounded()))s so far, "
            + "and still going in the background. No build and no reindex will speed this up, and nothing is "
            + "wrong: a large store takes a while to read the first time. The declarations below are complete; "
            + "callers, overrides and references are the part that needs it. Ask again in a moment."
    }
}

extension SiftEngine {
    /// What a failed open said, the cache it was opening, and the anchor it failed at.
    private struct SemanticFailure {
        let note: String
        let cache: SemanticCache
        let anchor: Date
    }
}

public extension SiftEngine {
    /// `digest`'s several-targets form — `digest Type.a Type.b Type.c` — each target's own answer, in the order given; see `DigestRenderer.render(targets:options:)`.
    func digest(targets: [String], options: DigestOptions) throws -> String {
        try measuredDigest(targets: targets, options: options).text
    }

    /// The several-targets form of `measuredDigest(target:options:)`.
    func measuredDigest(targets: [String], options: DigestOptions) throws -> MeasuredAnswer {
        try notingMemoryIndex(checkedDigest { try $0.measured(targets: targets, options: options) })
    }

    /// The line a `digest` or `where` answer carries under its header while this engine's index is in memory, saying so and why; `nil` for an index on disk.
    ///
    /// The header measures the tree either way, since an index in memory is kept fresh exactly as the file is; what it cannot say is that nothing was stored, which is why the next command parses the whole tree again.
    var memoryIndexNote: String? {
        guard store.isInMemory else { return nil }
        return storesNothing ? Self.syntacticIndexNote : Self.inMemoryIndexNote
    }

    /// Whether an engine opened on the repository at `root` would hold its index in memory, worked out without opening one, parsing anything or making anything under the tree.
    ///
    /// For a caller that lives one call long, the hook: an index in memory is a parse of the whole tree on every engine opened, which a process of its own per call pays every time.
    static func wouldKeepIndexInMemory(root: URL) -> Bool {
        IndexLocation.expected(databasePath: indexPath(in: root)) == .memory
    }

    /// Where the index file of the repository at `root` lives when the tree can be written.
    internal static func indexPath(in root: URL) -> String {
        SiftPaths.cache(in: root).appendingPathComponent(SiftPaths.indexFileName).path
    }

    /// Refuses, for a command whose whole effect is the stored index, where this engine's index is in memory and nothing it did would last.
    func requireStoredIndex() throws {
        guard store.isInMemory else { return }
        throw EngineError.treeNotWritable(repoRoot.path)
    }

    /// `answer` with ``memoryIndexNote`` leading its text, which the face places directly under the header it adds.
    private func notingMemoryIndex(_ answer: MeasuredAnswer) -> MeasuredAnswer {
        guard let note = memoryIndexNote else { return answer }
        return MeasuredAnswer(text: note + "\n" + answer.text, bytes: answer.bytes, missed: answer.missed, reparsedPaths: answer.reparsedPaths, unreparsedPaths: answer.unreparsedPaths, parseErrorFiles: answer.parseErrorFiles, parts: answer.parts)
    }

    /// `freshness` naming every file a digest of this engine has reparsed from the live file since it was brought up to date, with the parse-error count as those reparses left it.
    ///
    /// For a face that frames its header once after reading several things, where the digest that found a file stale is not necessarily the one it asks: a later read finds the row already fresh and reports no reparse of its own. A header that names nothing is returned as it came.
    func framing(_ freshness: Freshness) throws -> Freshness {
        guard !servedReparses.isEmpty else { return freshness }
        return try freshness.noting(reparsed: servedReparses.reparsed.sorted(), unreparsed: servedReparses.unreparsed.sorted(), parseErrorFiles: store.counts().parseErrorFiles)
    }

    /// `render` run against a renderer whose source reads are checked against their rows, and, where one was stale, run again after reparsing it.
    ///
    /// The second pass reads the file's new rows, so the outline and the source it serves describe the same bytes; it runs once and unchecked, and the reparse leaves the reconcile counter alone, since no query-time candidate drove it.
    private func checkedDigest(_ render: (DigestRenderer) throws -> MeasuredAnswer) throws -> MeasuredAnswer {
        var renderer = try makeDigestRenderer()
        renderer.sourceReader = ServedSourceReader(checkingAgainst: store)
        let first = try render(renderer)
        guard !renderer.sourceReader.stalePaths.isEmpty else { return first }
        let stale = renderer.sourceReader.stalePaths.sorted()
        let parsed = stale.compactMap { FileParser.parse(absoluteURL: repoRoot.appendingPathComponent($0), repoRelativePath: $0) }
        try store.replaceFiles(parsed) { [resolver] in (resolver.module(for: $0), resolver.resolvedModule(for: $0) == nil) }
        let second = try render(makeDigestRenderer())
        let reparsed = Set(parsed.map(\.path))
        servedReparses.record(reparsed: stale.filter(reparsed.contains), unreparsed: stale.filter { !reparsed.contains($0) })
        let parseErrorFiles = try store.counts().parseErrorFiles
        return MeasuredAnswer(
            text: second.text, bytes: second.bytes, missed: second.missed,
            reparsedPaths: stale.filter(reparsed.contains), unreparsedPaths: stale.filter { !reparsed.contains($0) },
            parseErrorFiles: parseErrorFiles, parts: second.parts
        )
    }

    /// `digest` asked of a past revision: answered from a transient parse of that revision's tree (``RevisionQuery``), never from the store.
    func digest(targets: [String], at revision: String, options: DigestOptions) throws -> String {
        try revisionQuery(revision).digest(targets: targets, options: options)
    }

    /// `where` asked of a past revision the same way: syntactic, with call sites matched by name in that revision's files.
    func lookup(symbol: String, at revision: String, options: WhereOptions = WhereOptions()) async throws -> String {
        try await revisionQuery(revision).lookup(symbol: symbol, options: options)
    }

    /// A query against `revision`, sharing this engine's include rules, module resolution and config.
    private func revisionQuery(_ revision: String) -> RevisionQuery {
        RevisionQuery(
            repoRoot: repoRoot,
            tree: tree,
            git: git,
            enumerator: enumerator,
            resolver: resolver,
            config: config,
            revision: revision
        )
    }

    /// The renderer every `digest` query opens: wired for sibling-root pointers and this engine's config, shared so the two arities above cannot drift on how either is set up.
    internal func makeDigestRenderer() throws -> DigestRenderer {
        var renderer = try DigestRenderer(store: store, moduleNames: store.moduleNames(), repoRoot: repoRoot)
        renderer.siblingRoots = { [weak self] target in self?.siblingPointers(target: target) ?? [] }
        renderer.config = config
        renderer.isUnreadablyRenamed = { [resolver] in resolver.isUnreadablyRenamed($0) }
        return renderer
    }
}

/// Split from the class body to keep it under SwiftLint's type-body-length cap.
private extension SiftEngine {
    /// Discovery for this tree, told which directories hold a SwiftPM package so a `-derivedDataPath` build into one's own `.build` is found.
    func storeDiscovery() -> IndexStoreDiscovery {
        var discovery = IndexStoreDiscovery(repoRoot: repoRoot, config: config)
        discovery.packageDirectories = resolver.packageDirectories
        return discovery
    }

    /// The no-store note a query about files outside `discovered`'s package takes, where it is a nested package's store; `nil` for a store answering for the whole tree.
    func outsideNote(of discovered: DiscoveredStore, rejected: [String]) -> String? {
        guard !discovered.package.isEmpty else { return nil }
        let rejection = rejected.isEmpty ? "" : "; passed over: " + rejected.joined(separator: "; ")
        return "\(Self.outsideLead)\(discovered.label) answers only for files in \(discovered.package)\(Self.outsideRemedyOpening)"
            + "\(DegradedNote.outsideRemedy)\(rejection). \(Self.syntaxOnlyTail)"
    }
}

extension SiftEngine {
    /// What `where` reads: the primary store's input with the in-tree stores joined behind it, or, where there is no primary store, the in-tree stores alone.
    ///
    /// The walk runs before the primary's budget starts, and nothing here changes what the primary path remembers, so `affected`, `diff`, `status` and the deletion ledger see exactly the primary store. A primary still warming or failed answers as it would without the in-tree stores.
    func whereSemanticInput() -> SemanticInput {
        let discovery = storeDiscovery()
        let candidates = inTree.discover(discovery)
        let started = Date()
        let input = semanticInput(budget: openBudget)
        let primaryPath = probedStore.flatMap(\.self).map { CanonicalPath.of($0.path.path) }
        let stores = candidates.filter { CanonicalPath.of($0.path.path) != primaryPath }
        let remaining = max(0, openBudget - Date().timeIntervalSince(started))
        // Opened every branch below, including the ones that hand `input` back unchanged, so a store discovery
        // no longer names is let go whether or not the primary is active.
        let openings = inTree.open(stores, repoRoot: repoRoot, budget: remaining)
        switch input {
        case let .active(primary):
            return .active(primary.joining(openings))
        case .unavailable where !stores.isEmpty:
            guard let first = openings.opened.first else {
                if let note = openings.warmingNote {
                    return .warming(note: note)
                }
                return openings.pending.isEmpty ? input : .openFailed(note: openings.pending.joined(separator: "; "))
            }
            var rest = openings
            rest.opened.removeFirst()
            return .active(SemanticContext(store: first, repoRoot: repoRoot, rejectedSettings: discovery.rejectedSettings()).joining(rest))
        default:
            // The walk found nothing to open — say so when the cap, not an empty tree, is why: a note that only
            // ever advises "build one" is wrong for a reader who already did, just not where the walk reached.
            guard inTree.walkTruncated, case let .unavailable(note) = input else { return input }
            return .unavailable(note: note + Self.inTreeWalkTruncatedClause)
        }
    }
}

private extension SiftEngine {
    /// When the build's index store was last written, by its newest unit — or `nil` with no store, or no unit, to date.
    ///
    /// Discovery only, never an open: `status` anchors on the same date, and a store with no deletion ledger is seeded from git history since it (`Indexer.seedDeletionLedgerIfAbsent(listed:storeBuiltAt:at:)`).
    func storeBuiltAt() -> Date? {
        probeStore().flatMap(Self.newestUnit(of:))
    }

    static func newestUnit(of discovered: DiscoveredStore) -> Date? {
        // Discovery already walked every unit to choose a DerivedData store; walking them again is the cost of a cold stat per unit.
        discovered.newestUnit ?? IndexStoreDiscovery.newestUnitDate(in: discovered.path)
    }
}

public extension SiftEngine {
    /// Lets go of every index-store open this engine holds, so its next query opens the stores as a newly opened engine's first query would.
    ///
    /// For an engine kept across answers that must each answer as a process of its own would: the store opened, the failure remembered, the open still warming in the background and the in-tree stores beside them all go, so an open that overran one answer's budget is never found finished by the next. An open already running goes on to its end and is read by nobody, as it would be once its process exited. What this engine knows of the tree and its modules is kept.
    func openSemanticStoresAfresh() {
        openedSemanticStore = nil
        semanticFailure = nil
        semanticOpener = BudgetedOpen<SemanticStore>()
        inTree = InTreeStoreSet()
    }
}

/// Split from the class body to keep it under SwiftLint's type-body-length cap.
///
/// Four read-only surfaces that consult no stored row and carry no staleness axis of their own; `repoRoot`, `enumerator`, `git` and `config` stay reachable, since a same-file extension of a type sees its `private` members exactly as the primary declaration does.
public extension SiftEngine {
    /// Runs a structural query over the working tree and renders the matches.
    ///
    /// Takes no `Freshness` and consults no stored row: it parses what is on disk, so there is nothing here that could be stale (Docs/Design.md §2 — this axis simply does not apply). It still opens with a header, the live one, because which tree was read is a question the answer has to settle whether or not anything could be stale.
    func search(query: String, offset: Int = 0, count: Bool = false) async throws -> String {
        let parsed = try StructuralQuery(query)
        let result = await StructuralSearch(repoRoot: repoRoot, enumerator: enumerator).run(parsed)
        let note = await typeBodyNote(for: parsed, result: result)
        let body = count
            ? SearchRenderer.renderCount(result: result, query: parsed, typeBodyNote: note, moduleFor: resolver.module(for:))
            : SearchRenderer.render(result: result, query: parsed, offset: offset, typeBodyNote: note)
        return Freshness.liveHeaderLine(tree: tree) + "\n" + (parsed.readingNote.map { $0 + "\n" } ?? "") + body
    }

    /// The extra miss line for a type-kind query whose body term missed, `nil` for any other answer.
    ///
    /// The query is re-scanned for extensions, which the type's own declaration did not hold.
    private func typeBodyNote(for query: StructuralQuery, result: StructuralSearch.Result) async -> String? {
        guard result.matches.isEmpty, let extensionQuery = query.extensionQueryForTypeBodyMiss(eliminations: result.eliminations) else { return nil }
        let found = await StructuralSearch(repoRoot: repoRoot, enumerator: enumerator).run(extensionQuery).matches.count
        return query.typeBodyMissLine(extensionQuery: extensionQuery, found: found)
    }

    /// Ranks the working tree's declarations by how close their syntactic shape is to `target`'s — the helper that already exists, shown before another one is written.
    ///
    /// Working-tree read, like `search` — no staleness axis, no stored rows (Docs/Design.md §3), and the same live header.
    func similar(target: String) async -> String {
        let answer = await SimilarSearch(repoRoot: repoRoot, enumerator: enumerator).run(target: target)
        return Freshness.liveHeaderLine(tree: tree) + "\n" + SimilarRenderer.render(answer: answer)
    }

    /// Groups the working tree's near-duplicate bodies, over the files under `scope` or the whole tree when it is empty.
    ///
    /// Working-tree read, like `similar` — no staleness axis, no stored rows (Docs/Design.md §3), and the same live header.
    func dupes(scope: [String], options: DupesOptions = DupesOptions()) async -> String {
        let answer = await DupesSearch(repoRoot: repoRoot, enumerator: enumerator).run(scope: scope, options: options)
        return Freshness.liveHeaderLine(tree: tree) + "\n" + DupesRenderer.render(answer: answer)
    }

    /// Traces display text ↔ localization key across the repo's string catalogs, plus the Swift lines spelling a matched key as a literal.
    ///
    /// Working-tree read, like `search` — no staleness axis, no stored rows (Docs/Design.md §3), and the same live header.
    func strings(query: String) throws -> String {
        let gitContext = git
        let search = StringCatalogSearch(
            repoRoot: repoRoot,
            catalogPaths: { try gitContext.visibleStringCatalogs() },
            swiftPaths: { self.enumerator.swiftFiles() },
            cache: stringCatalogCache
        )
        return try Freshness.liveHeaderLine(tree: tree) + "\n" + StringsRenderer.render(answer: search.run(query: query), query: query)
    }

    /// Proposes (and optionally writes) `.sift.json` for this repository.
    ///
    /// Reports rather than assumes: the plan is printed whether or not it is written, because the finding that matters — which files have no declaring build file — is useful even when the user wants no config file at all.
    func initializeConfig(write: Bool, force: Bool) throws -> String {
        let plan = ConfigPlan.make(repoRoot: repoRoot, config: config, paths: enumerator.swiftFiles(includingManifests: true))
        guard write else {
            return ConfigPlanRenderer.render(plan: plan, wrote: nil)
        }
        if ConfigFile.exists(repoRoot: repoRoot), !force {
            return ConfigPlanRenderer.render(plan: plan, wrote: nil)
                + "\n.sift.json already exists — pass --force to merge these entries into it (existing values are never overwritten)."
        }
        try TreeWritability.requireConfigFile(repoRoot: repoRoot)
        let merged = plan.merged(onto: config)
        var json = ConfigFile.rawJSON(repoRoot: repoRoot)
        if !merged.roots.isEmpty {
            json["roots"] = merged.roots
        }
        if !merged.moduleMap.isEmpty {
            json["moduleMap"] = merged.moduleMap
        }
        try ConfigFile.write(json, repoRoot: repoRoot)
        reloadConfigIfChanged()
        return ConfigPlanRenderer.render(plan: plan, wrote: ".sift.json")
    }
}
