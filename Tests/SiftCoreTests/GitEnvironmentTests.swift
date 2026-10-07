//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// Every `git` the shipped binary runs for its own answers is handed an environment with no repository in it.
///
/// The caller is not always a shell. `sift status` or `sift run -- swift test` from inside a `pre-push` hook inherits the `GIT_DIR` git exported into that hook, and a git that reads it resolves `HEAD`, the dirty set and the file listing against the *hook's* repository — an answer about a repository nobody named, served under this one's freshness header.
@Suite(.temporaryDirectories)
struct GitEnvironmentTests {
    @Test
    func everyGitVariableIsDroppedAndNothingElseIs() {
        let scrubbed = ProcessEnvironment.withoutGit(from: [
            "GIT_DIR": "/tmp/elsewhere.git",
            "GIT_INDEX_FILE": "/tmp/elsewhere.git/index",
            "GIT_AUTHOR_NAME": "Leaked",
            "PATH": "/usr/bin",
            "HOME": "/Users/nobody",
            "GITHUB_TOKEN": "not git's",
        ])

        #expect(scrubbed == ["PATH": "/usr/bin", "HOME": "/Users/nobody", "GITHUB_TOKEN": "not git's"])
    }

    /// What the child is given by default is the real environment, less git's own variables — the rest of it is what makes a child work at all.
    @Test
    func thisProcessesOwnEnvironmentKeepsEverythingThatIsNotGits() {
        let environment = ProcessInfo.processInfo.environment
        let scrubbed = ProcessEnvironment.withoutGit()

        #expect(scrubbed["PATH"] == environment["PATH"])
        #expect(scrubbed["HOME"] == environment["HOME"])
        #expect(scrubbed.keys.allSatisfy { !$0.hasPrefix("GIT_") })
    }

    /// The shipped spawns, proved against a leaked variable rather than argued from the call sites.
    ///
    /// **`GIT_TRACE2_EVENT` is the representative, and the choice is the point.** The variable that does the damage is `GIT_DIR`, and exporting *that* process-wide — even for the few milliseconds this holds one — would redirect every other test's `git` in a suite that runs in parallel and shells out constantly, failing tests for reasons of their own. This one changes nothing about what git does: it only asks git to append a JSON event log, whose `def_repo` event names the worktree it opened. So a leak is *observable* without being *disruptive*, and the assertion is immune to concurrent noise, since no other process can write this fixture's path into that file. `GIT_AUTHOR_NAME` rides along as a second leaked key that git would silently obey.
    @Test
    func aGitThisToolSpawnsForItselfSeesNoneOfTheCallersGitVariables() throws {
        let root = try TestSources.makeTempRepo()
        try TestSources.write("struct Changed {}\n", to: "Sources/Changed.swift", in: root)
        let trace = try TestSources.makeTempDirectory().appendingPathComponent("trace.jsonl")

        let previous = ["GIT_TRACE2_EVENT": trace.path, "GIT_AUTHOR_NAME": "Leaked"]
            .reduce(into: [String: String?]()) { restored, entry in
                restored[entry.key] = ProcessInfo.processInfo.environment[entry.key]
                setenv(entry.key, entry.value, 1)
            }
        defer {
            for (key, value) in previous {
                if let value {
                    setenv(key, value, 1)
                } else {
                    unsetenv(key)
                }
            }
        }

        let context = GitContext(repoRoot: root)
        _ = try context.head()
        _ = try context.dirtySwiftFiles()
        _ = RunChangedFiles.inWorkingTree(at: root)

        let traced = (try? String(contentsOf: trace, encoding: .utf8)) ?? ""

        #expect(!traced.contains(root.path), "a git this tool spawned read the caller's GIT_* environment")
    }

    /// Pinned directly, not through a read's observed behaviour: whatever the ambient environment says, the environment each of these three builds for its own git reads must carry the override that keeps `status` and porcelain `diff` from taking `index.lock` to write a stat-cache refresh back.
    @Test
    func everyGitReadEnvironmentDisablesOptionalLocks() {
        #expect(GitContext.readEnvironment()["GIT_OPTIONAL_LOCKS"] == "0")
        #expect(TreeContentHash.readEnvironment()["GIT_OPTIONAL_LOCKS"] == "0")
        #expect(RunChangedFiles.readEnvironment()["GIT_OPTIONAL_LOCKS"] == "0")
    }
}
