//
// Copyright © Agulhas Labs
//

import Foundation

/// Enumerates the repo's indexable `.swift` files as canonical repo-relative paths.
///
/// The listing source is git (`ls-files --cached --others --exclude-standard`), so gitignored files are consistently outside the tool — the invalidation layer could never see their changes, and indexing what cannot be invalidated serves stale answers under a fresh header. The directory walk remains only as a fallback when git itself fails.
struct FileEnumerator {
    let repoRoot: URL
    let config: SiftConfig
    /// Produces the git-visible `.swift` list; injected so tests can fake it and non-engine callers can omit it.
    var gitListing: (() throws -> [String])?

    /// All indexable files, sorted for determinism; `includingManifests` adds the build manifests the index itself never stores, for `init`'s counted-apart report.
    func swiftFiles(includingManifests: Bool = false) -> [String] {
        if let listing = try? gitListing?() {
            return listing
                .filter { isIndexable(relativePath: $0) || (includingManifests && isCountableManifest($0)) }
                .sorted()
        }
        return walkedFiles(includingManifests: includingManifests)
    }

    /// `true` when the path should be indexed at all (used to filter git-status output through the same rules).
    ///
    /// Defined as the absence of an ``Exclusion`` rather than beside it, so the rule a miss answer names is by construction the rule that kept the file out.
    ///
    /// `modes` is where a symbolic link is read from: the working tree by default, and a revision's own tree for an answer about that revision.
    func isIndexable(relativePath: String, modes: Modes = .workingTree) -> Bool {
        exclusion(of: relativePath, modes: modes) == nil
    }

    /// The rule that keeps a repo-relative path out of the index, or `nil` when the path is indexable.
    ///
    /// `modes` is where a symbolic link is read from, as for ``isIndexable(relativePath:modes:)``.
    func exclusion(of relativePath: String, modes: Modes = .workingTree) -> Exclusion? {
        guard relativePath.hasSuffix(".swift") else { return .notSwift }
        // A build manifest is an input to module resolution, never a subject of it — indexing one mints a phantom module from its directory name and a guessed-module warning no moduleMap entry can clear.
        if SwiftPMManifest.isManifestPath(relativePath) {
            return .manifest
        }
        return alwaysExcludedPrefix(relativePath) ?? userConfigExclusion(relativePath) ?? symbolicLinkExclusion(relativePath, modes: modes)
    }

    /// Whether a path is itself a symbolic link, read the way the link rule reads it.
    func isSymbolicLink(_ relativePath: String, modes: Modes) -> Bool {
        symbolicLinkExclusion(relativePath, modes: modes) != nil
    }

    /// A path that is itself a symbolic link, read with `lstat` so the link is never followed, or from the revision's tree `modes` carries.
    ///
    /// Git tracks a link's own text, so an edit to the file behind it marks only that file dirty: a record held under the link's path would never be reparsed, and would go on citing lines the file no longer has. The file it points to is indexed under its own path, where the index covers it at all. At a revision the link's blob is its target's path, never Swift source, and a path that is a link today may have been a file then, or the reverse, so there the revision's own mode decides.
    private func symbolicLinkExclusion(_ relativePath: String, modes: Modes) -> Exclusion? {
        if case let .revision(links) = modes {
            return links.contains(relativePath) ? .symbolicLink : nil
        }
        var info = stat()
        guard lstat(repoRoot.appendingPathComponent(relativePath).path, &info) == 0 else { return nil }
        return info.st_mode & S_IFMT == S_IFLNK ? .symbolicLink : nil
    }

    /// A `.swift` file this repository's own `.sift.json` narrows away — never one the index would refuse for itself.
    ///
    /// The distinction exists for `affected`, which has to tell two silences apart. A generated `.build` source is not part of the question at all, so dropping it is right and saying so would be noise; a file under `web/` in a repo configured `roots: ["app"]` is a change to the working tree that this tool has *chosen* not to look at, and an answer that drops it silently says "nothing changed" about a tree that changed.
    func isNarrowedAwayByConfig(relativePath: String) -> Bool {
        relativePath.hasSuffix(".swift")
            && !SwiftPMManifest.isManifestPath(relativePath)
            && !isAlwaysExcluded(relativePath)
            && !passesUserConfig(relativePath)
    }

    /// A manifest that would be enumerable were it not a manifest — counted by `init`, never stored by the index.
    private func isCountableManifest(_ relativePath: String) -> Bool {
        SwiftPMManifest.isManifestPath(relativePath) && passesConfigFilters(relativePath)
    }

    private func passesConfigFilters(_ relativePath: String) -> Bool {
        !isAlwaysExcluded(relativePath) && passesUserConfig(relativePath)
    }

    /// The directories no configuration opts back in — build output, caches, vendored dependencies, and every hidden tree (``SiftConfig/isExcludedPathComponent(_:)``).
    private func isAlwaysExcluded(_ relativePath: String) -> Bool {
        alwaysExcludedPrefix(relativePath) != nil
    }

    /// The outermost path component no configuration opts back in, as the repo-relative prefix that ends in it.
    private func alwaysExcludedPrefix(_ relativePath: String) -> Exclusion? {
        let components = relativePath.split(separator: "/")
        guard let index = components.firstIndex(where: { SiftConfig.isExcludedPathComponent($0) }) else { return nil }
        let prefix = components[...index].joined(separator: "/")
        return components[index].hasPrefix(".") ? .hidden(prefix) : .vendored(prefix)
    }

    /// The narrowing this repository asked for: `exclude` substrings, then `roots` when it names any.
    private func passesUserConfig(_ relativePath: String) -> Bool {
        userConfigExclusion(relativePath) == nil
    }

    private func userConfigExclusion(_ relativePath: String) -> Exclusion? {
        if let pattern = config.exclude.first(where: { relativePath.contains($0) }) {
            return .configExclude(pattern)
        }
        guard !config.roots.isEmpty else { return nil }
        let inside = config.roots.contains { relativePath == $0 || relativePath.hasPrefix($0 + "/") }
        return inside ? nil : .outsideRoots(config.roots)
    }

    // MARK: Fallback walk

    private func walkedFiles(includingManifests: Bool) -> [String] {
        let rootURLs: [URL] = if config.roots.isEmpty {
            [repoRoot]
        } else {
            config.roots.map { repoRoot.appendingPathComponent($0) }
        }
        var paths: Set<String> = []
        for rootURL in rootURLs {
            collect(under: rootURL, includingManifests: includingManifests, into: &paths)
        }
        return paths.sorted()
    }

    private func collect(under rootURL: URL, includingManifests: Bool, into paths: inout Set<String>) {
        let fileManager = FileManager.default
        guard let enumerator = fileManager.enumerator(
            at: rootURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: []
        ) else { return }
        let rootPath = repoRoot.standardizedFileURL.path
        while let url = enumerator.nextObject() as? URL {
            let name = url.lastPathComponent
            let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            if isDirectory {
                if SiftConfig.isExcludedPathComponent(name) {
                    enumerator.skipDescendants()
                }
                continue
            }
            guard url.pathExtension == "swift" else { continue }
            let standardized = url.standardizedFileURL.path
            guard standardized.hasPrefix(rootPath + "/") else { continue }
            let relative = String(standardized.dropFirst(rootPath.count + 1))
            if isIndexable(relativePath: relative) || (includingManifests && isCountableManifest(relative)) {
                paths.insert(relative)
            }
        }
    }
}

extension FileEnumerator {
    /// Where a path's file mode is read when it is tested for a symbolic link.
    enum Modes: Equatable {
        /// The working tree, with `lstat`.
        case workingTree
        /// A revision's tree, as the paths it records as symbolic links (``GitContext/trackedEntries(at:)``).
        case revision(links: Set<String>)
    }

    /// Why the index leaves a path out — one case per rule ``isIndexable(relativePath:)`` applies, and one for git's ignore rules, which the git listing applies instead.
    ///
    /// A miss on a file that exists is answered with the rule, because "no indexed file matches" about a file on disk reads as "there is no such file", and the caller goes looking for one that was never missing.
    enum Exclusion: Equatable {
        /// Not a Swift source; the index parses nothing else.
        case notSwift
        /// A SwiftPM manifest: read to resolve modules, never stored as source.
        case manifest
        /// A hidden name, carried as the repo-relative prefix that ends in it.
        case hidden(String)
        /// A dependency or build-output directory, carried the same way.
        case vendored(String)
        /// Matched by one of the config's `exclude` substrings.
        case configExclude(String)
        /// Under none of the config's `roots`.
        case outsideRoots([String])
        /// A symbolic link, whose target git never reports as changed on the link's behalf.
        case symbolicLink
        /// Ignored by git, so absent from the listing the index is built from.
        ///
        /// Never returned by ``exclusion(of:)``, which asks nothing of git: only a caller that has asked git names it.
        case gitIgnored

        /// The rule, worded to follow "is not indexed —".
        var reason: String {
            switch self {
            case .notSwift:
                "the index holds Swift sources only"
            case .manifest:
                "it is a build manifest, which the index reads to resolve modules and never stores as source"
            case let .hidden(prefix):
                "\(prefix) is hidden, and a hidden path is never indexed"
            case let .vendored(prefix):
                "\(prefix) is a dependency or build-output directory, which the index never enters"
            case let .configExclude(pattern):
                "\(SiftPaths.configFileName) excludes paths containing \"\(pattern)\""
            case let .outsideRoots(roots):
                "\(SiftPaths.configFileName) limits the index to \(roots.joined(separator: ", "))"
            case .symbolicLink:
                "it is a symbolic link, and the index holds each file once, under the path git reports its edits on — ask for the file it points to"
            case .gitIgnored:
                "git ignores it"
            }
        }
    }
}
