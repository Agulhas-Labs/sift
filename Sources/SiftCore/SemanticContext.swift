//
// Copyright © Agulhas Labs
//

import Foundation

/// Everything semantic rendering needs: the open store, path relativization, and the moment staleness is judged against.
struct SemanticContext {
    let store: SemanticStore
    let repoRoot: URL
    /// Each `indexStorePath` discovery read and passed over on the way to opening `store` — named on the `where` mode line even though a store was found, since the setting still did not act (``IndexStoreDiscovery/rejectedSettings()``).
    var rejectedSettings: [String] = []
    /// The open in-tree stores, in path order, that answer for a declaration `store` does not resolve (``IndexStoreDiscovery/discoverInTree(excluding:)``).
    var inTreeStores: [SemanticStore] = []
    /// A clause for each in-tree store that is still loading or failed to open, named on the `where` mode line.
    var pendingInTree: [String] = []
    /// Whether an in-tree store is still loading, so a declaration no open store resolves reads as warming rather than unresolved.
    var inTreeWarming = false

    /// The context of the first store — this one's, then each in-tree store's — that resolves `row`, with the USR it resolved to.
    func owner(of row: SymbolRow) -> (context: SemanticContext, usr: String)? {
        for candidate in [store] + inTreeStores {
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

    private func holdsUnit(in stores: [SemanticStore], forFile path: String) -> Bool {
        let absolute = repoRoot.appendingPathComponent(path).path
        let spellings = Set([absolute, "/private" + absolute, CanonicalPath.of(absolute)])
        return stores.contains { candidate in spellings.contains { candidate.hasUnit(forFile: $0) } }
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
        let compiled = Set(withoutUnit.map(\.module)).filter { module in
            files.contains { $0.module == module && anyStoreHasUnit(forFile: $0.path) }
        }
        let candidates = withoutUnit.filter { !compiled.contains($0.module) }
        guard !candidates.isEmpty else {
            return (withoutUnit.map(\.path).sorted(), [])
        }
        let boundary = ProjectBoundary(directories: projectDirectories)
        var builtProjects: Set = [""]
        var declared: Set<String>?
        if store.provenance == .swiftPMBuild {
            let manifest = SwiftPMManifest.parse(fileAt: repoRoot.appendingPathComponent("Package.swift"))
            declared = manifest.targets.isEmpty || manifest.computedTargetNames ? nil : Set(manifest.targets.map(\.name))
            // A nested project an in-tree store was built for is built too: that store's build adds a target the project gains since.
            builtProjects.formUnion(Set(candidates.map { boundary.project(of: $0.path) }).filter { project in
                files.contains { boundary.project(of: $0.path) == project && holdsUnit(in: inTreeStores, forFile: $0.path) }
            })
        } else {
            builtProjects = Set(candidates.map { boundary.project(of: $0.path) }).filter { project in
                files.contains { boundary.project(of: $0.path) == project && anyStoreHasUnit(forFile: $0.path) }
            }
        }
        let outside = Set(candidates.filter { file in
            let project = boundary.project(of: file.path)
            // The root manifest declares the root package's targets only; another project's modules are not its to name.
            return !builtProjects.contains(project) || (project.isEmpty && (declared.map { !$0.contains(file.module) } ?? false))
        }.map(\.path))
        return (
            withoutUnit.map(\.path).filter { !outside.contains($0) }.sorted(),
            outside.sorted()
        )
    }

    /// The indexed test files no store holds a unit for, classified by whether any test file has one — what every `where` reader of them decides its advice and its axis on.
    func testFileCoverage(in index: IndexStore) throws -> TestFileCoverage {
        let testFiles = try index.fileInventory().values.filter { TestFileRecognition.isTestFile(imports: $0.imports) }
        let withoutUnit = testFiles.count { !anyStoreHasUnit(forFile: $0.path) }
        return TestFileCoverage(withoutUnit: withoutUnit, neverBuilt: withoutUnit > 0 && withoutUnit == testFiles.count, provenance: store.provenance)
    }

    /// The instant every staleness comparison is made against — the store's newest unit, nudged past equality so a file written in the same clock tick as the build reads as newer rather than as level with it.
    ///
    /// One expression, because the declaring-file refusal and the cited-file check must agree by construction on what "since the build" means; if each computed its own, the two halves of the same axis could disagree by a rounding.
    var buildAnchor: Double {
        Self.buildAnchor(newestUnit: store.newestUnitDate)
    }

    /// The same expression for a reader that judges the axis without an open store — `status`, which must agree with a query about what "since the build" means and never opens one to find out.
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
