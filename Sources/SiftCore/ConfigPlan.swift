//
// Copyright © Agulhas Labs
//

import Foundation

/// What `sift init` proposes for a repository it has just met.
///
/// The job is not to guess a whole configuration — it is to surface the one thing a monorepo silently gets wrong. Module resolution reads SwiftPM manifests, XcodeGen specs (any file name, identified by shape) and `.xcodeproj` targets; anything else (a Bazel target, a directory convention) falls through to "first path component", which is a guess presented as a fact. Every file still gets *a* module, so nothing errors and nothing looks wrong — `digest <Module>` is just quietly answering about a module that doesn't exist.
///
/// So the plan reports coverage honestly and proposes `moduleMap` entries only for the groups that fell through, each one marked as needing a human to supply the real target name. A proposal this tool cannot verify is a draft, not an answer.
public struct ConfigPlan: Sendable {
    /// Source files only — build manifests are counted in `manifestsScanned`, never here, so the resolved/unresolved arithmetic is over files that actually belong to a module.
    public let filesScanned: Int
    /// SwiftPM manifests among the scanned paths — inputs to module resolution, not subjects of it.
    public let manifestsScanned: Int
    /// SwiftPM manifests that contributed no module mapping at all — the parser found no literal target path and the convention directories are absent.
    ///
    /// Rendered loudly, because "repo has no build files" and "the manifest could not be read" must not look identical.
    public let unmappedManifests: [String]
    /// Top-level directories that contain Swift files.
    public let swiftDirectories: [String]
    /// Top-level directories that contain none, and would therefore be skipped by a `roots` allowlist.
    public let skippableDirectories: [String]
    /// Modules a build file actually declares, with the file count each covers.
    public let resolvedModules: [String: Int]
    /// Path groups with no declaring build file, ordered by file count.
    public let unresolvedGroups: [UnresolvedGroup]

    public var unresolvedFileCount: Int {
        unresolvedGroups.reduce(0) { $0 + $1.fileCount }
    }

    public var resolvedFileCount: Int {
        filesScanned - unresolvedFileCount
    }

    /// Builds the plan by resolving every indexable file against the layout the tool already understands.
    public static func make(repoRoot: URL, config: SiftConfig, paths: [String]) -> ConfigPlan {
        let resolver = ModuleResolver(repoRoot: repoRoot, config: config)
        var resolved: [String: Int] = [:]
        var unresolved: [String: Int] = [:]
        var swiftDirectories: Set<String> = []
        var hasLooseTopLevelFile = false
        var manifestCount = 0

        for path in paths {
            // A manifest is a build file that happens to be Swift. It belongs to no module by definition, so counting it as source — resolved or unresolved — would report either a problem with no fix or a covered file no module claims.
            guard !isBuildManifest(path) else {
                manifestCount += 1
                continue
            }
            if path.contains("/") {
                swiftDirectories.insert(topComponent(of: path))
            } else {
                hasLooseTopLevelFile = true
            }
            if let module = resolver.resolvedModule(for: path) {
                resolved[module, default: 0] += 1
            } else {
                unresolved[groupPrefix(of: path), default: 0] += 1
            }
        }

        let groups = unresolved
            .map { UnresolvedGroup(prefix: $0.key, fileCount: $0.value) }
            .sorted { ($1.fileCount, $0.prefix) < ($0.fileCount, $1.prefix) }
        // A `roots` allowlist would drop a Swift file sitting at the repo root, so it is only ever proposed when there is none to drop.
        let skippable = hasLooseTopLevelFile
            ? []
            : topLevelDirectories(of: repoRoot).filter { !swiftDirectories.contains($0) }

        return ConfigPlan(
            filesScanned: paths.count - manifestCount,
            manifestsScanned: manifestCount,
            unmappedManifests: resolver.unmappedManifests,
            swiftDirectories: swiftDirectories.sorted(),
            skippableDirectories: skippable,
            resolvedModules: resolved,
            unresolvedGroups: groups
        )
    }

    private static func isBuildManifest(_ path: String) -> Bool {
        SwiftPMManifest.isManifestPath(path)
    }

    /// The config this plan would write, merged onto `existing` so curated fields are never lost.
    ///
    /// Merged rather than replaced because `.sift.json` is hand-maintained — the module map is where a human supplies the target names this tool could only guess at — and an `init` that clobbered it would destroy work the tool told the user to invest.
    public func merged(onto existing: SiftConfig) -> SiftConfig {
        var config = existing
        if config.roots.isEmpty, !skippableDirectories.isEmpty {
            config.roots = swiftDirectories
        }
        for group in unresolvedGroups where config.moduleMap[group.prefix] == nil {
            config.moduleMap[group.prefix] = group.proposedModule
        }
        return config
    }

    private static func topComponent(of path: String) -> String {
        path.split(separator: "/").first.map(String.init) ?? path
    }

    /// The prefix a `moduleMap` entry would use: two components deep where the layout allows, since one is usually the repo area and two is usually the target — extended through a `Sources`/`Tests` directory sitting right below, so a tool's sources and its tests never merge into one proposed module.
    private static func groupPrefix(of path: String) -> String {
        let components = path.split(separator: "/").map(String.init)
        guard components.count > 2 else { return topComponent(of: path) }
        if components.count > 3, components[2] == "Sources" || components[2] == "Tests" {
            return components.prefix(3).joined(separator: "/")
        }
        return components.prefix(2).joined(separator: "/")
    }

    private static func topLevelDirectories(of repoRoot: URL) -> [String] {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: repoRoot,
            includingPropertiesForKeys: [.isDirectoryKey]
        )) ?? []
        return contents.compactMap { url in
            let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            let name = url.lastPathComponent
            guard isDirectory, !SiftConfig.isExcludedPathComponent(name) else { return nil }
            return name
        }.sorted()
    }
}

public extension ConfigPlan {
    /// A set of files sharing a path prefix that no build file claims.
    struct UnresolvedGroup: Sendable, Equatable {
        public let prefix: String
        public let fileCount: Int

        /// The name to write into `moduleMap` as a starting point — the prefix's last directory-like component, which is right often enough to be worth pre-filling and wrong often enough to be labelled a guess.
        ///
        /// A prefix ending in `Sources` names the tool directory above it; one ending in `Tests` appends the conventional `Tests` suffix to it — a guess like the rest, presented as one.
        public var proposedModule: String {
            let components = prefix.split(separator: "/").map(String.init)
            guard let last = components.last else { return prefix }
            guard components.count >= 2 else { return last }
            if last == "Sources" {
                return components[components.count - 2]
            }
            if last == "Tests" {
                return components[components.count - 2] + "Tests"
            }
            return last
        }
    }
}
