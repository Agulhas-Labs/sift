//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCLI
import SiftCore
@testable import SiftMCP
import Testing

/// What a session's greeting says about the index, and what it no longer spends words on.
///
/// The repositories here sit in the test's temporary directory, which `RootsRegistry` never records, so the registry cannot be what makes a repository read as indexed: only the index on disk can.
@Suite(.temporaryDirectories)
struct SessionStartGreetingTrimTests {
    /// The greeting names a repository unindexed only where a first query would have to build the index.
    @Test
    func aRepositoryWithoutAnIndexIsToldTheFirstQueryIndexesIt() throws {
        let repo = try MCPTestRepo.make()

        let greeting = try Self.greeting(for: repo)

        #expect(greeting.contains("has not indexed yet"))
        #expect(greeting.contains("the first query indexes it"))
        #expect(!greeting.contains("This repo is indexed"))
    }

    /// An index on disk is an index, whether or not the roots registry remembers the repository.
    @Test
    func aRepositoryWithAnIndexIsNeverToldItHasNotBeenIndexed() async throws {
        let repo = try MCPTestRepo.make()
        try await SiftEngine(directory: repo, registry: nil).ensureFresh()
        #expect(!RootsRegistry.standard().knownRoots().contains(repo.path))

        let greeting = try Self.greeting(for: repo)

        #expect(greeting.contains("This repo is indexed"))
        #expect(!greeting.contains("not indexed"))
        #expect(!greeting.contains("first query indexes it"))
    }

    /// A session started in a subdirectory of the indexed repository finds the repository's index, not a missing one beside it.
    @Test
    func aSubdirectoryOfAnIndexedRepositoryReadsAsIndexedToo() async throws {
        let repo = try MCPTestRepo.make()
        try await SiftEngine(directory: repo, registry: nil).ensureFresh()

        let context = SessionPrimer.context(at: repo.appendingPathComponent("Sources/App").path, knownRoots: [])

        #expect(context == .insideRoot(CanonicalPath.of(repo.path)))
    }

    /// A session's greeting leaves out what the rule and the tool descriptions say, and the no-Bash clause a main session never needs; a subagent keeps the clause, since its tool set can be narrower.
    @Test(arguments: [false, true])
    func theSessionGreetingDropsTheClosingProseASubagentKeeps(lookupsFromBash: Bool) throws {
        let session = try #require(SessionPrimer.render(.insideRoot("/repos/App"), audience: .session, lookupsFromBash: lookupsFromBash))
        let subagent = try #require(SessionPrimer.render(.insideRoot("/repos/App"), audience: .subagent, lookupsFromBash: lookupsFromBash))

        #expect(!session.contains("Fuller guidance"))
        #expect(!session.contains("without Bash"))
        #expect(!session.contains("nothing to report"))
        #expect(subagent.contains("without Bash"))
        #expect(session.hasSuffix(lookupsFromBash ? "rather than loading them." : "from Bash (`sift digest …`)."))
    }
}

private extension SessionStartGreetingTrimTests {
    /// What the SessionStart hook prints for a session started in `repo`, with no Bash allow rules in view.
    static func greeting(for repo: URL, sourceLocation: SourceLocation = #_sourceLocation) throws -> String {
        let ledger = try TemporaryDirectory.make("ledger").appendingPathComponent("run.jsonl")
        return try #require(SessionStartCommand.output(
            payload: ["cwd": repo.path, "hook_event_name": "SessionStart", "source": "startup"],
            cwd: nil,
            event: nil,
            runLedgerURL: ledger,
            permission: { _ in WrappedRunPermission(allowed: [], vetoed: []) }
        ), sourceLocation: sourceLocation)
    }
}
