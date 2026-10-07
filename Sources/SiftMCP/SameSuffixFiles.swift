//
// Copyright © Agulhas Labs
//

import Foundation
import SiftCore

/// The Swift files under a repository whose paths end in one suffix, read from disk once per repository and suffix however many log lines or paths ask within one hook call.
///
/// A suffix target credits a file only where no other file the index could hold ends in it too (``DigestedFiles/FileNaming``), and each question would otherwise walk the tree again: six log lines for one target once cost a hook call its time budget.
final class SameSuffixFiles: @unchecked Sendable {
    /// How many entries one walk visits before it gives up: every entry counts, a directory or a file of any kind, so a tree of build output is as bounded as a tree of sources.
    let entryLimit: Int

    private let lock = NSLock()
    private var found: [String: [String]?] = [:]
    private var walkCount = 0

    init(entryLimit: Int = 20000) {
        self.entryLimit = entryLimit
    }

    /// How many walks of the disk this has made, one for each repository and suffix it was asked about.
    var walksMade: Int {
        lock.withLock { walkCount }
    }

    /// The canonical paths of the indexable Swift files under `repository` ending in `target` at a component boundary, at most two of them — enough to tell one from several — or `nil` where the walk failed or ran past ``entryLimit``, and so cannot say.
    ///
    /// Skips what the index never holds, by the indexer's own rule (``SiftConfig/isExcludedPathComponent(_:)``): hidden trees, and the vendored and build directories it names. A package directory — a `.playground`, a `.swiftpm` app — is walked into, since the index holds the Swift files inside one.
    func files(endingIn target: String, under repository: URL) -> [String]? {
        let key = CanonicalPath.of(repository.path) + "\n" + target
        lock.lock()
        defer { lock.unlock() }
        if let cached = found[key] {
            return cached
        }
        walkCount += 1
        let walked = walk(endingIn: "/" + target, under: repository)
        found[key] = .some(walked)
        return walked
    }

    private func walk(endingIn suffix: String, under repository: URL) -> [String]? {
        guard let walker = FileManager.default.enumerator(
            at: repository,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }
        var matched: [String] = []
        var visited = 0
        while let entry = walker.nextObject() as? URL {
            visited += 1
            guard visited <= entryLimit else { return nil }
            if SiftConfig.isExcludedPathComponent(entry.lastPathComponent) {
                walker.skipDescendants()
                continue
            }
            guard entry.pathExtension == "swift", entry.path.hasSuffix(suffix) else { continue }
            matched.append(CanonicalPath.of(entry.path))
            if matched.count > 1 {
                break
            }
        }
        return matched
    }
}
