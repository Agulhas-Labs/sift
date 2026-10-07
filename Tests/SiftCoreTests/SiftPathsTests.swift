//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
import Testing

/// Covers the one promise the path helpers make beyond naming: asking where something goes never puts it there.
@Suite(.temporaryDirectories)
struct SiftPathsTests {
    /// Asking where the cache is must not be what creates it — the callers that only read would start leaving directories in every repository they touch.
    @Test
    func askingWhereTheCacheIsCreatesNothing() throws {
        let root = try TestSources.makeTempDirectory()

        let cache = SiftPaths.cache(in: root)

        #expect(cache.lastPathComponent == SiftPaths.directoryName)
        #expect(!FileManager.default.fileExists(atPath: cache.path))
    }

    /// A repository with no config at all is the common case, and what it gets asked for is where a config would go.
    @Test
    func askingWhereTheConfigIsCreatesNothing() throws {
        let root = try TestSources.makeTempDirectory()

        let config = SiftPaths.config(in: root)

        #expect(config.lastPathComponent == SiftPaths.configFileName)
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    }

    /// A moved `HOME` moves every per-user path with it, since the account's own record would send a probe run under a scratch home into the live files.
    @Test
    func aMovedHomeIsTheHomeEveryPerUserPathFollows() {
        let environment = ["HOME": "/scratch/depot"]

        #expect(SiftPaths.userHome(environment: environment).path == "/scratch/depot")
        #expect(SiftPaths.claudeSettings(environment: environment).path == "/scratch/depot/.claude/settings.json")
    }

    /// `CFFIXED_USER_HOME` wins over `HOME`, because it is how this tool already moves another build's home while leaving its `HOME` alone.
    @Test
    func theFixedHomeVariableWinsOverHome() {
        let environment = ["CFFIXED_USER_HOME": "/scratch/orchard", "HOME": "/scratch/depot"]

        #expect(SiftPaths.userHome(environment: environment).path == "/scratch/orchard")
    }

    /// A `HOME` that is empty, missing or relative names no directory, so the account's home stands.
    @Test(arguments: [[:], ["HOME": ""], ["HOME": "depot"]])
    func aHomeThatNamesNoDirectoryFallsBackToTheAccount(environment: [String: String]) {
        #expect(SiftPaths.userHome(environment: environment) == FileManager.default.homeDirectoryForCurrentUser)
    }

    /// `accountHome` is what the system's own tools use whatever `HOME` says, so it takes no environment to inject and a moved `HOME` handed to ``userHome(environment:)`` leaves it where it was. Pinned without touching the process environment, which the rest of the suite reads concurrently.
    @Test
    func accountHomeIsTheAccountsWhateverHOMESays() {
        let moved = SiftPaths.userHome(environment: ["HOME": "/tmp/scratch-home-that-does-not-exist"])
        #expect(moved.path == "/tmp/scratch-home-that-does-not-exist")
        #expect(SiftPaths.accountHome == FileManager.default.homeDirectoryForCurrentUser)
        #expect(SiftPaths.accountHome != moved)
    }
}
