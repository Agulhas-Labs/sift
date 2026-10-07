//
// Copyright © Agulhas Labs
//

import Foundation
import SiftCore

/// Whether a path a command was pointed at is Swift source.
///
/// The gap this closes: `grep -rn "UsageLog" Sources/` names no `.swift` anywhere, so a classifier reading the command text alone cannot see it — and it is one of the commonest shapes a lookup takes. Deciding it needs the filesystem, which is why it is a type of its own rather than another regex: the callers that judge shell text stay pure, and this is injected.
///
/// Bounded on purpose. It stops at the first Swift file it sees, skips the directories that hold no source anyone greps for, and gives up after `visitLimit` entries rather than walking a home directory to the end. Giving up answers "no", which under-counts a miss — the direction that flatters the tool, and the only safe one for something running inside a hook on the path of a shell call.
public struct SwiftTree {
    /// Entries examined before this concludes "not Swift" regardless.
    ///
    /// A real source directory answers within a handful; the cap is for `grep -rn foo ~/`, where the honest answer is not worth the walk.
    static let visitLimit = 4000

    /// The directories whose Swift no index of a repository holds: build output, a dependency's checkout, and the trees the indexer leaves out by default (`SiftConfig.defaultExcludedDirectories`).
    ///
    /// **The one definition of "outside the indexed sources"**, read by every surface that has to agree about it: the hook lets a lookup of such a path through (``TextSearch``), the transcript scan scores the same lookup out of the share on the same verdict, and the audit files a refused call under it (`TranscriptScan.refusedCallShape`). It is also where this probe's own skipping starts, since a tree no index holds is never the subject of a source lookup either.
    static let neverIndexed: Set<String> = SiftConfig.defaultExcludedDirectories.union([".build", "checkouts"])

    /// Directories that are never the subject of a source lookup, and are the expensive ones to walk.
    private static let skipped: Set<String> = neverIndexed.union([".git", ".swiftpm", ".venv", "vendor"])

    /// Whether `path` lies outside every tree an index holds: under a directory ``neverIndexed`` names, wherever in the path it stands, or under the system's scratch directory `/tmp`.
    ///
    /// Read by component rather than by substring, so a file named `DerivedData.swift` is a file like any other. Hidden directories in general are not taken, although the indexer leaves a repository's own hidden trees out: a path is read here without knowing where its repository starts, and a worktree under `.claude/worktrees` is a repository of its own, which its own index holds whole.
    ///
    /// **Judged relative to `directory` — the call's own working directory — when both it and `path` are absolute.** The indexer excludes a `neverIndexed` name only relative to the repository it walks (`SiftConfig.isExcludedPathComponent`), so a repository that merely sits inside a directory named `checkouts` or `Pods` is indexed like any other, and Claude Code always hands a whole `Read` an absolute path: judging the raw path would refuse every file in such a repository. So the components `path` and `directory` share from the start are set aside first — dropped lexically, with no filesystem probe, since the scan reads this after the tree may be gone and both ends must reach the same verdict from the same two strings — and only what is left of `path` is checked against ``neverIndexed``. `.build/checkouts/kit/A.swift`, left over once the shared repository root is dropped, is still outside; `Sources/View.swift`, left over the same way, is inside. With no `directory`, or where `path` shares nothing with it, the whole path is judged, as before that residual is not fixed: a path in a wholly unrelated repository whose own ancestry happens to carry one of these names, seen from a `directory` sharing no prefix with it, still reads outside — nothing here can tell that repository's own excluded directories from the coincidence above it.
    public static func isOutsideIndexedSources(_ path: String, relativeTo directory: String? = nil) -> Bool {
        if path.hasPrefix("/tmp/") || path.hasPrefix("/private/tmp/") {
            return true
        }
        return judgedComponents(of: path, relativeTo: directory).contains { neverIndexed.contains($0) }
    }

    /// Directories the shared-prefix trick above must never absorb, because none of them is in practice a repository's own ancestor: a `cwd` under `.build/checkouts/kit`, `DerivedData` or `node_modules` names a dependency's or a build tool's tree, not a repository that merely sits inside a directory of that name.
    ///
    /// `checkouts`, `Pods` and `Carthage` keep the carve-out `judgedComponents` exists for — a repository can genuinely live inside one of those.
    private static let neverAnAncestor: Set<String> = [".build", "DerivedData", "node_modules"]

    /// The components of `path` actually judged against ``neverIndexed``: every component, or — once `path` and `directory` are both absolute — only the ones left after the longest run they share from the start, stopping short of any shared component named in ``neverAnAncestor``.
    private static func judgedComponents(of path: String, relativeTo directory: String?) -> [String] {
        let components = path.split(separator: "/").map(String.init)
        guard let directory, path.hasPrefix("/"), directory.hasPrefix("/") else { return components }
        let cwdComponents = directory.split(separator: "/").map(String.init)
        let shared = zip(components, cwdComponents).prefix { $0 == $1 && !neverAnAncestor.contains($0) }.count
        return Array(components.dropFirst(shared))
    }

    /// A probe bound to `directory`, or `nil` when there is no directory to resolve against.
    ///
    /// `nil` is the honest answer for a caller with no working directory, and it reads as "text only" everywhere it is passed — not as "no Swift here", which would be a claim this cannot make.
    ///
    /// Each probe remembers its own answers. One shell command is asked about by three separate readers — the counting guard, the window check and the advisor — and each walk costs up to ``visitLimit`` directory entries, so answering `Sources/` three times would be three walks of it. The memo belongs to the probe rather than to the type: a process-wide cache would have to decide when the filesystem had moved on, while a probe lives for one command and cannot go stale within it.
    public static func probe(relativeTo directory: String?) -> ((String) -> Bool)? {
        guard let directory else { return nil }
        var answers: [String: Bool] = [:]
        return { path in
            if let known = answers[path] {
                return known
            }
            let answer = holdsSource(at: path, relativeTo: directory)
            answers[path] = answer
            return answer
        }
    }

    /// Whether `path` is a Swift file, or a directory holding one.
    ///
    /// Relative paths resolve against `directory`, which is the session's working directory — the shell command was written to run there.
    public static func holdsSource(at path: String, relativeTo directory: String?) -> Bool {
        guard let resolved = resolve(path, relativeTo: directory) else { return false }
        if resolved.hasSuffix(".swift") {
            return FileManager.default.fileExists(atPath: resolved)
        }

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: resolved, isDirectory: &isDirectory), isDirectory.boolValue else {
            return false
        }
        return holdsSwiftFile(in: URL(fileURLWithPath: resolved))
    }

    /// A path made absolute, or `nil` when it cannot be — a relative path with no directory to resolve against is unanswerable, not "no".
    ///
    /// Not `private`: `ShellAdvice` resolves a command's own paths against the same `directory` before asking `DigestFloor` about them, and a second copy of this join would only invite the two readings to drift.
    public static func resolve(_ path: String, relativeTo directory: String?) -> String? {
        if path.hasPrefix("/") {
            return path
        }
        guard let directory, directory.hasPrefix("/") else { return nil }
        return URL(fileURLWithPath: directory).appendingPathComponent(path).standardizedFileURL.path
    }

    /// The file a read names, made absolute as the shell reads an unquoted operand: a bare `~` or a leading `~/` is the home directory, which ``resolve(_:relativeTo:)`` would join to `directory` instead; every other path is resolved as that does.
    ///
    /// What the checks of whether this context already holds a read file ask, so a `cat ~/…` of a held file is judged as its absolute spelling is. A `~user` prefix is left as written.
    public static func resolve(readPath path: String, relativeTo directory: String?) -> String? {
        guard path == "~" || path.hasPrefix("~/") else { return resolve(path, relativeTo: directory) }
        return URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL.path
    }

    /// Whether a Swift file lies anywhere under `root`, walked in a release pool of its own.
    ///
    /// **The pool is what closes the walk.** The walk stops at the first Swift file, while the enumerator still holds a directory handle for every level it descended into, and the enumerator comes back autoreleased: on a thread with no pool of its own to drain, a replay's main thread among them, it and its handles would live as long as the process.
    private static func holdsSwiftFile(in root: URL) -> Bool {
        autoreleasepool { walkForSwiftFile(in: root) }
    }

    private static func walkForSwiftFile(in root: URL) -> Bool {
        let keys: [URLResourceKey] = [.isDirectoryKey, .nameKey]
        guard let walk = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            return false
        }

        var visited = 0
        while let entry = walk.nextObject() as? URL {
            visited += 1
            guard visited <= visitLimit else { return false }
            let values = try? entry.resourceValues(forKeys: Set(keys))
            if values?.isDirectory == true {
                if skipped.contains(values?.name ?? entry.lastPathComponent) {
                    walk.skipDescendants()
                }
                continue
            }
            if entry.pathExtension == "swift" {
                return true
            }
        }
        return false
    }
}
