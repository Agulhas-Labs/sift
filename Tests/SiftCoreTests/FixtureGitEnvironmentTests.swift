//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// The suite's own `git` must be deaf to the `GIT_*` variables of whatever launched it.
///
/// Every fixture repository is built by shelling out to `git`, and `git` exports `GIT_DIR`, `GIT_INDEX_FILE` and friends into every hook it runs. Inheriting them points each fixture's `git` at the launching repository instead of at the temporary directory it was handed: the run fails on lock files it never made, and the fixtures' commits land on the branch being pushed.
@Suite(.temporaryDirectories)
struct FixtureGitEnvironmentTests {
    /// The rule proved through a real spawn, which is the half a filter over a dictionary cannot pin: a fixture `git` handed the parent's environment verbatim would obey it.
    ///
    /// The filter itself, and the shipped spawns that share it, are `GitEnvironmentTests`.
    ///
    /// `GIT_AUTHOR_NAME` rather than the `GIT_DIR` that does the damage, deliberately. The suite runs its tests in parallel and shells out to `git` constantly, so a process-wide `GIT_DIR` — even for the ~30 ms this holds one — would redirect any *other* test's `git` mid-run and fail it for reasons that have nothing to do with what it was testing. A leaked author name is observable in exactly the same place and cannot break a concurrent commit; the scrub it proves is by prefix, so the key it is proved with is a representative and not a special case.
    @Test
    func aFixtureCommitIgnoresTheGitVariablesTheParentExports() throws {
        let root = try TestSources.makeTempRepo()
        try TestSources.write("a change to commit\n", to: "later.txt", in: root)

        let previous = ProcessInfo.processInfo.environment["GIT_AUTHOR_NAME"]
        setenv("GIT_AUTHOR_NAME", "Leaked", 1)
        defer {
            if let previous {
                setenv("GIT_AUTHOR_NAME", previous, 1)
            } else {
                unsetenv("GIT_AUTHOR_NAME")
            }
        }
        try TestSources.commitAll(in: root, message: "committed under a leaked GIT_AUTHOR_NAME")

        let author = try TestSources.runGit(["log", "-1", "--format=%an"], in: root)

        #expect(author.trimmingCharacters(in: .whitespacesAndNewlines) == "Tester")
    }
}
