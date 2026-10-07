//
// Copyright © Agulhas Labs
//

import Foundation

/// The committed configuration at `<root>/.sift.json`; every field is optional and the tool is fully functional with no file present.
public struct SiftConfig: Codable, Sendable {
    /// Directory roots to index, relative to the repo root; empty means the whole repo.
    public var roots: [String]
    /// Path substrings to exclude, on top of the built-in defaults.
    public var exclude: [String]
    /// Longest-prefix path → module-name overrides, consulted before the build-layout heuristics.
    public var moduleMap: [String: String]
    /// Explicit index-store path for the semantic phase.
    public var indexStorePath: String?
    /// Executable names `sift run` treats as linters on top of the one built in, for a repository whose linter this tool has never heard of.
    ///
    /// A name only, as it stands in `arguments[0]` — the path it is invoked through is its caller's business, since recognition reads the last path component.
    public var linters: [String]

    public init() {
        roots = []
        exclude = []
        moduleMap = [:]
        indexStorePath = nil
        linters = []
    }

    /// The named directories no configuration opts back in — vendored dependencies and build output that happen to be visible.
    ///
    /// Only the *visible* ones are listed. Every hidden directory is excluded by the rule in ``isExcludedPathComponent(_:)`` instead of by name, so nothing needs adding here as a machine acquires another dotted tool directory.
    public static let defaultExcludedDirectories: Set<String> = ["Pods", "Carthage", "DerivedData", "node_modules"]

    /// Whether one component of a repo-relative path puts it outside the index, whatever the configuration says.
    ///
    /// **A hidden name — anything starting with `.` — is never indexed.** A list spelling out `.git`, `.build`, `.sift`, `.swiftpm` and `.claude` would be five instances of one rule and a name-by-name race against whichever tool stakes out a dotted directory next: source vendored under one of them indexes as a module named after the directory, and then every answer that touches it carries a guessed-module banner for something that is not part of the codebase at all. The rule is what such a list stands in for, so the rule is what is applied — and it holds for a hidden *file* too, which is what the build-file walk's `skipsHiddenFiles` does.
    ///
    /// Deliberately absolute rather than a default a repository could override: a hidden tree is build output, a cache, or somebody else's vendored copy, and none of the three is source this index could answer for honestly.
    public static func isExcludedPathComponent(_ name: some StringProtocol) -> Bool {
        name.hasPrefix(".") || defaultExcludedDirectories.contains(String(name))
    }

    /// Loads the repository's config, or the defaults when it has none; a malformed file is an error, not a silent default.
    ///
    /// Read through ``ConfigFile/url(repoRoot:)`` rather than by spelling the name here, so the file this finds is the one ``SiftPaths/config(in:)`` promises and the one every writer stamps.
    ///
    /// A key this version does not model is ignored rather than rejected: a config can carry a retired key such as `exemplars`, and a config that stopped loading over a retired key would take the module map and the excludes down with it.
    public static func load(repoRoot: URL) throws -> SiftConfig {
        let url = ConfigFile.url(repoRoot: repoRoot)
        guard FileManager.default.fileExists(atPath: url.path) else {
            return SiftConfig()
        }
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        return try decoder.decode(SiftConfig.self, from: data)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        roots = try container.decodeIfPresent([String].self, forKey: .roots) ?? []
        exclude = try container.decodeIfPresent([String].self, forKey: .exclude) ?? []
        moduleMap = try container.decodeIfPresent([String: String].self, forKey: .moduleMap) ?? [:]
        indexStorePath = try container.decodeIfPresent(String.self, forKey: .indexStorePath)
        linters = try container.decodeIfPresent([String].self, forKey: .linters) ?? []
    }
}
