//
// Copyright © Agulhas Labs
//

import Foundation

/// Everything semantic rendering needs: the open store, path relativization, and the moment staleness is judged against.
struct SemanticContext {
    let store: SemanticStore
    let repoRoot: URL
    /// Each `indexStorePath` discovery read and passed over on the way to opening `store` — named in the degraded `where` note even though a store was found, since the setting still did not act (``IndexStoreDiscovery/rejectedSettings()``).
    var rejectedSettings: [String] = []
    /// The open in-tree stores, in path order, that answer for a declaration `store` does not resolve (``IndexStoreDiscovery/discoverInTree(excluding:)``).
    var inTreeStores: [SemanticStore] = []
    /// A clause for each in-tree store that is still loading or failed to open, named in the degraded `where` note.
    var pendingInTree: [String] = []
    /// Whether an in-tree store is still loading, so a declaration no open store resolves reads as warming rather than unresolved.
    var inTreeWarming = false
    /// The no-store note a query takes in place of this context when every file it asks about lies outside what each of its stores answers for (``SemanticInput/answering(forFiles:)``), `nil` where every store answers for the whole tree.
    var outsideNote: String?

    /// The context of the first store — this one's, then each in-tree store's — that resolves `row`, with the USR it resolved to.
    func owner(of row: SymbolRow) -> (context: SemanticContext, usr: String)? {
        for candidate in [store] + inTreeStores where candidate.answers(forFile: row.path) {
            if let usr = candidate.usr(for: row) {
                return (SemanticContext(store: candidate, repoRoot: repoRoot, rejectedSettings: rejectedSettings), usr)
            }
        }
        return nil
    }

    /// Whether this store or any in-tree store holds a unit for the repo-relative `path`, under the root as given or as the filesystem spells it.
    func anyStoreHasUnit(forFile path: String) -> Bool {
        holdsUnit(in: [store] + inTreeStores, forFile: path)
    }

    /// The first of this store and the in-tree stores that answers for the repo-relative `path` and holds a unit for it, `nil` where none does.
    func storeHoldingUnit(forFile path: String) -> SemanticStore? {
        ([store] + inTreeStores).first { holdsUnit(in: [$0], forFile: path) }
    }

    /// The places the first store holding a unit for the repo-relative `path` records `names` referenced at there (``SemanticStore/writtenPlaces(of:inFile:)``), under the root as given or as the filesystem spells it; `nil` where no store holds one.
    func recordedPlaces(of names: ScannedNames, inFile path: String) -> [String: [ScannedNames.RecordedPlace]]? {
        var spellings = FileSpellings(ofFile: path, under: repoRoot)
        for candidate in [store] + inTreeStores where candidate.answers(forFile: path) {
            if let spelling = spellings.first(where: candidate.hasUnit(forFile:)) {
                return candidate.writtenPlaces(of: names, inFile: spelling)
            }
        }
        return nil
    }

    /// Whether any of `stores` that answers for the repo-relative `path` holds a unit for it, under the root as given or as the filesystem spells it.
    func holdsUnit(in stores: [SemanticStore], forFile path: String) -> Bool {
        let answering = stores.filter { $0.answers(forFile: path) }
        guard !answering.isEmpty else { return false }
        var spellings = FileSpellings(ofFile: path, under: repoRoot)
        return spellings.contains { spelling in answering.contains { $0.hasUnit(forFile: spelling) } }
    }

    /// The packages of this context's stores, sorted, where none of them answers for the repo-relative `path`; `nil` where one does.
    func packagesPassingOver(file path: String) -> [String]? {
        let stores = [store] + inTreeStores
        guard !stores.contains(where: { $0.answers(forFile: path) }) else { return nil }
        return Set(stores.map(\.package)).sorted()
    }

    /// Whether any of this context's stores answers for at least one of the repo-relative `paths`.
    func answersForAny(of paths: [String]) -> Bool {
        ([store] + inTreeStores).contains { candidate in paths.contains(where: candidate.answers(forFile:)) }
    }

    /// The indexed test files, by the import rule ``TestFileRecognition`` applies, that no store holds a unit for, repo-relative and sorted, split by whether a build of the store's project would add them.
    ///
    /// `unbuilt` is a test target the last build skipped, which a plain `swift build` always does, a target added since, or a file added to a built target since: the store records no reference from any of them. Where a test build ran, a file in a module no store holds a single unit for is `outsideTargets` instead when it sits in another project of the tree (``ProjectBoundary``: a project no store built, and for SwiftPM's store any project but the root package and those an in-tree store holds a unit in) or, for SwiftPM's store, in a module the root manifest declares no target for: no build of the store's project compiles it. Where no test build ran, every file stays `unbuilt`, since a test build is then what tells them apart; a manifest naming no target literally, or any target by a computed name, is read as declaring every module, so doubt lands on `unbuilt`.
    func testFilesWithoutUnit(in index: IndexStore, projectDirectories: [String]) throws -> (unbuilt: [String], outsideTargets: [String]) {
        let files = try index.fileInventory().values
        let testFiles = files.filter { TestFileRecognition.isTestFile(imports: $0.imports) }
        let withoutUnit = testFiles.filter { !anyStoreHasUnit(forFile: $0.path) }
        guard withoutUnit.count < testFiles.count else {
            return (withoutUnit.map(\.path).sorted(), [])
        }
        let outside = BuildMembership(files: Array(files), context: self, projectDirectories: projectDirectories).outsideTheBuild(withoutUnit)
        return (
            withoutUnit.map(\.path).filter { !outside.contains($0) }.sorted(),
            outside.sorted()
        )
    }

    /// The indexed test files no store holds a unit for, classified by whether any test file has one — what every `where` reader of them decides its advice and its axis on.
    func testFileCoverage(in index: IndexStore) throws -> TestFileCoverage {
        let testFiles = try index.fileInventory().values.filter { TestFileRecognition.isTestFile(imports: $0.imports) }
        let withoutUnit = testFiles.count { !anyStoreHasUnit(forFile: $0.path) }
        return TestFileCoverage(withoutUnit: withoutUnit, neverBuilt: withoutUnit > 0 && withoutUnit == testFiles.count, provenance: store.provenance, package: store.package)
    }

    /// The instant a file's change is compared with for a build whose newest unit is `newestUnit`, nudged past equality so a file written in the same clock tick as the build reads as newer rather than as level with it.
    ///
    /// One expression, so the per-file judge (``OccurrenceFreshness``) and `status`, which never opens the store, agree by construction on what "since the build" means.
    static func buildAnchor(newestUnit: Date) -> Double {
        newestUnit.timeIntervalSince1970 + 0.001
    }

    /// Store locations are absolute; render them repo-relative when they sit inside the repo.
    func relativePath(_ absolute: String) -> String {
        let root = repoRoot.standardizedFileURL.path + "/"
        if absolute.hasPrefix(root) {
            return String(absolute.dropFirst(root.count))
        }
        let privateRoot = "/private" + root
        if absolute.hasPrefix(privateRoot) {
            return String(absolute.dropFirst(privateRoot.count))
        }
        return absolute
    }
}
