//
// Copyright © Agulhas Labs
//

import Foundation

/// One bounded walk of a repository's ignored directories for the build directories an `xcodebuild -derivedDataPath` build leaves there, with what a later query needs to tell whether the walk still holds.
///
/// A build directory holds `Index.noindex` directly, and a gate puts it in or just below an ignored directory (`.build/runner-dd`), so the walk looks no further than ``levelBound`` levels below each ignored directory and never past ``IndexStoreDiscovery/inTreeDepthBound`` components below the root. It goes breadth first across every ignored directory at once, so the shallow places a build directory usually sits are all seen before any deep one, and it stops after ``visitCap`` directories: an ignored `node_modules` of sixty thousand directories costs what two thousand do. It never follows a symlink, never enters a directory holding `.git` (a nested checkout builds another tree), and never enters the tool's own cache directory, whose contents change on every query.
final class InTreeStoreWalk: Sendable {
    /// How many levels below an ignored directory a build directory may sit: the ignored directory itself, a child of it, or a grandchild.
    static let levelBound = 2
    /// The most directories one walk visits.
    static let visitCap = 2000

    /// The ignored directories git listed when the walk ran, which a later query compares against its own list.
    let ignored: [String]
    /// The modification date of each directory the walk visited, by repo-relative path: a directory created or removed anywhere the walk looked changes one of them.
    let stamps: [String: Date]
    /// The visited directories holding an `Index.noindex` entry, in path order: the build directories whose stores each query checks afresh.
    let candidates: [String]
    /// Whether the walk hit `visitCap` with directories still unvisited — the cap cut it short rather than the tree running out, so a store the walk never reached may still exist.
    let truncated: Bool

    init(ignored: [String], stamps: [String: Date], candidates: [String], truncated: Bool = false) {
        self.ignored = ignored
        self.stamps = stamps
        self.candidates = candidates
        self.truncated = truncated
    }

    /// How many directories the walk visited, never more than the cap it ran with.
    var visited: Int {
        stamps.count
    }

    /// Directory-name spellings a real `xcodebuild -derivedDataPath` build commonly leaves — checked case-insensitively so a directory bearing one of these, or already holding `Index.noindex`, is visited (and its own children explored) before a same-level directory that does not.
    private static let buildNameHints: Set<String> = [".build", "build", "deriveddata", "xcbuild", "out"]

    /// Whether `name` looks like build output by spelling alone — a cheap, filesystem-free test used to order the queue, never to decide a store is there.
    private static func namesLikelyBuildOutput(_ name: String) -> Bool {
        let lower = name.lowercased()
        return Self.buildNameHints.contains(lower) || lower.hasSuffix("-dd")
    }

    /// Walks down from each of `ignored`, breadth first, visiting at most `cap` directories.
    ///
    /// Two queues, not one: every directory that looks like build output by name, or already holds `Index.noindex`, goes in `priority` and is drained before `rest` is touched at all, so a real store under a build-named directory is found before the cap even when a same-level directory (a `node_modules`) is vastly wider. **Only a priority entry's children are ever listed** — a `rest` directory is visited (checked for `.git` and `Index.noindex` directly) but never enumerated, so a wide directory that does not look like build output costs one stat whatever it holds, not a listing of what it holds. Within a priority subtree, listing a directory's children stops once the queue already holds enough pending entries to spend the visits still available, and never fetches more children's dates than that leaves room for.
    static func walk(repoRoot: URL, ignored: [String], cap: Int = visitCap) -> InTreeStoreWalk {
        let depthBound = IndexStoreDiscovery.inTreeDepthBound
        let topLevel = ignored
            .filter { $0 != SiftPaths.directoryName && $0.split(separator: "/").count <= depthBound }
            .map { InTreeWalkEntry(path: $0, level: 0, modified: modificationDate(of: repoRoot.appendingPathComponent($0))) }
        var priority: [InTreeWalkEntry] = []
        var rest: [InTreeWalkEntry] = []
        for entry in topLevel {
            let url = repoRoot.appendingPathComponent(entry.path)
            let name = (entry.path as NSString).lastPathComponent
            let looksBuiltAlready = FileManager.default.fileExists(atPath: url.appendingPathComponent("Index.noindex").path)
            if looksBuiltAlready || namesLikelyBuildOutput(name) {
                priority.append(entry)
            } else {
                rest.append(entry)
            }
        }
        var stamps: [String: Date] = [:]
        var candidates: [String] = []
        var priorityNext = 0
        var restNext = 0
        // Set whenever a priority directory's children were left unlisted, or only partly listed, for the budget —
        // the queue draining cleanly at the end does not mean the tree was seen in full when this happened along
        // the way. A `rest` directory never lists its children at all, by design, so it never sets this.
        var listingCutShort = false
        while stamps.count < cap {
            let entry: InTreeWalkEntry
            let fromPriority: Bool
            if priorityNext < priority.count {
                entry = priority[priorityNext]
                priorityNext += 1
                fromPriority = true
            } else if restNext < rest.count {
                entry = rest[restNext]
                restNext += 1
                fromPriority = false
            } else {
                break
            }
            let path = entry.path
            stamps[path] = entry.modified ?? .distantPast
            let url = repoRoot.appendingPathComponent(path)
            guard !FileManager.default.fileExists(atPath: url.appendingPathComponent(".git").path) else { continue }
            if FileManager.default.fileExists(atPath: url.appendingPathComponent("Index.noindex").path) {
                candidates.append(path)
                continue
            }
            guard fromPriority, entry.level < levelBound, path.split(separator: "/").count < depthBound else { continue }
            let pending = (priority.count - priorityNext) + (rest.count - restNext)
            let listLimit = cap - stamps.count - pending
            guard listLimit > 0 else {
                listingCutShort = true
                continue
            }
            let (children, moreAvailable) = subdirectories(of: url, limit: listLimit)
            if moreAvailable {
                listingCutShort = true
            }
            for child in children {
                let childEntry = InTreeWalkEntry(path: path + "/" + child.name, level: entry.level + 1, modified: child.modified)
                if namesLikelyBuildOutput(child.name) {
                    priority.append(childEntry)
                } else {
                    rest.append(childEntry)
                }
            }
        }
        let truncated = listingCutShort || priorityNext < priority.count || restNext < rest.count
        return InTreeStoreWalk(ignored: ignored, stamps: stamps, candidates: candidates.sorted(), truncated: truncated)
    }

    /// Whether this walk still describes the tree: git lists the same ignored directories and every directory the walk visited has the date it had.
    func holds(repoRoot: URL, ignored current: [String]) -> Bool {
        guard current == ignored else { return false }
        return stamps.allSatisfy { path, date in
            Self.modificationDate(of: repoRoot.appendingPathComponent(path)) == date
        }
    }

    /// The directories directly inside `url`, by name and modification date, symlinks left out, at most `limit` of them stat'd — the rest of a wide directory's children are left unlisted rather than paying to stat every one only to discard most, and the second element of the pair says whether that happened.
    private static func subdirectories(of url: URL, limit: Int) -> (entries: [(name: String, modified: Date?)], moreAvailable: Bool) {
        guard limit > 0, let children = try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil) else { return ([], false) }
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey, .contentModificationDateKey]
        var result: [(name: String, modified: Date?)] = []
        for child in children.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            guard result.count < limit else { return (result, true) }
            guard let values = try? child.resourceValues(forKeys: keys),
                  values.isDirectory == true, values.isSymbolicLink != true else { continue }
            result.append((child.lastPathComponent, values.contentModificationDate))
        }
        return (result, false)
    }

    /// The modification date of the directory at `url`, or `nil` when there is none to read.
    private static func modificationDate(of url: URL) -> Date? {
        try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    }
}
