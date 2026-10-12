//
// Copyright © Agulhas Labs
//

import Foundation

/// Path-prefix → target-name mappings read straight out of an `.xcodeproj`, so an app built by Xcode needs no `moduleMap`.
///
/// This is the build file the largest repositories actually use: without reading it, every file of an app built by Xcode falls back to a directory-name guess, and a per-repository `sift init` is a remedy nobody runs across ten checkouts. A guess that arrives on time and names a module that does not exist is the one failure no count in the audit can see.
///
/// `project.pbxproj` is an OpenStep property list, which Foundation reads directly — no vendored parser, no regex over a format that nests.
struct XcodeProjectTargets {
    /// The prefix → module map one project contributes, already collapsed to directories where a directory is unanimous.
    static func mappings(projectPath: URL, repoRoot: URL) -> [String: String] {
        read(projectPath: projectPath, repoRoot: repoRoot).mappings
    }

    /// What one project contributes to module resolution.
    static func read(projectPath: URL, repoRoot: URL) -> Reading {
        guard let objects = objects(inProjectAt: projectPath) else { return Reading() }
        let sourceRoot = projectPath.deletingLastPathComponent()
        let parents = parentGroups(in: objects)

        var perFile: [String: String] = [:]
        var undeclared: Set<String> = []
        var configFiles: Set<URL> = []
        for value in objects.values {
            guard let target = value as? [String: Any], target["isa"] as? String == "PBXNativeTarget" else { continue }
            let (module, isDeclared) = moduleName(
                of: target,
                context: Context(objects: objects, parents: parents, sourceRoot: sourceRoot),
                configFiles: &configFiles
            )
            guard !module.isEmpty else { continue }
            if !isDeclared {
                undeclared.insert(module)
            }
            for path in sourcePaths(of: target, objects: objects, parents: parents, sourceRoot: sourceRoot, repoRoot: repoRoot) {
                // First target wins on a shared file. A file compiled into two targets has two module names and the
                // index stores one, so the tie is arbitrary either way — but it must be *stable*, and dictionary
                // iteration is not, so the winner is decided by name rather than by whichever target came out first.
                if let existing = perFile[path.key], existing <= module {
                    continue
                }
                perFile[path.key] = module
            }
        }
        return Reading(mappings: collapsed(perFile), undeclaredModules: undeclared, configFiles: configFiles.sorted { $0.path < $1.path })
    }

    /// A digest of what the projects *mean*, not of their bytes.
    ///
    /// XcodeGen rewrites every object UUID on each regeneration, so hashing `project.pbxproj` itself would move the resolution fingerprint — and re-attribute every file — each time anyone regenerated a project that says exactly what it said before.
    static func fingerprintContribution(of mappings: [String: String]) -> String {
        mappings
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: "\n")
    }

    // MARK: Reading

    private static func objects(inProjectAt projectPath: URL) -> [String: Any]? {
        let file = projectPath.appendingPathComponent("project.pbxproj")
        guard let data = try? Data(contentsOf: file) else { return nil }
        var format = PropertyListSerialization.PropertyListFormat.openStep
        let parsed = try? PropertyListSerialization.propertyList(from: data, options: [], format: &format)
        return (parsed as? [String: Any])?["objects"] as? [String: Any]
    }

    /// Child object ID → the group holding it, so a file reference can be walked back up to a path.
    private static func parentGroups(in objects: [String: Any]) -> [String: String] {
        var parents: [String: String] = [:]
        for (id, value) in objects {
            guard let group = value as? [String: Any],
                  let isa = group["isa"] as? String, isa.hasSuffix("Group"),
                  let children = group["children"] as? [Any]
            else { continue }
            for child in children {
                guard let childID = child as? String else { continue }
                parents[childID] = id
            }
        }
        return parents
    }

    /// The Swift module a target produces, as its configurations' `PRODUCT_MODULE_NAME` and `PRODUCT_NAME` settings name it, else the target name with the characters a module name cannot carry replaced, as the compiler itself does.
    ///
    /// `isDeclared` is false where a setting renames the module through a reference this tool cannot expand, or the configurations disagree: the target's name is kept as the likeliest module, but its files count as guessed.
    private static func moduleName(of target: [String: Any], context: Context, configFiles: inout Set<URL>) -> (name: String, isDeclared: Bool) {
        let objects = context.objects
        let name = target["name"] as? String ?? ""
        guard let listID = target["buildConfigurationList"] as? String,
              let list = objects[listID] as? [String: Any],
              let configurations = list["buildConfigurations"] as? [Any]
        else { return (C99ExtendedIdentifier.spelling(of: name), true) }
        // Highest precedence first: the target's settings, its xcconfig, then the project's configuration of the same
        // name and its xcconfig — an xcconfig's `PRODUCT_MODULE_NAME` outranks nothing the target sets itself.
        let projectConfigurations = objects.values
            .compactMap { $0 as? [String: Any] }
            .first { $0["isa"] as? String == "PBXProject" }
            .flatMap { ($0["buildConfigurationList"] as? String).flatMap { objects[$0] as? [String: Any] } }?["buildConfigurations"] as? [Any] ?? []
        let projectByName = Dictionary(
            projectConfigurations.compactMap { $0 as? String }.compactMap { objects[$0] as? [String: Any] }.map { ($0["name"] as? String ?? "", $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let levels = configurations
            .compactMap { $0 as? String }
            .compactMap { objects[$0] as? [String: Any] }
            .map { configuration in
                let project = projectByName[configuration["name"] as? String ?? ""] ?? [:]
                return [configuration, project].flatMap { level in
                    [level["buildSettings"] as? [String: Any] ?? [:], xcconfigLevel(of: level, context: context, configFiles: &configFiles)]
                }
            }
        return switch ModuleNameSetting.outcome(target: name, configurations: levels) {
        case .unset:
            (C99ExtendedIdentifier.spelling(of: name), true)
        case let .named(module):
            (module, true)
        case .unknown:
            (C99ExtendedIdentifier.spelling(of: name), false)
        }
    }

    /// A configuration's `baseConfigurationReference` xcconfig as a level: `[:]` where it names none, `nil` where it names one this tool cannot place or read.
    ///
    /// A file it places joins `configFiles` whether or not it reads, since creating or editing it changes the answer.
    private static func xcconfigLevel(of configuration: [String: Any], context: Context, configFiles: inout Set<URL>) -> [String: Any]? {
        guard let id = configuration["baseConfigurationReference"] as? String else { return [:] }
        guard let reference = context.objects[id] as? [String: Any],
              let file = resolve(node: reference, id: id, objects: context.objects, parents: context.parents, sourceRoot: context.sourceRoot)
        else { return nil }
        configFiles.insert(file.standardizedFileURL)
        return ModuleNameSetting.xcconfigLevel(at: file)
    }

    /// Every repo-relative Swift source path a target compiles, from its sources phase and from any folder it synchronizes.
    private static func sourcePaths(
        of target: [String: Any],
        objects: [String: Any],
        parents: [String: String],
        sourceRoot: URL,
        repoRoot: URL
    ) -> [(key: String, isDirectory: Bool)] {
        var paths: [(key: String, isDirectory: Bool)] = []

        // Xcode 16 folder-synchronized targets name a directory and compile whatever is in it — the whole mapping in
        // one entry, and the shape a modern project is most likely to use.
        for group in target["fileSystemSynchronizedGroups"] as? [Any] ?? [] {
            guard let groupID = group as? String, let node = objects[groupID] as? [String: Any] else { continue }
            guard let resolved = resolve(node: node, id: groupID, objects: objects, parents: parents, sourceRoot: sourceRoot),
                  let relative = repoRelative(resolved, repoRoot: repoRoot)
            else { continue }
            paths.append((relative, true))
        }

        for phase in target["buildPhases"] as? [Any] ?? [] {
            guard let phaseID = phase as? String,
                  let sources = objects[phaseID] as? [String: Any],
                  sources["isa"] as? String == "PBXSourcesBuildPhase"
            else { continue }
            for file in sources["files"] as? [Any] ?? [] {
                guard let buildFileID = file as? String,
                      let buildFile = objects[buildFileID] as? [String: Any],
                      let refID = buildFile["fileRef"] as? String,
                      let reference = objects[refID] as? [String: Any],
                      let resolved = resolve(node: reference, id: refID, objects: objects, parents: parents, sourceRoot: sourceRoot),
                      resolved.pathExtension == "swift",
                      let relative = repoRelative(resolved, repoRoot: repoRoot)
                else { continue }
                paths.append((relative, false))
            }
        }
        return paths
    }

    /// A file or group's location on disk, by walking the group chain that gives it its path.
    ///
    /// `sourceTree` says what each step is relative to: `<group>` to the parent, `SOURCE_ROOT` to the directory holding the project, `<absolute>` to nothing. The remaining trees (`SDKROOT`, `BUILT_PRODUCTS_DIR`, `DEVELOPER_DIR`) name things outside the repository, and a `nil` says so by returning nothing rather than by guessing a location.
    private static func resolve(
        node: [String: Any],
        id: String,
        objects: [String: Any],
        parents: [String: String],
        sourceRoot: URL
    ) -> URL? {
        var components: [String] = []
        var current: [String: Any]? = node
        var currentID: String? = id
        var hops = 0

        while let node = current, hops < 64 {
            hops += 1
            let tree = node["sourceTree"] as? String ?? "<group>"
            let path = node["path"] as? String
            if let path, !path.isEmpty {
                components.insert(path, at: 0)
            }
            switch tree {
            case "<absolute>":
                return URL(fileURLWithPath: components.joined(separator: "/"))
            case "SOURCE_ROOT", "<group>":
                break
            default:
                return nil
            }
            if tree == "SOURCE_ROOT" {
                return sourceRoot.appendingPathComponent(components.joined(separator: "/"))
            }
            guard let parentID = currentID.flatMap({ parents[$0] }) else { break }
            currentID = parentID
            current = objects[parentID] as? [String: Any]
        }
        guard !components.isEmpty else { return nil }
        return sourceRoot.appendingPathComponent(components.joined(separator: "/"))
    }

    private static func repoRelative(_ url: URL, repoRoot: URL) -> String? {
        let resolved = URL(fileURLWithPath: url.standardizedFileURL.path).path
        let root = repoRoot.standardizedFileURL.path
        guard resolved.hasPrefix(root + "/") else { return nil }
        return String(resolved.dropFirst(root.count + 1))
    }

    // MARK: Collapsing

    /// Per-file mappings reduced to the fewest prefixes that mean the same thing.
    ///
    /// The resolver matches by longest prefix with a linear scan per file, so leaving one entry per source file would make attribution quadratic on exactly the repositories this exists for. A directory whose mapped files all name one module becomes one entry; a directory that compiles into two targets keeps its files.
    static func collapsed(_ perFile: [String: String]) -> [String: String] {
        var modulesByDirectory: [String: Set<String>] = [:]
        for (path, module) in perFile {
            modulesByDirectory[directory(of: path), default: []].insert(module)
        }
        var result: [String: String] = [:]
        // In key order: a mixed directory can hold a path both as a mapped key and as the parent of mapped files, and
        // the later write wins, so dictionary order would pick the module and differ from one process to the next.
        for (path, module) in perFile.sorted(by: { $0.key < $1.key }) {
            let parent = directory(of: path)
            if modulesByDirectory[parent]?.count == 1, !parent.isEmpty {
                result[parent] = module
            } else {
                result[path] = module
            }
        }
        // One upward pass, so a target laid out as a tree of directories collapses to its root rather than to every
        // leaf. Deliberately not run to a fixed point: a second pass buys little on real layouts and could hoist a
        // mapping above a sibling directory that no target claims at all.
        var lifted = result
        // Grouped rather than filtered per parent: scanning every key for each candidate parent is quadratic in the
        // map, and the map is largest exactly where a directory is mixed and nothing collapsed in the pass above.
        var childrenByParent: [String: [String]] = [:]
        for prefix in result.keys {
            let parent = directory(of: prefix)
            guard !parent.isEmpty else { continue }
            childrenByParent[parent, default: []].append(prefix)
        }
        // In a fixed order: a parent lifted here can itself be a child lifted away by its own parent, so the outcome
        // hangs on which comes first, and dictionary order differs from one process to the next.
        for (parent, children) in childrenByParent.sorted(by: { $0.key < $1.key }) where children.count > 1 {
            let modules = Set(children.compactMap { result[$0] })
            guard modules.count == 1, let module = modules.first else { continue }
            for child in children {
                lifted.removeValue(forKey: child)
            }
            lifted[parent] = module
        }
        return lifted
    }

    private static func directory(of path: String) -> String {
        guard let index = path.lastIndex(of: "/") else { return "" }
        return String(path[path.startIndex ..< index])
    }
}

extension XcodeProjectTargets {
    /// The prefix → module map one project contributes, the modules in it named after their target only because the target's build settings rename it in a way this tool cannot read, and every xcconfig a module name was read from, there or not.
    struct Reading {
        var mappings: [String: String] = [:]
        var undeclaredModules: Set<String> = []
        var configFiles: [URL] = []
    }
}

private extension XcodeProjectTargets {
    /// What resolving a file reference needs: the project's objects, each child's group, and the directory holding the project.
    struct Context {
        var objects: [String: Any]
        var parents: [String: String]
        var sourceRoot: URL
    }
}
