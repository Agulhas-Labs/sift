//
// Copyright © Agulhas Labs
//

import CryptoKit
import Foundation
import Yams

/// Maps repo-relative file paths to module names by longest prefix.
///
/// Mapping sources, all merged (config wins on ties via longest prefix): the explicit config map, every SwiftPM manifest's declared targets — an explicit literal `path:` first, the `Sources/<Target>` + `Tests/<Target>` convention beside it — every XcodeGen spec's target→sources entries, and every `.xcodeproj`'s native targets. All three build systems are *discovered*, none is expected at a fixed path or under a fixed name (Docs/Design.md §2).
struct ModuleResolver {
    /// Path prefix → module name, longest prefix consulted first.
    private let prefixMap: [(prefix: String, module: String)]
    /// Repo-relative SwiftPM manifests that contributed no mapping at all — no literal target path and nothing under the convention directories.
    ///
    /// Surfaced by `init`, because these files' modules will be guessed while a build file that should name them sits right there.
    let unmappedManifests: [String]
    /// What each build system contributed, reported by `status` when anything fell back to a guess.
    let survey: Survey
    /// Paths a target's `sources` entry explicitly excludes, which no prefix may resolve through.
    private let excludedPrefixes: [String]
    /// Repo-relative directories the build-file walk entered.
    ///
    /// Stamped by the engine alongside `inputPaths`, because a build file *appearing* is the case no input path can cover: adding `Apps/project.yml` to a repo that had none leaves nothing to compare, and `dirtySwiftFiles()` runs with a `-- '*.swift'` pathspec so no `.yml` can arrive that way either. Candidates are discovered rather than fixed, so there is no known path to stamp before the file exists; a directory's mtime moving when an entry is created is what catches it.
    let watchedDirectories: [String]

    /// Repo-relative paths of every resolution input read at construction — the manifests and XcodeGen specs found.
    ///
    /// The engine stats these between queries to notice a mid-session edit cheaply.
    let inputPaths: [String]

    /// Repo-relative directories holding a build file of their own — a SwiftPM manifest, an XcodeGen spec that resolved targets, an `.xcodeproj` — the root as the empty string; a file belongs to the project of the deepest one enclosing it.
    ///
    /// Not part of the fingerprint: it changes no module attribution, and every file it is read from is already hashed by path.
    let projectDirectories: [String]
    /// Content digest of everything module attribution depends on that lives OUTSIDE the source files: the resolver's own logic version, every manifest's bytes, the XcodeGen files' bytes, and the config `moduleMap`.
    ///
    /// Source-content invalidation can never catch these inputs changing, which is how an upgraded binary (or an edited manifest) would serve stale per-file modules forever. The engine compares this against the value stored in the index and re-attributes every file on mismatch.
    let fingerprint: String

    /// Bumped when resolution *logic* changes meaning, so an upgraded binary re-attributes an existing index without waiting for any input file to change.
    ///
    /// 2: syntactic manifest parsing + manifest exclusion.
    ///
    /// 3: `.xcodeproj` targets read directly — this is the mechanism that spares anyone a per-repository `sift init` after an upgrade, since bumping it re-attributes every existing index on its next query.
    ///
    /// 4: XcodeGen specs discovered anywhere in the tree and identified by *shape* rather than by name — the file may be called anything, `--spec` takes any path — and their `sources` resolved against the spec's own directory.
    static let logicVersion = 4

    init(repoRoot: URL, config: SiftConfig) {
        var accumulator = Accumulator()
        let scan = BuildFileScan.run(repoRoot: repoRoot, config: config)
        watchedDirectories = scan.directories.map { Self.relative($0, to: repoRoot) }
        Self.addSwiftPMTargets(manifests: scan.packageManifests, repoRoot: repoRoot, into: &accumulator)
        Self.addXcodeGenTargets(specs: scan.yamlCandidates, repoRoot: repoRoot, into: &accumulator)
        Self.addXcodeProjectTargets(projects: scan.xcodeProjects, repoRoot: repoRoot, into: &accumulator)
        var map = accumulator.map
        var hasher = accumulator.hasher
        let unmapped = accumulator.unmappedManifests
        let inputs = accumulator.inputPaths
        let exclusions = accumulator.excluded
        let found = accumulator.survey
        survey = found
        for (prefix, module) in config.moduleMap.sorted(by: { $0.key < $1.key }) {
            map[Self.normalized(prefix)] = module
            hasher.update(data: Data("map:\(prefix)=\(module)\n".utf8))
        }
        prefixMap = map
            .map { (prefix: $0.key, module: $0.value) }
            .sorted { $0.prefix.count > $1.prefix.count }
        excludedPrefixes = exclusions.sorted()
        unmappedManifests = unmapped.sorted()
        inputPaths = inputs.sorted()
        projectDirectories = Set(accumulator.projectDirectories).sorted()
        let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        fingerprint = "v\(Self.logicVersion):\(digest)"
    }

    /// The module for a repo-relative path; falls back to the first path component when nothing matches.
    func module(for relativePath: String) -> String {
        resolvedModule(for: relativePath)
            ?? relativePath.split(separator: "/").first.map(String.init) ?? relativePath
    }

    /// The module a build file actually declares for this path, or `nil` when only the fallback applies.
    ///
    /// The distinction is invisible in `module(for:)` by design — every file gets *a* module either way — but it is the whole question `init` asks. A fallback module is a guess from the directory name, so `digest <Module>` and `where Module.Type` are wrong for those files in a way nothing in the output admits.
    func resolvedModule(for relativePath: String) -> String? {
        for entry in prefixMap {
            guard relativePath == entry.prefix || relativePath.hasPrefix(entry.prefix + "/") else { continue }
            // A longer `excludes:` match beats the directory that claimed it — the target says outright it does not
            // compile this file, and claiming it anyway is a wrong answer wearing a resolved module's confidence.
            let excludedByLongerRule = excludedPrefixes.contains { exclusion in
                exclusion.count > entry.prefix.count
                    && (relativePath == exclusion || relativePath.hasPrefix(exclusion + "/"))
            }
            return excludedByLongerRule ? nil : entry.module
        }
        return nil
    }

    // MARK: Sources

    private static func addSwiftPMTargets(manifests: [URL], repoRoot: URL, into accumulator: inout Accumulator) {
        for manifestDirectory in manifests.map({ $0.deletingLastPathComponent() }) {
            let relativeBase = relative(manifestDirectory, to: repoRoot)
            let manifestPath = [relativeBase, "Package.swift"].filter { !$0.isEmpty }.joined(separator: "/")
            accumulator.projectDirectories.append(relativeBase)
            let bytes = FileManager.default.contents(atPath: manifestDirectory.appendingPathComponent("Package.swift").path) ?? Data()
            accumulator.inputPaths.append(manifestPath)
            accumulator.hasher.update(data: Data("manifest:\(manifestPath)\n".utf8))
            accumulator.hasher.update(data: bytes)
            var mapped = 0
            // Declared targets first: an explicit `path:` is the manifest saying exactly where a target lives, which the convention scan below cannot see — the whole failure mode of a `<Tool>/Sources/<Tool>` layout.
            for target in SwiftPMManifest.parse(source: String(data: bytes, encoding: .utf8) ?? "").targets {
                guard let path = target.path else { continue }
                let prefixComponents = [relativeBase, normalized(path)].filter { !$0.isEmpty }
                accumulator.map[prefixComponents.joined(separator: "/")] = target.name
                mapped += 1
            }
            for sourcesName in ["Sources", "Tests"] {
                let sourcesURL = manifestDirectory.appendingPathComponent(sourcesName)
                guard let targets = try? FileManager.default.contentsOfDirectory(
                    at: sourcesURL,
                    includingPropertiesForKeys: [.isDirectoryKey]
                ) else { continue }
                for targetURL in targets {
                    let isDirectory = (try? targetURL.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                    guard isDirectory else { continue }
                    let prefixComponents = [relativeBase, sourcesName, targetURL.lastPathComponent]
                        .filter { !$0.isEmpty }
                    let prefix = prefixComponents.joined(separator: "/")
                    // The convention is a guess from a directory name; a target the manifest *declared* for the same path is a statement. Never let the guess overwrite the statement — `.target(name: "Renamed", path: "Sources/Lib")` must beat the `Lib` the directory implies.
                    guard accumulator.map[prefix] == nil else { continue }
                    accumulator.map[prefix] = targetURL.lastPathComponent
                    mapped += 1
                }
            }
            if mapped > 0 {
                accumulator.survey.swiftPMManifests += 1
            }
            if mapped == 0 {
                accumulator.unmappedManifests.append(manifestPath)
            }
        }
    }

    /// The extensions a spec can carry, since a spec's *name* carries no information at all.
    static let yamlExtensions: Set<String> = ["yml", "yaml"]

    /// Targets from every XcodeGen spec in the repository, discovered rather than guessed at a fixed path or a fixed name.
    ///
    /// A hard-coded `["project.yml", "Apps/project.yml"]` would be one project's own layout, in a resolver whose headline constraint is a large monorepo that follows none of its conventions. Discovering `project.yml` anywhere is only half of it, since a monorepo may name its specs after their products; and identifying one by shape still leaves a third case, since a target's `sources` may arrive from a template or an include. ``XcodeGenSpec`` does the reading; this decides what each source path means on disk.
    private static func addXcodeGenTargets(specs: [URL], repoRoot: URL, into accumulator: inout Accumulator) {
        for spec in specs {
            guard let text = try? String(contentsOf: spec, encoding: .utf8) else {
                accumulator.survey.unreadableCandidates += 1
                continue
            }
            guard XcodeGenSpec.mayBeSpec(text) else { continue }
            let targets: [XcodeGenSpec.Target]
            let contributingFiles: [URL]
            switch XcodeGenSpec.read(at: spec, text: text) {
            case .notASpec:
                // A document that names `targets:` or `include:` and still will not parse is a spec someone has to
                // fix — a tab in the indentation, a duplicate key, a multi-document `---`. Counting it as "not a
                // spec" would print the undiagnosable status the Survey exists to replace.
                if text.contains("targets:") {
                    accumulator.survey.unparsableSpecs += 1
                }
                continue
            case .targetsWithoutSources:
                accumulator.survey.specsWithoutResolvableSources += 1
                continue
            case let .spec(found, files):
                targets = found
                contributingFiles = files
            }

            let base = electedBase(for: targets, repoRoot: repoRoot)
            var derived: [String: String] = [:]
            var derivedExclusions: [String] = []
            for target in targets.sorted(by: { $0.name < $1.name }) {
                for source in target.sources {
                    guard let prefix = prefix(of: source.path, target: target, base: base, repoRoot: repoRoot) else { continue }
                    if let existing = derived[prefix], existing <= target.name {
                        continue
                    }
                    derived[prefix] = target.name
                    for exclude in source.excludes {
                        derivedExclusions.append(normalized(prefix + "/" + exclude))
                    }
                }
            }
            guard !derived.isEmpty else {
                accumulator.survey.specsWithoutResolvableSources += 1
                continue
            }

            accumulator.survey.xcodeGenSpecs += 1
            accumulator.projectDirectories.append(relative(spec.deletingLastPathComponent(), to: repoRoot))
            // Every contributing file, not just the one that names them: a fragment reached through `include:` decides
            // module names too, so leaving it unstamped would mean editing it changed nothing until the process restarted.
            for file in contributingFiles {
                let relativeFile = relative(file, to: repoRoot)
                guard !relativeFile.hasPrefix("/"), !relativeFile.hasPrefix("..") else { continue }
                accumulator.inputPaths.append(relativeFile)
                accumulator.hasher.update(data: Data("xcodegen:\(relativeFile)\n".utf8))
            }
            for (prefix, module) in derived.sorted(by: { $0.key < $1.key }) {
                accumulator.hasher.update(data: Data("\(prefix)=\(module)\n".utf8))
                accumulator.map[prefix] = module
            }
            accumulator.excluded.append(contentsOf: derivedExclusions)
            for exclusion in derivedExclusions.sorted() {
                accumulator.hasher.update(data: Data("exclude:\(exclusion)\n".utf8))
            }
        }
    }

    /// Which directory a spec's `sources` are written against, decided once for the whole spec.
    ///
    /// XcodeGen resolves a source path against the spec's own directory; the `--root` flag moves that base for the whole invocation, which is how a generated top-level `Apps/project.yml` is written. Deciding **per path** does not work: guarding the fallback to the spec's own subtree — which stops a stale entry hijacking a same-named top-level directory — also rejects the main case the fallback exists for, a `--root` spec naming a sibling tree like `Packages/Shared`. One spec is generated with one base, so electing per spec resolves both: the spec's own directory wins unless *nothing at all* resolves under it.
    private static func electedBase(for targets: [XcodeGenSpec.Target], repoRoot: URL) -> Base {
        for target in targets {
            for source in target.sources {
                let candidate = normalized(relative(target.declaringDirectory.appendingPathComponent(source.path).standardizedFileURL, to: repoRoot))
                if !candidate.isEmpty, FileManager.default.fileExists(atPath: repoRoot.appendingPathComponent(candidate).path) {
                    return .specDirectory
                }
            }
        }
        return .repositoryRoot
    }

    /// The repo-relative prefix one `sources` entry names, or `nil` when it names nothing usable.
    ///
    /// An empty prefix — what `sources: .` on a root spec produces — is rejected rather than stored: `resolvedModule` matches on `path == prefix` or `hasPrefix(prefix + "/")`, neither of which an empty string can satisfy, so it would count as a contribution while resolving nothing and print a survey line that reads healthy beside 100% guessed.
    private static func prefix(of path: String, target: XcodeGenSpec.Target, base: Base, repoRoot: URL) -> String? {
        let resolved = switch base {
        case .specDirectory:
            normalized(relative(target.declaringDirectory.appendingPathComponent(path).standardizedFileURL, to: repoRoot))
        case .repositoryRoot:
            normalized(path)
        }
        // `.` relativizes to the repository root, which is the empty prefix in every spelling it reaches here.
        guard !resolved.isEmpty, resolved != ".", !resolved.hasPrefix("/"), !resolved.hasPrefix("..") else { return nil }
        guard FileManager.default.fileExists(atPath: repoRoot.appendingPathComponent(resolved).path) else { return nil }
        return resolved
    }

    /// Targets read from every `.xcodeproj` in the repository — the build file the largest repositories use, read here so that it needs no hand-written `moduleMap`.
    ///
    /// Applied after XcodeGen so that where both exist the generated project, which is what actually builds, has the final say. The *derived mappings* go into the fingerprint rather than the file's bytes: XcodeGen rewrites every object UUID on regeneration, and re-attributing the whole index because a project was regenerated to say the same thing is churn for nothing.
    private static func addXcodeProjectTargets(projects: [URL], repoRoot: URL, into accumulator: inout Accumulator) {
        for project in projects {
            accumulator.projectDirectories.append(relative(project.deletingLastPathComponent(), to: repoRoot))
            let mappings = XcodeProjectTargets.mappings(projectPath: project, repoRoot: repoRoot)
            guard !mappings.isEmpty else {
                accumulator.survey.unreadableProjects += 1
                continue
            }
            accumulator.survey.xcodeProjects += 1
            let relativeProject = relative(project, to: repoRoot)
            accumulator.inputPaths.append(relativeProject + "/project.pbxproj")
            accumulator.hasher.update(data: Data("xcodeproj:\(relativeProject)\n".utf8))
            accumulator.hasher.update(data: Data(XcodeProjectTargets.fingerprintContribution(of: mappings).utf8))
            for (prefix, module) in mappings.sorted(by: { $0.key < $1.key }) where accumulator.map[normalized(prefix)] == nil {
                // First writer wins. Every project in the tree is discovered, so letting a later one have the final
                // say would let a vendored sample relabel a prefix a real manifest already owns — resolved-looking,
                // so no guessed banner.
                accumulator.map[normalized(prefix)] = module
            }
        }
    }

    private static func relative(_ url: URL, to root: URL) -> String {
        let rootPath = root.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        guard path.hasPrefix(rootPath) else { return path }
        return String(path.dropFirst(rootPath.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    private static func normalized(_ prefix: String) -> String {
        var trimmed = prefix.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        while trimmed.hasPrefix("./") {
            trimmed = String(trimmed.dropFirst(2))
        }
        return trimmed
    }
}

extension ModuleResolver {
    /// What the resolver looked for and what each build system actually contributed.
    ///
    /// A module-resolution defect shows in `status` as "100% guessed", and is not diagnosable from that alone while the report says what the answer *was* and never what had been searched for.
    ///
    /// Two things it deliberately does not do. It counts **contributions, not candidates** — a manifest whose targets all use computed paths, an `.xcodeproj` that failed to parse, and a spec that resolved nothing each count as zero, so the line beside "100% guessed" cannot itself read healthy. And it never reports a repository-wide YAML census: "carried no `targets:` declaring sources" means a document that really is a spec and really declares nothing this tool can resolve, which is the actionable near miss, while a CI workflow is simply not a spec and is not counted at all.
    struct Survey: Sendable, Equatable {
        /// SwiftPM manifests that mapped at least one target.
        var swiftPMManifests = 0
        /// XcodeGen specs that mapped at least one source path.
        var xcodeGenSpecs = 0
        /// Specs with targets whose sources this tool could not resolve — a template attribute, or a path naming nothing on disk.
        var specsWithoutResolvableSources = 0
        /// `.xcodeproj` files that contributed at least one mapping.
        var xcodeProjects = 0
        /// `.xcodeproj` files that yielded nothing, which usually means the format could not be read.
        var unreadableProjects = 0
        /// Candidate files that could not be read or decoded at all.
        var unreadableCandidates = 0
        /// Documents that name `targets:` and still would not parse — a spec someone has to fix.
        var unparsableSpecs = 0

        /// The line `status` prints beneath a guessed-module warning.
        var line: String {
            var parts = [
                "\(swiftPMManifests) SwiftPM manifest(s)",
                "\(xcodeGenSpecs) XcodeGen spec(s)",
                "\(xcodeProjects) .xcodeproj",
            ]
            if specsWithoutResolvableSources > 0 {
                parts.append("\(specsWithoutResolvableSources) spec(s) whose targets declare no source path found on disk")
            }
            if unreadableProjects > 0 {
                parts.append("\(unreadableProjects) .xcodeproj that could not be read")
            }
            if unparsableSpecs > 0 {
                parts.append("\(unparsableSpecs) spec(s) that would not parse")
            }
            if unreadableCandidates > 0 {
                parts.append("\(unreadableCandidates) file(s) that could not be read")
            }
            return "build files that named a module: " + parts.joined(separator: ", ")
        }
    }
}

extension ModuleResolver {
    /// The directory a spec's `sources` entries are written against.
    enum Base {
        case specDirectory
        case repositoryRoot
    }
}

extension ModuleResolver {
    /// Everything the three build systems accumulate while resolution is being built.
    ///
    /// One value rather than five parallel `inout` parameters: each collector needs all of them, and threading them separately pushes the signatures past the parameter limit.
    struct Accumulator {
        var map: [String: String] = [:]
        var excluded: [String] = []
        var unmappedManifests: [String] = []
        var inputPaths: [String] = []
        var projectDirectories: [String] = []
        var survey = Survey()
        var hasher = SHA256()
    }
}
