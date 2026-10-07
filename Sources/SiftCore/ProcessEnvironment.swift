//
// Copyright © Agulhas Labs
//

import Foundation

/// The environment this tool hands to the processes it runs for its own answers.
public struct ProcessEnvironment: Sendable {
    private init() {}
}

public extension ProcessEnvironment {
    /// The leading arguments every `git` this tool runs is given, before its subcommand: `core.fsmonitor` off, so a hook command named in the repository's own `.git/config` is never started by a read.
    ///
    /// **A repository's config is the repository's, and a lookup is run unprompted under an allow rule.** `core.fsmonitor` names a program git starts to learn which files changed, on every command that loads the index; a clone carries none, but a repository someone prepared can set one, and sift would otherwise run it on every `digest`, `where`, `search`, `strings` and hook lookup. Command-line configuration outranks every file, so this one setting is what keeps the program from starting. The setting costs only `git status` speed in a very large tree, where git then stats files itself.
    ///
    /// **A repository's git hooks are programs of the repository's too.** `git add` on the Stop gate's scratch index fires `post-index-change` from `core.hooksPath` or `.git/hooks`, so `core.hooksPath=/dev/null` points hook lookup at a directory with none. Sift runs no git command that needs a hook.
    ///
    /// **Accepted, not closed:** a clean or smudge filter driver (`filter.<name>.clean`), which `git status` can run on a file whose stat changed. It is a driver the user installed in their own config and bound in an attributes file, which a clone does not carry, so it stays. A diff that produces content also passes `--no-textconv`, since textconv drivers come from the same config.
    ///
    /// The command a caller wraps in `sift run` is not run through this: it is the caller's own, and runs as their shell would have run it.
    static let gitHardening = ["-c", "core.fsmonitor=false", "-c", "core.hooksPath=/dev/null"]

    /// `source` with every `GIT_*` variable dropped, and nothing else touched — the environment every `git` this tool spawns is given.
    ///
    /// **git exports `GIT_DIR`, `GIT_INDEX_FILE`, `GIT_WORK_TREE` and friends into every hook it runs, and a child process inherits them.** So `sift status`, or a `sift run -- swift test` from inside a `pre-push` hook, would resolve `HEAD`, the dirty set and the file listing against the *hook's* repository rather than the one at `--root`: a confident answer, under a freshness header, about a repository the caller never named. That is the failure this tool exists not to make, and it is not hypothetical — the same inheritance lets a test fixture's commits land on the branch being pushed. A git handed no repository finds one the way it is meant to, from the directory it runs in.
    ///
    /// **The command a caller wraps in `sift run` is deliberately not scrubbed.** That is the caller's own command and it gets the caller's own environment, unchanged, exactly as their shell would have run it. This is about the git *this tool* spawns to answer with, not about what it is asked to launch.
    ///
    /// Only the `GIT_` namespace goes: `GITHUB_TOKEN` and its neighbours are not git's, and `PATH`, `HOME` and the toolchain's own variables are what make the child work at all.
    static func withoutGit(from source: [String: String] = ProcessInfo.processInfo.environment) -> [String: String] {
        source.filter { !$0.key.hasPrefix("GIT_") }
    }

    /// `source` with `entries` added as git configuration through `GIT_CONFIG_COUNT`, `GIT_CONFIG_KEY_<n>` and `GIT_CONFIG_VALUE_<n>`, numbered on from any entries `source` already carries.
    ///
    /// This is how a command run where git cannot see the repository's own configuration is handed the part of it that it needs. Entries the caller set this way are kept: theirs come first, and these are appended after them.
    ///
    /// A `GIT_CONFIG_COUNT` that is not a count leaves `source` as it was, since git refuses such an environment whatever is added to it, and that refusal is the caller's to see rather than one this tool made.
    static func carrying(gitConfiguration entries: [(key: String, value: String)], into source: [String: String] = ProcessInfo.processInfo.environment) -> [String: String] {
        guard !entries.isEmpty, let existing = source["GIT_CONFIG_COUNT"].map({ Int($0) }) ?? 0, existing >= 0 else {
            return source
        }
        var environment = source
        for (offset, entry) in entries.enumerated() {
            environment["GIT_CONFIG_KEY_\(existing + offset)"] = entry.key
            environment["GIT_CONFIG_VALUE_\(existing + offset)"] = entry.value
        }
        environment["GIT_CONFIG_COUNT"] = String(existing + entries.count)
        return environment
    }
}
