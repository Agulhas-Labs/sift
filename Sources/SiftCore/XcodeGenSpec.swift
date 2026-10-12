//
// Copyright © Agulhas Labs
//

import Foundation
import Yams

/// An XcodeGen spec, read far enough to say which module each source path belongs to.
///
/// Identifying one by *name* does not work: `project.yml` is XcodeGen's default, `--spec` takes any path, and a monorepo may name each spec after its product. Identifying one by shape has a trap of its own — a target's `sources` may arrive from a `targetTemplates` entry or from an `include`d fragment, neither of which is written in the target's own mapping, so requiring an inline `sources` would reject the whole document and report it as "not a spec" while it plainly is one.
///
/// So the reading is done properly: includes are followed and merged, templates are applied, and a document that has targets but no resolvable sources is a *distinct* outcome from a document that is not a spec at all — because those two need opposite things said about them.
struct XcodeGenSpec {
    /// How many `include:` hops to follow before treating the chain as a cycle.
    static let maximumIncludeDepth = 4

    /// True when a document is worth parsing at all — the byte test that keeps a monorepo's YAML out of the parser.
    ///
    /// It has to admit `include:` as well as `targets:`, since the whole point of an include is that the parent declares no targets of its own.
    static func mayBeSpec(_ text: String) -> Bool {
        text.contains("targets:") || text.contains("include:")
    }

    /// `text` is the caller's already-loaded bytes: every candidate is read once, which is the whole point of the prefilter that precedes this.
    static func read(at url: URL, text: String) -> Reading {
        var visited: Set<String> = []
        guard let merged = load(at: url, text: text, depth: 0, visited: &visited) else { return .notASpec }
        guard !merged.targets.isEmpty else { return .notASpec }

        var targets: [Target] = []
        // The xcconfigs a module name was read from are inputs like the spec itself: left unstamped, an edited
        // `PRODUCT_MODULE_NAME` would keep the old name confidently until something else changed. One named but not
        // there yet is kept too, so creating it re-attributes.
        var configFiles = Set(merged.project.configFiles.values.map(\.standardizedFileURL))
        for name in merged.targets.keys.sorted() {
            guard let declaration = merged.targets[name] else { continue }
            let resolved = apply(templates: merged.templates, to: declaration.body)
            guard let sources = resolved["sources"] else { continue }
            // A path carrying an unexpanded `${…}` attribute is a template placeholder this tool cannot substitute.
            // Mapping the literal text would claim a prefix no file has, which reads as a resolved module and is worse
            // than declaring nothing.
            let paths = sourcePaths(from: sources).filter { !$0.path.contains("${") }
            guard !paths.isEmpty else { continue }
            configFiles.formUnion(ProjectSettings.configFiles(in: resolved, directory: declaration.directory).values.map(\.standardizedFileURL))
            targets.append(Target(
                name: name,
                sources: paths,
                declaringDirectory: declaration.directory,
                module: ModuleNameSetting.outcome(
                    target: name,
                    configurations: configurationLevels(of: resolved, directory: declaration.directory, project: merged.project)
                )
            ))
        }
        let files = merged.files + configFiles.subtracting(merged.files).sorted { $0.path < $1.path }
        return targets.isEmpty ? .targetsWithoutSources : .spec(targets: targets, files: files)
    }

    // MARK: Merging

    /// One spec plus everything it includes, with the *including* document winning on a name collision, as XcodeGen resolves it.
    private static func load(at url: URL, text: String?, depth: Int, visited: inout Set<String>) -> Merged? {
        guard depth <= maximumIncludeDepth else { return nil }
        let key = url.standardizedFileURL.path
        guard !visited.contains(key) else { return nil }
        visited.insert(key)

        guard let text = text ?? (try? String(contentsOf: url, encoding: .utf8)),
              let yaml = try? Yams.load(yaml: text) as? [String: Any] else { return nil }
        let directory = url.deletingLastPathComponent()
        var merged = Merged()
        merged.files = [url.standardizedFileURL]

        for includePath in includePaths(from: yaml["include"]) {
            let includeURL = directory.appendingPathComponent(includePath).standardizedFileURL
            guard let included = load(at: includeURL, text: nil, depth: depth + 1, visited: &visited) else { continue }
            merged.targets.merge(included.targets) { _, new in new }
            merged.templates.merge(included.templates) { _, new in new }
            merged.files.append(contentsOf: included.files)
            merged.project = merged.project.overridden(by: included.project)
        }
        merged.project = merged.project.overridden(by: ProjectSettings(document: yaml, directory: directory))

        if let templates = yaml["targetTemplates"] as? [String: Any] {
            for (name, body) in templates {
                guard let body = body as? [String: Any] else { continue }
                merged.templates[name] = body
            }
        }
        if let targets = yaml["targets"] as? [String: Any] {
            for (name, body) in targets {
                guard let body = body as? [String: Any] else { continue }
                // The including document *overrides* the included one key by key; it does not replace it. Overwriting
                // wholesale would discard `sources` inherited through an include whenever the parent tweaked anything
                // else — the standard shared-fragment-plus-override monorepo shape, verified against xcodegen 2.46.0.
                if var existing = merged.targets[name] {
                    for (key, value) in body {
                        existing.body[key] = value
                    }
                    merged.targets[name] = existing
                } else {
                    merged.targets[name] = Declaration(body: body, directory: directory)
                }
            }
        }
        return merged
    }

    /// A target's own keys win over the templates it names, templates chain through their own `templates:`, and `sources` concatenates rather than being overridden.
    ///
    /// All three are how a monorepo actually shares a source layout (verified against xcodegen 2.46.0), and getting any of them wrong is silent: a template naming another template contributes nothing, or a target declaring its own `sources` beside a template's drops the template's directories — leaving files with a directory-name guess for a target that plainly declares them.
    private static func apply(templates: [String: [String: Any]], to target: [String: Any], depth: Int = 0) -> [String: Any] {
        guard depth <= maximumIncludeDepth, let names = target["templates"] as? [Any] else { return target }
        var resolved = target
        var accumulated = sourceValues(target["sources"])
        for name in names.compactMap({ $0 as? String }) {
            guard let template = templates[name] else { continue }
            let expanded = apply(templates: templates, to: template, depth: depth + 1)
            accumulated.append(contentsOf: sourceValues(expanded["sources"]))
            for (key, value) in expanded where resolved[key] == nil {
                resolved[key] = value
            }
        }
        if !accumulated.isEmpty {
            resolved["sources"] = accumulated
        }
        return resolved
    }

    /// A `sources` value as a list, whatever spelling it was written in, so the pieces can be concatenated.
    private static func sourceValues(_ value: Any?) -> [Any] {
        guard let value else { return [] }
        if let array = value as? [Any] {
            return array
        }
        return [value]
    }

    // MARK: Shapes

    /// Each of the project's configurations as levels of settings for one target, highest precedence first: the target's `settings`, its `configFiles` xcconfig, the project's `settings`, the project's `configFiles` xcconfig.
    ///
    /// The configurations are the project's `configs`, else XcodeGen's `Debug` and `Release`, and a `configs` or `configFiles` key names one case-insensitively, as XcodeGen matches it (measured with xcodegen 2.46.0: `debug:` applies to `Debug`).
    static func configurationLevels(of target: [String: Any], directory: URL, project: ProjectSettings) -> [[[String: Any]?]] {
        let names = project.configurationNames
        let targetFiles = ProjectSettings.configFiles(in: target, directory: directory)
        return names.map { name in
            [
                settingsLevel(target["settings"], configuration: name, among: names),
                configFileLevel(targetFiles, configuration: name),
                settingsLevel(project.settings, configuration: name, among: names),
                configFileLevel(project.configFiles, configuration: name),
            ]
        }
    }

    /// One `settings` mapping as it applies to `configuration`: `base` with the matching `configs` entry over it, or all of it where it has neither.
    ///
    /// `nil` where a settings group could set anything, or a `configs` key names no configuration, so its intent is not known.
    private static func settingsLevel(_ settings: Any?, configuration: String, among names: [String]) -> [String: Any]? {
        guard let settings = settings as? [String: Any] else { return [:] }
        guard ["base", "configs", "groups"].contains(where: { settings[$0] != nil }) else { return settings }
        guard settings["groups"] == nil else { return nil }
        var level = settings["base"] as? [String: Any] ?? [:]
        for (key, value) in settings["configs"] as? [String: Any] ?? [:] {
            guard names.contains(where: { $0.caseInsensitiveCompare(key) == .orderedSame }) else { return nil }
            guard key.caseInsensitiveCompare(configuration) == .orderedSame else { continue }
            guard let own = value as? [String: Any] else { return nil }
            level.merge(own) { _, own in own }
        }
        return level
    }

    private static func configFileLevel(_ files: [String: URL], configuration: String) -> [String: Any]? {
        guard let file = files.first(where: { $0.key.caseInsensitiveCompare(configuration) == .orderedSame })?.value else { return [:] }
        return ModuleNameSetting.xcconfigLevel(at: file)
    }

    /// `override` merged onto `base` key by key at every depth, the including document winning, as XcodeGen merges an included spec.
    static func deepMerged(_ base: Any?, _ override: Any?) -> Any? {
        guard let baseMapping = base as? [String: Any], let overrideMapping = override as? [String: Any] else { return override ?? base }
        return baseMapping.merging(overrideMapping) { old, new in deepMerged(old, new) ?? new }
    }

    /// `include:` may be a string, a list of strings, or a list of `{path:}` dictionaries.
    private static func includePaths(from value: Any?) -> [String] {
        guard let value else { return [] }
        if let path = value as? String {
            return [path]
        }
        guard let array = value as? [Any] else { return [] }
        return array.compactMap { element in
            if let path = element as? String {
                return path
            }
            return (element as? [String: Any])?["path"] as? String
        }
    }

    /// XcodeGen `sources` may be a string, a bare `{path:}` mapping, an array of strings, or an array of `{path:}` mappings.
    ///
    /// The bare-mapping spelling casts to neither `String` nor `[Any]`, so without its own case a legitimate spec written that way would produce no paths and be reported as declaring nothing — the "valid spelling read as declares-nothing" class this area is prone to.
    static func sourcePaths(from sources: Any) -> [Source] {
        if let path = sources as? String {
            return [Source(path: path, excludes: [])]
        }
        if let dictionary = sources as? [String: Any] {
            return source(from: dictionary).map { [$0] } ?? []
        }
        guard let array = sources as? [Any] else { return [] }
        return array.compactMap { element in
            if let path = element as? String {
                return Source(path: path, excludes: [])
            }
            if let dictionary = element as? [String: Any] {
                return source(from: dictionary)
            }
            return nil
        }
    }

    private static func source(from dictionary: [String: Any]) -> Source? {
        guard let path = dictionary["path"] as? String else { return nil }
        let excludes = (dictionary["excludes"] as? [Any])?.compactMap { $0 as? String } ?? []
        let includes = (dictionary["includes"] as? [Any])?.compactMap { $0 as? String } ?? []
        return Source(path: path, excludes: excludes, includes: includes, type: dictionary["type"] as? String)
    }
}

extension XcodeGenSpec {
    /// What a YAML document turned out to be.
    enum Reading: Equatable {
        /// No top-level `targets:` mapping — a CI workflow, a lint config, a chart.
        case notASpec
        /// A spec whose targets declare no source path this tool can resolve, which is the honest near miss.
        case targetsWithoutSources
        /// `files` is every document that contributed and every xcconfig a target's module name was read from.
        case spec(targets: [Target], files: [URL])
    }

    /// One target, with the directory of the file that declared it — `sources` are relative to *that*, not to the spec that included it.
    struct Target: Equatable {
        var name: String
        var sources: [Source]
        var declaringDirectory: URL
        /// What the target's `PRODUCT_MODULE_NAME` and `PRODUCT_NAME` settings make of its module name.
        var module: ModuleNameSetting.Outcome = .unset
    }

    /// One `sources` entry: the path it names, and the sub-paths it explicitly does not compile.
    ///
    /// `excludes` is not decoration. Without it a target over-claims a directory it does not build, and because a claimed prefix counts as *resolved* those files answer with the wrong module carrying no guessed banner — the confident wrong answer this area exists to prevent.
    struct Source: Equatable {
        var path: String
        var excludes: [String]
        /// The globs that, where there are any, a file must match to be compiled.
        var includes: [String] = []
        /// The source's `type:`, such as `folder`, where it names one.
        var type: String?
    }

    private struct Declaration {
        var body: [String: Any]
        var directory: URL
    }

    private struct Merged {
        var targets: [String: Declaration] = [:]
        var templates: [String: [String: Any]] = [:]
        /// Every file that contributed, so an included fragment is watched and fingerprinted like the spec that names it.
        var files: [URL] = []
        var project = ProjectSettings()
    }

    /// The project-wide keys that bear on a target's module name: `settings`, `configFiles` and the `configs` it declares.
    struct ProjectSettings {
        var settings: Any?
        /// Configuration name → xcconfig, resolved against the directory of the document that named it.
        var configFiles: [String: URL] = [:]
        var configs: Set<String>?

        init() {}

        init(document: [String: Any], directory: URL) {
            settings = document["settings"]
            configFiles = Self.configFiles(in: document, directory: directory)
            configs = (document["configs"] as? [String: Any]).map { Set($0.keys) }
        }

        var configurationNames: [String] {
            (configs ?? ["Debug", "Release"]).sorted()
        }

        /// This project with `other`'s keys over it, as an including document overrides the one it includes.
        func overridden(by other: Self) -> Self {
            var result = self
            result.settings = XcodeGenSpec.deepMerged(settings, other.settings)
            result.configFiles.merge(other.configFiles) { _, new in new }
            if let otherConfigs = other.configs {
                result.configs = (configs ?? []).union(otherConfigs)
            }
            return result
        }

        static func configFiles(in mapping: [String: Any], directory: URL) -> [String: URL] {
            var files: [String: URL] = [:]
            for case let (name, path as String) in mapping["configFiles"] as? [String: Any] ?? [:] {
                files[name] = directory.appendingPathComponent(path)
            }
            return files
        }
    }
}
