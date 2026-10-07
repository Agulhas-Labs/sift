//
// Copyright © Agulhas Labs
//

import Foundation

/// Builds the session-start primer: the guidance the tools need *before* the first raw file read, not after it.
///
/// This exists because the path-scoped user rule cannot arrive in time. `paths: ["**/*.swift"]` fires when a Swift file is touched, so the advice to reach for a digest instead of reading the file lands one step after the read it was meant to replace. A `SessionStart` hook is the only delivery guaranteed to precede the model's first turn, and it stays free in non-Swift sessions by resolving to `.none` and printing nothing.
///
/// The primer is deliberately a *primer*: the decision rule and this machine's roots, not the full contract. The path-scoped rule still carries the depth — freshness semantics, refusals, monorepo caveats — when Swift actually comes into play.
public struct SessionPrimer {
    /// Resolves what the session is sitting in.
    ///
    /// `containsSwiftSources` is an autoclosure because it walks the filesystem and only the last branch needs it — a session inside a known root must never pay for a probe whose answer it already has.
    ///
    /// `repositoryRoot` is what keeps the last branch honest. Probing for Swift sources alone is far too loose: a folder like `~/Documents` matches on any project buried a few levels down, and the primer would go on to offer indexing the whole of it. An unindexed repository is a repository, so a directory that encloses no `.git` gets nothing.
    public static func context(
        cwd: String,
        knownRoots: [String],
        repositoryRoot: String?,
        containsSwiftSources: @autoclosure () -> Bool
    ) -> SessionContext {
        let directory = canonical(cwd)
        let roots = knownRoots.map(sessionDirectory)

        // Deepest match wins: with a root nested inside another, the inner one is the repo the session
        // is actually in, and answering with the outer would send every query to the wrong index.
        if let containing = roots.filter({ directory == $0 || directory.hasPrefix($0 + "/") })
            .max(by: { $0.count < $1.count })
        {
            return .insideRoot(containing)
        }

        let below = roots.filter { $0.hasPrefix(directory + "/") }.sorted()
        if !below.isEmpty {
            return .aboveRoots(below)
        }

        guard let repositoryRoot else { return .none }
        return containsSwiftSources() ? .unregisteredSwiftRepository(canonical(repositoryRoot)) : .none
    }

    /// Resolves what a session started in `directory` is sitting in, probing the disk for its repository and Swift sources.
    ///
    /// The one reading behind both places that ask whether Swift is in view: the primer, which stays silent at `.none`, and the MCP server, which marks its tools to load up front everywhere else.
    public static func context(at directory: String, knownRoots: [String]) -> SessionContext {
        let directory = sessionDirectory(directory)
        let repository = enclosingRepository(of: directory)
        let resolved = context(
            cwd: directory,
            knownRoots: knownRoots,
            repositoryRoot: repository,
            containsSwiftSources: containsSwiftSources(at: repository ?? directory)
        )
        // The registry is a list of roots remembered across sessions, and says nothing about the one question the
        // `.unregisteredSwiftRepository` wording answers: whether a query would have to build the index first. A
        // repository whose index is on disk but which the registry never heard of (a scratch directory, which
        // `RootsRegistry` declines to record, or a registry that was reset) is indexed, so it reads as a root.
        guard case let .unregisteredSwiftRepository(path) = resolved, ReadOnlyIndex.hasUsableIndex(atRoot: path) else {
            return resolved
        }
        return .insideRoot(path)
    }

    /// `directory` with every symlink in it resolved, the last component included: the path a process started there reads back as its working directory.
    ///
    /// The MCP server decides from `FileManager.currentDirectoryPath`, which comes back resolved; a hook's `cwd` or a `--cwd`/`--root` argument is taken as given. Resolved here, a symlink to a repository reads as the repository in both, where before the walk up for `.git` and the Swift probe started at the link and the primer fell silent. `CanonicalPath.of` alone leaves a final symlink in place, and `resolvingSymlinksInPath` alone drops the `/private` that `getcwd` keeps, so it takes both.
    public static func sessionDirectory(_ directory: String) -> String {
        canonical(URL(fileURLWithPath: directory).resolvingSymlinksInPath().path)
    }

    /// The git repository enclosing `directory`, or nil if it is not inside one.
    ///
    /// Walks up rather than testing `directory` alone, so a session started in a subdirectory of an unindexed repo still resolves to the repo. Stops at the filesystem root; a `.git` file (a worktree or submodule pointer) counts exactly as a directory does.
    public static func enclosingRepository(of directory: String) -> String? {
        var current = URL(fileURLWithPath: directory).standardizedFileURL
        while true {
            if FileManager.default.fileExists(atPath: current.appendingPathComponent(".git").path) {
                return current.path
            }
            let parent = current.deletingLastPathComponent()
            guard parent.path != current.path else { return nil }
            current = parent
        }
    }

    /// The text to inject, or `nil` when the session gets nothing.
    ///
    /// `lookupsFromBash` swaps the closing's CLI sentence for the one that tells a context whose sift tools are deferred or missing to call the CLI rather than load them. The caller says so only where the four lookups run from Bash without a permission prompt, since that advice where each call asks is worse than the loading step it saves.
    ///
    /// `serverAbsent` leads the primer with the one thing a context cannot find out for itself until a call fails: its session's server is proven not to be running, so the tools the banner names are not there and the CLI is the route. Only the caller can prove that, and it is said only where the primer says anything at all — with no Swift in view the missing server does not matter.
    public static func render(
        _ context: SessionContext,
        audience: Audience = .session,
        moduleHealth: ModuleHealth? = nil,
        serverAbsent: Bool = false,
        lookupsFromBash: Bool = false
    ) -> String? {
        let primer = primer(context, closing: (moduleHealth?.warning ?? "") + closing(for: audience, lookupsFromBash: lookupsFromBash))
        guard serverAbsent else { return primer }
        return primer.map { serverAbsentNotice + "\n\n" + $0 }
    }

    private static func primer(_ context: SessionContext, closing: String) -> String? {
        switch context {
        case .none:
            nil
        case let .insideRoot(root):
            banner + "\n\nThis repo is indexed (`\(root)`), so queries here need no `root:` argument.\n" + closing
        case let .aboveRoots(roots):
            banner
                + "\n\nThis session is rooted **above** the repositories, so pass `root:` with the repo you mean."
                + " Without it, `digest` and `where` fall back to resolving the name against every indexed root,"
                + " which works but costs a probe of each and can come back ambiguous. Indexed roots below here:\n\n"
                + roots.map { "  - \($0)" }.joined(separator: "\n") + "\n"
                + closing
        case let .unregisteredSwiftRepository(path):
            banner
                + "\n\nA Swift repository this machine has not indexed yet (`\(path)`): no setup step,"
                + " the first query indexes it.\n"
                + closing
        }
    }

    /// Whether `directory` holds Swift sources, bounded so a session start never pays for a deep walk.
    ///
    /// Bounded two ways, both because this runs before the user's first turn: it stops at the first hit, and it refuses to descend into the directories that hold no first-party source but plenty of files. A false negative costs only the unregistered-repo nudge, so the time budget is the right thing to protect.
    public static func containsSwiftSources(at directory: String, fileLimit: Int = 4000) -> Bool {
        let skipped: Set = [".build", ".git", "DerivedData", "Pods", "Carthage", "node_modules", ".swiftpm", ".sift"]
        guard let walker = FileManager.default.enumerator(
            at: URL(fileURLWithPath: directory),
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            return false
        }

        var visited = 0
        while let entry = walker.nextObject() as? URL {
            if skipped.contains(entry.lastPathComponent) {
                walker.skipDescendants()
                continue
            }
            if entry.pathExtension == "swift" {
                return true
            }
            visited += 1
            if visited > fileLimit {
                return false
            }
        }
        return false
    }

    private static var banner: String {
        """
        **sift indexes this Swift code: ask it before reading or grepping a `.swift` file.**
        - `digest <Type>` (or a file, or `.`): member line ranges, then a ranged Read; known `Type.member`s (several per call): their source; a cited line: `digest File.swift:120`
        - `where <Symbol>` instead of grepping: definition, callers, conformers, overrides
        - `search` for code by shape, `strings "<text>"` for UI text
        - `sift run -- swift test` (or a build) from Bash: the failures, the log in `.sift/runs/`
        """
    }

    /// Said first when the session's server is proven not to be running: what is missing, and the route that still works.
    private static var serverAbsentNotice: String {
        """
        **This session's sift MCP server is not running, so the `digest`, `where`, `search` and `strings` tools are not \
        here.** The same queries run from Bash and answer the same: `sift digest …`, `sift where …`, `sift search …`, \
        `sift strings …`, with `--root <path>` where a tool call would pass `root:`.
        """
    }

    private static func closing(for audience: Audience, lookupsFromBash: Bool) -> String {
        let cli = lookupsFromBash
            ? "If sift's tools are deferred or missing, run `sift digest …` from Bash rather than loading them"
            : "Without sift tools, the CLI answers the same queries from Bash (`sift digest …`)"
        return switch audience {
        case .session:
            "\n\(cli)."
        case .subagent:
            """

            Exploring several types at once: `digest` each rather than opening the files. \(cli); without Bash, use \
            Read/Grep as normal, nothing to report.
            """
        }
    }

    private static func canonical(_ path: String) -> String {
        CanonicalPath.of(path)
    }
}

public extension SessionPrimer {
    /// How much of a repository's module resolution is guesswork, for the one warning worth spending session-start space on.
    ///
    /// Reported here as well as on each affected answer because of what the per-answer banner cannot do: it arrives *with* an answer, so the first thing built on a wrong module name is already built by the time it is read. At session start it precedes everything.
    ///
    /// The threshold matches `audit`'s deliberately. Every repository has a handful of loose files outside any manifest — a `Package.swift`, a plugin, a script — and warning about a couple in several hundred would train the reader to skip the line that matters when it says every file.
    struct ModuleHealth: Sendable, Equatable {
        public let guessed: Int
        public let files: Int

        public init(guessed: Int, files: Int) {
            self.guessed = guessed
            self.files = files
        }

        /// `true` when guessing is the rule rather than the exception.
        public var isMostlyGuessed: Bool {
            files >= 10 && guessed * 10 >= files
        }

        /// The block appended to the primer, or `""` when there is nothing worth saying.
        ///
        /// Takes its consequence and remedy from ``GuessedModuleNotice`` rather than restating them. The per-answer banner, the transcript audit, the agent guide and this primer all state the one remedy, and a rewording that misses one of them leaves the loudest surface of the four — the one that fires once per session and instructs the agent to open its reply with it — telling people to run a per-repository setup step the tool no longer needs. Restating shared wording is how the surfaces drift apart; sharing it is the only thing that stops it.
        var warning: String {
            guard isMostlyGuessed else { return "" }
            let share = guessed * 100 / files
            return """

            \n**⚠ This repository's module names are mostly guesswork** — \(share)% of its files (\(guessed) of \(files)) \
            have no build file declaring which module they belong to, so the tool falls back to the directory name. \
            Those files still answer, on time, about a module that does not exist: \(GuessedModuleNotice.consequence), \
            while `digest <Type>`, a file path, `where` and `search` are unaffected. SwiftPM manifests, XcodeGen specs \
            (under any file name) and `.xcodeproj` targets are all read automatically, and an upgraded binary \
            re-attributes an existing index on its next query without being asked — so **check the binary is current \
            before anything else**, and treat what follows as the last resort it is. \
            **Say so at the start of your reply** — \(GuessedModuleNotice.remedy).
            """
        }
    }

    /// Who the primer is being written for.
    ///
    /// Subagents need their own delivery *and* their own closing line. Delivery, because a `SessionStart` hook does not fire for them and the path-scoped rule does not reach them either — a subagent given the tools and told in its own prompt to prefer them can still read a set of Swift files end to end without a single index call. Its own closing line, because that is the shape of the miss: exploration sweeps a set of files, which is the most expensive thing the index exists to replace.
    enum Audience: Sendable {
        case session
        case subagent
    }
}
