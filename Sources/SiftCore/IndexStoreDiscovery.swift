//
// Copyright © Agulhas Labs
//

import Foundation

/// Locates the repo's index store without opening it — discovery is filesystem probing only (Docs/Design.md §2).
///
/// Probe order: explicit config → `buildServer.json` (its `indexStorePath`, else its `workspace` matched into DerivedData) → SwiftPM's `.build`, in either layout (Swift Build's `.build/out`, the native build system's `index/store` directories), the newest unit winning between them, and across a `--scratch-path` directory directly under `.build` (`.build/<name>/out`, `.build/<name>/<triple>/<config>/index/store`) → a DerivedData scan for an `info.plist` whose `WorkspacePath` sits inside the repo. The scan passes over three kinds of entry, each of which describes some other tree than this one: a workspace that no longer exists (a removed worktree's entry outlives it), one under a directory the index never covers (a hidden one such as `.claude/worktrees`, or a vendored one), and one inside a *nested* checkout (a live linked worktree, say). When several entries remain, the one with the newest unit wins.
struct IndexStoreDiscovery {
    let repoRoot: URL
    let config: SiftConfig
    /// Overridable for tests; production uses `~/Library/Developer/Xcode/DerivedData`.
    var derivedDataRoot: URL
    /// Whether several matching DerivedData stores are weighed against each other by their newest unit, or the first found is taken — the choice matters only to which store is opened, never to whether one exists.
    var weighsCandidates = true

    init(repoRoot: URL, config: SiftConfig, derivedDataRoot: URL? = nil) {
        self.repoRoot = repoRoot
        self.config = config
        self.derivedDataRoot = derivedDataRoot
            ?? SiftPaths.accountHome
            .appendingPathComponent("Library/Developer/Xcode/DerivedData")
    }

    func discover() -> DiscoveredStore? {
        if let configured = config.indexStorePath {
            let url = resolved(configured)
            if Self.isStore(url) {
                return DiscoveredStore(path: url, provenance: .config)
            }
        }
        if let fromBuildServer = probeBuildServerJSON() {
            return fromBuildServer
        }
        if let fromSwiftPM = probeSwiftPMBuild() {
            return fromSwiftPM
        }
        // Canonical on both sides (`probeDerivedData` hands the workspace over canonical too): Xcode records
        // the path as the filesystem spells it, while a root can arrive through a symlink (`/tmp`) or in a
        // shell's case-insensitive spelling, and a raw prefix match then misses this repository's own store.
        let rootPath = CanonicalPath.of(repoRoot.path)
        return probeDerivedData(anchorCanonical: rootPath) { workspacePath in
            // Component-boundary prefix: /Dev/GizmoTools must never supply /Dev/Gizmo's store.
            guard workspacePath == rootPath || workspacePath.hasPrefix(rootPath + "/") else { return false }
            // Only the path *below* this root is judged: a worktree's own root sits under `.claude/worktrees`,
            // and querying from it must still find its own entry. A hidden or vendored directory in that
            // relative path is one the index never covers, so a store built there describes a tree this
            // repository's answers are not about — and `.claude/worktrees` is where removed agent worktrees
            // leave their entries behind.
            let relative = workspacePath.dropFirst(rootPath.count).split(separator: "/")
            guard !relative.contains(where: SiftConfig.isExcludedPathComponent) else { return false }
            // A workspace inside a *nested* checkout — a linked worktree under this repo, or any other
            // repo checked out beneath it — belongs to that checkout's own build, not this one's: at a
            // different commit its store would name callers that do not exist here and miss ones that
            // do. Querying from that nested checkout itself must still find its own entry, so this only
            // excludes ancestors strictly between the workspace and this repoRoot, never repoRoot itself.
            return !Self.liesInsideNestedCheckout(workspacePath, under: rootPath)
        }
    }

    /// How far below the root an in-tree build directory may sit, in path components (`.build/runner-dd` is two).
    static let inTreeDepthBound = 4

    /// Every index store an `xcodebuild -derivedDataPath` build left inside this repository, in path order — the additional sources `where` reads beside the primary store.
    func discoverInTree(excluding primary: URL?) -> [DiscoveredStore] {
        discoverInTree(excluding: primary, reusing: nil).stores
    }

    /// The same, reusing `previous` — the walk an earlier query made — while it still holds, and returning the walk the stores came from.
    ///
    /// A store counts when its build directory (the one holding `Index.noindex/DataStore`) lies inside a directory git ignores, found by the bounded walk ``InTreeStoreWalk`` describes. Asking git for the ignored directories is one call that never walks tracked source, and a tree git cannot read has no in-tree stores rather than guessed ones. The walk is reused while git lists the same ignored directories and none it visited has changed; which of its build directories holds a store is checked afresh every time, since a build fills one without touching any directory the walk dated. `primary`, the store ``discover()`` found, is never listed a second time.
    func discoverInTree(excluding primary: URL?, reusing previous: InTreeStoreWalk?) -> (stores: [DiscoveredStore], walk: InTreeStoreWalk?) {
        guard let ignored = try? GitContext(repoRoot: repoRoot).ignoredDirectories() else { return ([], nil) }
        let walk = previous.flatMap { $0.holds(repoRoot: repoRoot, ignored: ignored) ? $0 : nil }
            ?? InTreeStoreWalk.walk(repoRoot: repoRoot, ignored: ignored)
        let primaryPath = primary.map { CanonicalPath.of($0.path) }
        let stores = walk.candidates.compactMap { directory -> DiscoveredStore? in
            let store = repoRoot.appendingPathComponent(directory).appendingPathComponent("Index.noindex/DataStore")
            guard Self.isStore(store), CanonicalPath.of(store.path) != primaryPath else { return nil }
            return DiscoveredStore(path: store, provenance: .inTree(directory))
        }
        return (stores, walk)
    }

    /// Each `indexStorePath` this repository sets that was read and passed over because it is not an index store, as a clause naming the value and the file it came from.
    ///
    /// Discovery falls through a rejected setting to the next probe, which is the right behaviour and a silent one: the reader who set the key sees "none found", or a store from somewhere else, and the advice to set the very key they set. `status` and the no-store note quote these so the rejection is said where the setting would have acted.
    func rejectedSettings() -> [String] {
        var rejected: [String] = []
        if let configured = config.indexStorePath, !Self.isStore(resolved(configured)) {
            rejected.append(Self.rejection(of: configured, in: ConfigFile.url(repoRoot: repoRoot).lastPathComponent))
        }
        if let explicit = buildServerJSON()?["indexStorePath"] as? String, !Self.isStore(resolved(explicit)) {
            rejected.append(Self.rejection(of: explicit, in: "buildServer.json"))
        }
        return rejected
    }

    /// The one wording for a rejected `indexStorePath`, whichever file set it.
    static func rejection(of value: String, in file: String) -> String {
        "indexStorePath '\(value)' in \(file) is not an index store (no v<N>/units under it)"
    }

    /// A configured path as discovery reads it: absolute as written, otherwise against the repository root.
    private func resolved(_ path: String) -> URL {
        path.hasPrefix("/") ? URL(fileURLWithPath: path) : repoRoot.appendingPathComponent(path)
    }

    /// Whether `workspacePath` sits inside another git checkout nested strictly between it and `rootPath`.
    ///
    /// Walks the ancestor directories from the workspace up to (but excluding) `rootPath`, looking for a `.git` entry — the marker every checkout root carries, a linked worktree's own `.git` file included. Finding one means the workspace belongs to that nested checkout, not to `rootPath`.
    ///
    /// Both paths arrive canonical, and are compared as they arrive: `standardizedFileURL` would strip a leading `/private` from one side only, and the walk would stop before its first step.
    private static func liesInsideNestedCheckout(_ workspacePath: String, under rootPath: String) -> Bool {
        var directory = URL(fileURLWithPath: workspacePath)
        while directory.path.hasPrefix(rootPath + "/") {
            if FileManager.default.fileExists(atPath: directory.appendingPathComponent(".git").path) {
                return true
            }
            directory.deleteLastPathComponent()
        }
        return false
    }

    // MARK: Probes

    /// `buildServer.json` at the root, parsed, or `nil` when there is none or it is not a JSON object.
    private func buildServerJSON() -> [String: Any]? {
        guard let data = try? Data(contentsOf: repoRoot.appendingPathComponent("buildServer.json")) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    private func probeBuildServerJSON() -> DiscoveredStore? {
        guard let json = buildServerJSON() else { return nil }
        if let explicit = json["indexStorePath"] as? String {
            let storeURL = resolved(explicit)
            if Self.isStore(storeURL) {
                return DiscoveredStore(path: storeURL, provenance: .buildServerJSON)
            }
        }
        guard let workspace = json["workspace"] as? String else { return nil }
        let workspaceAbsolute = CanonicalPath.of(resolved(workspace).path)
        return probeDerivedData(anchorCanonical: workspaceAbsolute) { $0 == workspaceAbsolute }
            .map { DiscoveredStore(path: $0.path, provenance: .buildServerJSON, newestUnit: $0.newestUnit) }
    }

    /// Where SwiftPM leaves a store in `.build`, relative to the repository root.
    ///
    /// Two layouts, one per build system. Swift Build — SwiftPM's default as of Swift 6.4 — writes the store into `.build/out` itself, whatever `-index-store-path` is passed, and `.build/debug` is then a symlink into `out/Products/Debug`, which holds none. The native build system (`--build-system native`, and every older toolchain) writes it under the per-configuration directory `.build/debug` and `.build/release` link to, or at `.build/index/store` when asked to by flag. Ordered only for a tie, which the explicitly requested path wins, then the current default's.
    static let swiftPMCandidates = [".build/index/store", ".build/out", ".build/debug/index/store", ".build/release/index/store"]

    /// The store in this repository's own `.build` with the newest unit, among every candidate and in whichever layout wrote it.
    ///
    /// Both layouts can hold a store in one checkout: a toolchain upgrade that makes Swift Build the default leaves the native store behind, and a `--build-system native` build afterwards leaves `.build/out` behind in turn. The one written last is nearest the tree as last built; the other describes an earlier build and is stale in a way no rebuild of it will ever heal, so taking it by position would refuse, or answer, from the wrong build. The same rule the DerivedData scan applies across its entries, and it holds between the native configurations too: a release store indexed after the last debug build wins, where a fixed order once put debug first. The newest unit is one file, so a partial build into the store that would otherwise lose makes it win with older units beside it — the approximation the staleness anchor makes everywhere (Docs/Design.md §2).
    private func probeSwiftPMBuild() -> DiscoveredStore? {
        Self.newestStore(among: (Self.swiftPMCandidates + scratchPathCandidates()).map { repoRoot.appendingPathComponent($0) })
            .map { DiscoveredStore(path: $0.store, provenance: .swiftPMBuild, newestUnit: $0.newestUnit) }
    }

    /// The stores a `--scratch-path` directory inside `.build` leaves, relative to the repository root: for each immediate child `<name>` of `.build`, `<name>/out` (Swift Build) and `<name>/<triple>/<config>/index/store` (the native build system).
    ///
    /// One level of children and one of triples, never a walk of the tree. A child holding a `.git` is another checkout, and a hidden triple (such as that checkout's `.build`) is skipped. A candidate that is no store is skipped by ``newestStore(among:)``, which weighs these against the default locations by newest unit.
    private func scratchPathCandidates() -> [String] {
        let fileManager = FileManager.default
        func children(_ directory: String) -> [String] {
            ((try? fileManager.contentsOfDirectory(atPath: repoRoot.appendingPathComponent(directory).path)) ?? []).sorted()
        }
        return children(".build").filter { name in
            // Another checkout's own `.build` is not a scratch path: its store describes that checkout.
            !fileManager.fileExists(atPath: repoRoot.appendingPathComponent(".build/\(name)/.git").path)
        }.flatMap { name in
            [".build/\(name)/out"] + children(".build/\(name)").filter { !$0.hasPrefix(".") }.flatMap { triple in
                children(".build/\(name)/\(triple)").map { ".build/\(name)/\(triple)/\($0)/index/store" }
            }
        }
    }

    /// Of `candidates`, the store whose newest unit is newest — discovery's one rule wherever several stores could answer for the same tree.
    ///
    /// Carries that date back too, so a caller needing it (the staleness anchor) does not walk the winning store's units a second time. A candidate without a store's shape is skipped; a store with no unit at all ranks as built at `.distantPast`; an earlier candidate keeps a tie.
    private static func newestStore(among candidates: [URL]) -> (store: URL, newestUnit: Date)? {
        var best: (store: URL, newestUnit: Date)?
        for store in candidates where isStore(store) {
            let newest = newestUnitDate(in: store) ?? .distantPast
            if best.map({ newest > $0.newestUnit }) ?? true {
                best = (store, newest)
            }
        }
        return best
    }

    /// A cheap, filesystem-free rejection of a DerivedData entry that plainly cannot describe the anchor — this repository's root, for the scan in ``discover()``; the named workspace, for `buildServer.json`'s — so an entry for some other project on the machine costs a plist read and this string compare, never a `stat`, and a workspace on a hung network share or automount cannot stall discovery.
    ///
    /// Case-insensitive and with a leading `/private` stripped, the two differences a raw compare misses that `CanonicalPath.of` would otherwise resolve. A symlink elsewhere in the chain leaves an entry's own tail intact, so this also accepts anything sharing the anchor's own last path component — together the two checks are a superset of every entry the exact, canonical match below could accept, so nothing this rejects could ever have matched: only what could never match skips paying for a `stat`.
    private static func mightDescribe(_ workspacePath: String, anchorCanonical: String) -> Bool {
        func normalized(_ value: String) -> String {
            let stripped = value.hasPrefix("/private/") ? String(value.dropFirst("/private".count)) : value
            return stripped.lowercased()
        }
        let path = normalized(workspacePath)
        let anchor = normalized(anchorCanonical)
        if path == anchor || path.hasPrefix(anchor + "/") {
            return true
        }
        let anchorBasename = (anchor as NSString).lastPathComponent
        guard !anchorBasename.isEmpty else { return true }
        return path.split(separator: "/").contains(Substring(anchorBasename))
    }

    private func probeDerivedData(anchorCanonical: String, matching workspaceMatches: (String) -> Bool) -> DiscoveredStore? {
        let fileManager = FileManager.default
        // A symlinked DerivedData directory (someone moved it and left a symlink behind) enumerates as
        // empty through `contentsOfDirectory(at:)` unless the symlink itself is resolved first.
        let derivedDataDirectory = derivedDataRoot.resolvingSymlinksInPath()
        guard let entries = try? fileManager.contentsOfDirectory(at: derivedDataDirectory, includingPropertiesForKeys: nil) else {
            return nil
        }
        var stores: [URL] = []
        for entry in entries {
            let plistURL = entry.appendingPathComponent("info.plist")
            guard let data = try? Data(contentsOf: plistURL),
                  let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
                  let workspacePath = plist["WorkspacePath"] as? String else { continue }
            // The string-only pass first, before either filesystem call below can run for an entry that
            // plainly belongs to some other project.
            guard Self.mightDescribe(workspacePath, anchorCanonical: anchorCanonical) else { continue }
            // Xcode keeps an entry after its workspace is gone — `git worktree remove` deletes the folder and
            // leaves DerivedData alone — and with the folder goes the `.git` file that marked it as a nested
            // checkout, so a removed worktree's entry would otherwise read as this repository's own. Its
            // store describes a tree that no longer exists, and newest-unit-wins would prefer it.
            guard fileManager.fileExists(atPath: workspacePath), workspaceMatches(CanonicalPath.of(workspacePath)) else { continue }
            let store = entry.appendingPathComponent("Index.noindex/DataStore")
            if !weighsCandidates, Self.isStore(store) {
                return DiscoveredStore(path: store, provenance: .derivedData)
            }
            stores.append(store)
        }
        return Self.newestStore(among: stores).map { DiscoveredStore(path: $0.store, provenance: .derivedData, newestUnit: $0.newestUnit) }
    }

    /// Whether `url` looks like a real index store — a versioned directory (`v5`, `v6`, …) holding a `units` subdirectory — rather than any directory that happens to exist.
    ///
    /// A configured `indexStorePath` pointing at a build root instead of the store itself (`.build`, say, instead of `.build/out` or `.build/debug/index/store`) must not be accepted as a store: doing so anchors staleness checks at `.distantPast`, since no unit is ever found, and every occurrence reads as modified since a build that in fact happened — a "stale, build the project" that no rebuild can fix.
    static func isStore(_ url: URL) -> Bool {
        unitsDirectory(in: url) != nil
    }

    /// The `units` directory of the highest-numbered `v<N>` in `store` that has one, or `nil` when none does.
    ///
    /// The one definition of the store's shape, asked by both ``isStore(_:)`` and ``newestUnitDate(in:)``: were the check to accept a version the anchor then did not read, that store would pass as one and anchor at `.distantPast` — permanently stale, the very failure the shape check exists to prevent. Compared as numbers, so `v10` is newer than `v9`. ``SemanticCache`` takes the store's identity from this directory too, so a store the check accepts always has one.
    static func unitsDirectory(in store: URL) -> URL? {
        guard let entries = try? FileManager.default.contentsOfDirectory(at: store, includingPropertiesForKeys: nil) else {
            return nil
        }
        let versioned = entries.compactMap { entry -> (version: Int, units: URL)? in
            let name = entry.lastPathComponent
            guard name.hasPrefix("v"), let version = Int(name.dropFirst()), name.dropFirst().allSatisfy(\.isNumber) else {
                return nil
            }
            var isDirectory: ObjCBool = false
            let units = entry.appendingPathComponent("units")
            guard FileManager.default.fileExists(atPath: units.path, isDirectory: &isDirectory), isDirectory.boolValue else {
                return nil
            }
            return (version, units)
        }
        return versioned.max { $0.version < $1.version }?.units
    }

    /// The newest unit file's mtime — the store's "last built" moment, and the anchor of per-symbol staleness.
    ///
    /// Only regular files count, as a guard rather than a fix for anything a real store is known to do: a store's `v<N>/units` sits flat, so a directory entry's own mtime is not expected to move independently of the files inside it. But nothing rules that out here, and if a directory's mtime ever landed later than the newest unit file's, counting it would push the anchor later than the store's own content justifies. That under-warns rather than over-warns: a file edited between the real build and that inflated anchor would look already covered by the index, when it is not.
    static func newestUnitDate(in store: URL) -> Date? {
        guard let unitsURL = unitsDirectory(in: store), let enumerator = FileManager.default.enumerator(
            at: unitsURL,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey]
        ) else { return nil }
        var newest: Date?
        while let url = enumerator.nextObject() as? URL {
            guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey]),
                  values.isRegularFile == true,
                  let date = values.contentModificationDate
            else { continue }
            if newest.map({ date > $0 }) ?? true {
                newest = date
            }
        }
        return newest
    }
}
