//
// Copyright © Agulhas Labs
//

import Foundation

/// A past revision's Swift files that could bear on one question, parsed into a transient in-memory index — what `digest --at` and `where --at` answer from, never the store.
///
/// The chosen files are written under the cache directory so the renderers can read member bodies and call sites from them unchanged, and ``discard()`` removes them once the answer is built. Each file is parsed and its tree dropped before the next, as every parse is.
struct RevisionSnapshot {
    /// The revision as the caller wrote it.
    let revision: String
    /// The full hash of the commit it names.
    let commit: String
    /// The directory the chosen files were written into, laid out as the revision's tree.
    let root: URL
    /// The chosen files' declarations, in memory only.
    let store: IndexStore
    /// The chosen files, repo-relative and sorted.
    let paths: [String]
    /// Every Swift file at the revision that the index's own include and exclude rules would take.
    let candidates: Int

    /// Blobs read from git in one batch before the ones that bear on the question are kept; bounds what is held in memory at once.
    private static var batchSize: Int {
        256
    }

    /// The revision's commit hash and every indexable Swift file in its tree — what a module-name resolution and a read need in common, resolved once so the two agree.
    ///
    /// A revision git cannot read is refused in git's own words; one that names a tree or a file rather than a commit is refused too, since its paths would not be the repository's.
    static func indexableFiles(revision: String, git: GitContext, enumerator: FileEnumerator) throws -> (commit: String, paths: [String]) {
        guard !revision.hasPrefix("-") else {
            throw EngineError.revisionRefused("--at \(revision) is not a revision — pass a commit, branch or tag")
        }
        guard let commit = git.commitHash(revision) else {
            do {
                _ = try git.trackedPaths(at: revision)
            } catch let error as GitError {
                throw EngineError.revisionRefused("--at \(revision) names no commit in this repository — git says: \(error.detail)")
            }
            throw EngineError.revisionRefused("--at \(revision) names a tree or a file, not a commit — pass a commit, branch or tag")
        }
        let tree = try git.trackedEntries(at: commit)
        let paths = tree.paths.filter { enumerator.isIndexable(relativePath: $0, modes: .revision(links: tree.links)) }
        return (commit, paths)
    }

    /// Reads `revision`'s tree, keeping each indexable Swift file that `selecting` picks by path, whose text contains one of `names` or that `spelling` picks by its text, and parses those alone — `files` is the revision's already-resolved commit and indexable paths (``indexableFiles(revision:git:enumerator:)``).
    static func read(
        revision: String,
        files: (commit: String, paths: [String]),
        git: GitContext,
        resolver: ModuleResolver,
        selecting: (String) -> Bool,
        naming names: [String],
        spelling: (Data) -> Bool = { _ in false }
    ) throws -> RevisionSnapshot {
        let commit = files.commit
        let swiftFiles = files.paths
        let needles = names.filter { !$0.isEmpty }.map { Data($0.utf8) }
        let root = SiftPaths.cache(in: git.repoRoot).appendingPathComponent("at").appendingPathComponent(UUID().uuidString)
        var parsed: [ParsedFile] = []
        do {
            for start in stride(from: 0, to: swiftFiles.count, by: batchSize) {
                let batch = Array(swiftFiles[start ..< min(start + batchSize, swiftFiles.count)])
                let blobs = try git.blobs(batch.map { (rev: commit, path: $0) })
                for (offset, blob) in blobs.enumerated() {
                    let path = batch[offset]
                    guard let blob, selecting(path) || needles.contains(where: { blob.range(of: $0) != nil }) || spelling(blob) else { continue }
                    let url = root.appendingPathComponent(path)
                    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try blob.write(to: url)
                    if let file = FileParser.parse(absoluteURL: url, repoRelativePath: path) {
                        parsed.append(file)
                    }
                }
            }
            let store = try IndexStore(databasePath: IndexStore.inMemoryPath)
            try store.replaceFiles(parsed) { (resolver.module(for: $0), resolver.resolvedModule(for: $0) == nil) }
            return RevisionSnapshot(
                revision: revision,
                commit: commit,
                root: root,
                store: store,
                paths: parsed.map(\.path).sorted(),
                candidates: swiftFiles.count
            )
        } catch {
            Self.remove(root)
            throw error
        }
    }

    /// Removes the files written for this answer, and the directory holding every such answer once it is empty.
    func discard() {
        Self.remove(root)
    }

    private static func remove(_ root: URL) {
        try? FileManager.default.removeItem(at: root)
        rmdir(root.deletingLastPathComponent().path)
    }
}
