//
// Copyright © Agulhas Labs
//

import Foundation

/// The one filesystem walk that finds every build file module resolution reads.
///
/// It stands in for three walks with three different policies, and all three belong here: a discovery walk left behind as its own config-blind, depth-unbounded, hidden-descending pass is worse than either end state, because the axis nobody audited then reads as audited. All three are here under one policy: config filters honoured, bundles closed, symlinked directories followed, and a size cap so a monorepo's Helm charts are not read to be rejected.
struct BuildFileScan {
    /// Directory extensions that are files as far as a source tree is concerned.
    static let bundleExtensions: Set<String> = [
        "xcodeproj", "xcworkspace", "xcassets", "app", "framework", "bundle", "playground", "docc", "lproj",
    ]

    /// A spec is single-digit KB; anything larger is a data file that happens to be YAML.
    static let candidateByteCap = 512 * 1024

    /// Directories below the repo root a build file may sit in before it is a fixture or a sample rather than the build.
    ///
    /// Deliberately generous: `apps/ios/Modules/Feature/Parcel/Parcel.yml` is six components deep and is exactly the layout this exists to read, so a bound tight enough to be tidy is the name-based assumption again wearing a number. The cost of a wider bound is directory reads that `contentsOfDirectory` already makes cheap; the cost of a narrow one is silent — a build file past it is never visited, so it cannot even be reported as a near miss.
    static let maximumDepth = 8

    var xcodeProjects: [URL] = []
    var yamlCandidates: [URL] = []
    var packageManifests: [URL] = []
    /// Every directory the walk entered, so the engine can notice a build file *appearing* in one.
    var directories: [URL] = []

    static func run(repoRoot: URL, config: SiftConfig) -> BuildFileScan {
        var scan = BuildFileScan()
        // Canonical, not merely standardized: `repoRoot` typically already arrives as git's own
        // fully-resolved real path (`/private/tmp/…` under a worktree whose container is `/tmp`), and
        // `standardizedFileURL` would strip that `/private` back off — mismatching every entry below,
        // which is built by appending onto the *un*-standardized `repoRoot` and so keeps it. `relative`
        // below canonicalises both its arguments the same way, so neither side can drift from the other.
        let rootPath = CanonicalPath.of(repoRoot.path)
        // What the entries of the root's own listing hang from: the root canonicalised *through* any link at its end,
        // since a canonical path leaves a final symlink unresolved while every child's path resolves it.
        let rootBase = CanonicalPath.of(repoRoot.resolvingSymlinksInPath().path)
        // Logical URL for reporting, physical for reading: `contentsOfDirectory` through a symlink returns *empty*,
        // so a symlinked module tree is invisible unless the resolved path is the one enumerated, while every path
        // this hands back has to stay under the repository root to be repo-relative at all.
        var frontier = [(logical: repoRoot, physical: repoRoot.resolvingSymlinksInPath(), base: rootBase, depth: 0)]
        var enteredPhysical: Set<String> = [repoRoot.resolvingSymlinksInPath().path]
        scan.directories = [repoRoot]
        while let (logical, physical, base, depth) = frontier.popLast() {
            guard depth <= maximumDepth else { continue }
            let contents = (try? FileManager.default.contentsOfDirectory(
                at: physical,
                includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey],
                options: [.skipsHiddenFiles]
            )) ?? []
            for entry in contents {
                let values = try? entry.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey])
                let name = entry.lastPathComponent
                let entryLogical = logical.appendingPathComponent(name)
                // `.isDirectoryKey` is false for a symlink *to* a directory, so without this a repo that symlinks a
                // shared module tree would have none of its build files discovered, and a symlinked `.xcodeproj` would
                // be dropped rather than collected.
                var isDirectory = values?.isDirectory == true
                if values?.isSymbolicLink == true {
                    var flag: ObjCBool = false
                    isDirectory = FileManager.default.fileExists(atPath: entry.path, isDirectory: &flag) && flag.boolValue
                }
                let entryCanonical = Self.derivedPath(
                    of: entryLogical, name: name, parentCanonical: base, isSymbolicLink: values?.isSymbolicLink
                )
                let relativePath = Self.relative(canonical: entryCanonical, toPath: rootPath)
                guard passes(relativePath, config: config) else { continue }

                if isDirectory {
                    guard !bundleExtensions.contains(entry.pathExtension.lowercased()) else {
                        if entry.pathExtension.lowercased() == "xcodeproj" {
                            scan.xcodeProjects.append(entryLogical)
                        }
                        continue
                    }
                    // A symlink pointing at an ancestor would otherwise walk forever.
                    let resolved = entry.resolvingSymlinksInPath()
                    guard enteredPhysical.insert(resolved.path).inserted else { continue }
                    let entryBase = isSymbolicLink(values) ? CanonicalPath.of(resolved.path) : entryCanonical
                    frontier.append((entryLogical, resolved, entryBase, depth + 1))
                    scan.directories.append(entryLogical)
                    continue
                }
                if name == "Package.swift" {
                    scan.packageManifests.append(entryLogical)
                    continue
                }
                guard ModuleResolver.yamlExtensions.contains(entry.pathExtension.lowercased()) else { continue }
                guard (values?.fileSize ?? 0) <= candidateByteCap else { continue }
                scan.yamlCandidates.append(entryLogical)
            }
        }
        scan.xcodeProjects.sort { $0.path < $1.path }
        scan.yamlCandidates.sort { $0.path < $1.path }
        scan.packageManifests.sort { $0.path < $1.path }
        scan.directories.sort { $0.path < $1.path }
        return scan
    }

    /// The config's own view of what is in scope, so a build file the user excluded cannot name modules for files the index will never hold.
    ///
    /// `roots` is deliberately **not** applied. Pruning the walk to the configured roots looks like free economy and is a regression: a build file in a *sibling* tree routinely declares sources inside a root — `Apps/App.xcodeproj` compiling `Modules/Feature` — and pruning `Apps/` makes it invisible where a walk that filters on nothing at all finds it.
    private static func passes(_ relativePath: String, config: SiftConfig) -> Bool {
        // The same rule the enumerator applies, stated rather than left to `skipsHiddenFiles` above: a build
        // file the index would never read sources for cannot be allowed to name modules, and the walk and the
        // enumeration have to agree about which those are.
        for component in relativePath.split(separator: "/") where SiftConfig.isExcludedPathComponent(component) {
            return false
        }
        for pattern in config.exclude where relativePath.contains(pattern) {
            return false
        }
        return true
    }

    /// Whether the walk must ask the filesystem about an entry rather than derive its path, which is any entry not known to be a plain file or directory.
    static func isSymbolicLink(_ values: URLResourceValues?) -> Bool {
        values?.isSymbolicLink != false
    }

    /// The canonical path of a walked entry: its parent's canonical path plus its own name, unless it is a symlink.
    ///
    /// The directory listing already spells the name in its on-disk case and the parent is canonical, so only a symbolic link, or an entry whose type is unknown, needs the filesystem asked again.
    static func derivedPath(of logical: URL, name: String, parentCanonical: String, isSymbolicLink: Bool?) -> String {
        guard isSymbolicLink == false else { return CanonicalPath.of(logical.path) }
        return parentCanonical == "/" ? "/" + name : parentCanonical + "/" + name
    }

    /// Repo-relative form of an already canonical path, against a root canonicalised once for the whole walk (.agents/CodingGuidelines.md: "paths are canonicalised at comparison time, never at write time").
    private static func relative(canonical path: String, toPath rootPath: String) -> String {
        guard path.hasPrefix(rootPath) else { return path }
        var trimmed = Substring(path.dropFirst(rootPath.count))
        while trimmed.hasPrefix("/") {
            trimmed = trimmed.dropFirst()
        }
        return String(trimmed)
    }
}
