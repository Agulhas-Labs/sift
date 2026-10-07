//
// Copyright © Agulhas Labs
//

import Foundation

/// Judges each distinct occurrence path once per query, and remembers what the judging found.
///
/// Deletion is settled by one `stat` — cached per path, so a symbol with forty references in one file is statted once, and `stat` rather than `FileManager.attributesOfItem` for the same reason `SiftEngine.mtime(of:)` uses it.
///
/// Modification is settled from the *indexed* row's mtime — the very value the declaring-file refusal already compares against the same anchor — so the two halves of the axis agree by construction on what "written since the build" means, rather than one reading a stored mtime and the other a fresh stat. A path the index has no row for — a dependency's source, anything excluded — is left `.live` rather than judged on an mtime nothing vouches for: this reports what it can prove, and proves nothing about files outside the index. Deletion is the exception, because a missing file is a fact about the tree that needs no index row to establish.
final class OccurrenceFreshness {
    private let store: IndexStore
    /// The store's newest unit moment, already nudged past equality by the caller.
    private let buildAnchor: Double
    /// Absolute store path → repo-relative, so the indexed row can be found.
    private let relativePath: (String) -> String
    private var cache: [String: OccurrenceState] = [:]

    /// Distinct files found absent, and found newer than the build, keyed the same way refusals are (repo-relative where the path is inside the repo) so the header can union the two without counting one file twice.
    private(set) var deletedFiles: Set<String> = []
    private(set) var modifiedFiles: Set<String> = []
    /// How many `stat` calls this query actually paid for, which is what makes the cost claim checkable.
    private(set) var stats = 0

    init(store: IndexStore, buildAnchor: Double, relativePath: @escaping (String) -> String) {
        self.store = store
        self.buildAnchor = buildAnchor
        self.relativePath = relativePath
    }

    func state(of absolutePath: String) -> OccurrenceState {
        if let cached = cache[absolutePath] {
            return cached
        }
        let relative = relativePath(absolutePath)
        let resolved = resolve(absolutePath, relative: relative)
        cache[absolutePath] = resolved
        switch resolved {
        case .live: break
        case .deleted: deletedFiles.insert(relative)
        case .modifiedSinceBuild: modifiedFiles.insert(relative)
        }
        return resolved
    }

    private func resolve(_ absolutePath: String, relative: String) -> OccurrenceState {
        stats += 1
        var info = stat()
        guard stat(absolutePath, &info) == 0 else { return .deleted }
        guard let row = try? store.fileRow(path: relative) else { return .live }
        return row.mtime > buildAnchor ? .modifiedSinceBuild : .live
    }
}
