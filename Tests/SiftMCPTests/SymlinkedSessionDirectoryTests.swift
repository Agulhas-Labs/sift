//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCLI
import SiftCore
@testable import SiftMCP
import Testing

/// A session started through a symlink reads the same as one started at the path it points to, in the primer and in the server's up-front tool loading alike.
///
/// The server decides from `FileManager.currentDirectoryPath`, which comes back with every symlink resolved; the primer decides from the hook payload's `cwd` or `--cwd` as given. `realpath` stands in for the server's working directory here, because changing the process's own directory in a suite that runs in parallel is off-limits.
@Suite(.temporaryDirectories)
struct SymlinkedSessionDirectoryTests {
    @Test
    func aSymlinkToASwiftRepositoryReadsAsTheRepository() throws {
        let repo = try MCPTestRepo.make()
        let link = try Self.link(to: repo)

        let context = SessionPrimer.context(at: link.path, knownRoots: [])

        #expect(context == SessionPrimer.context(at: repo.path, knownRoots: []))
        #expect(context != .none)
        #expect(MCPToolCatalog.loadsUpFront(sessionIn: Self.realpath(link), knownRoots: []) == (context != .none))
    }

    @Test
    func aSymlinkToAnIndexedRootIsInsideThatRoot() throws {
        let root = try TemporaryDirectory.make("indexed")
        let link = try Self.link(to: root)

        let context = SessionPrimer.context(at: link.path, knownRoots: [root.path])

        #expect(context == .insideRoot(CanonicalPath.of(root.path)))
        #expect(MCPToolCatalog.loadsUpFront(sessionIn: Self.realpath(link), knownRoots: [root.path]))
    }

    /// A known root registered as a symlink compares in its resolved form, the same as the session directory does.
    @Test
    func aKnownRootThatIsASymlinkContainsASessionAtEitherPath() throws {
        let repo = try TemporaryDirectory.make("indexed")
        let link = try Self.link(to: repo)
        let resolved = SessionPrimer.sessionDirectory(repo.path)

        #expect(SessionPrimer.context(at: link.path, knownRoots: [link.path]) == .insideRoot(resolved))
        #expect(SessionPrimer.context(at: repo.path, knownRoots: [link.path]) == .insideRoot(resolved))
    }

    @Test
    func aSymlinkToASubdirectoryOfASwiftRepositoryReadsAsTheRepository() throws {
        let repo = try MCPTestRepo.make()
        let link = try Self.link(to: repo.appendingPathComponent("Sources/App"))

        let context = SessionPrimer.context(at: link.path, knownRoots: [])

        #expect(context == .unregisteredSwiftRepository(CanonicalPath.of(repo.path)))
        #expect(MCPToolCatalog.loadsUpFront(sessionIn: Self.realpath(link), knownRoots: []))
    }

    @Test
    func aRootPassedAsASymlinkToASwiftRepositoryLoadsTheTools() throws {
        let plain = try TemporaryDirectory.make("plain")
        let link = try Self.link(to: MCPTestRepo.make())

        #expect(MCPToolCatalog.loadsUpFront(sessionIn: plain.path, root: link.path, knownRoots: []))
    }

    @Test
    func theHookSpeaksAtASymlinkExactlyAsAtItsTarget() throws {
        let repo = try MCPTestRepo.make()
        let link = try Self.link(to: repo)

        let atLink = try Self.hookOutput(cwd: link)
        let atTarget = try Self.hookOutput(cwd: repo)

        #expect(atLink != nil)
        #expect(atLink == atTarget)
        #expect(MCPToolCatalog.loadsUpFront(sessionIn: Self.realpath(link), knownRoots: RootsRegistry.standard().knownRoots()))
    }

    /// The "where you left off" block reads the repository the primer names: from a symlink to a directory inside it, the walk up for `.git` has to start at the target, not at the link's own parent.
    @Test
    func theResumptionBlockFollowsASymlinkIntoTheRepository() throws {
        let repo = try MCPTestRepo.make()
        try "struct Gizmo {}\n".write(to: repo.appendingPathComponent("Sources/App/Gizmo.swift"), atomically: true, encoding: .utf8)
        let link = try Self.link(to: repo.appendingPathComponent("Sources/App"))

        let output = try Self.hookOutput(cwd: link, source: "compact")

        #expect(output?.contains("**Picking back up:**") == true)
        #expect(output?.contains("declarations changed: +Gizmo") == true)
    }
}

private extension SymlinkedSessionDirectoryTests {
    /// A symlink to `target`, made in a directory of its own so the test's scope removes it.
    static func link(to target: URL) throws -> URL {
        let link = try TemporaryDirectory.make("link").appendingPathComponent("repo")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        return link
    }

    /// `url` as `getcwd` would report it after a `chdir` there.
    static func realpath(_ url: URL) -> String {
        guard let resolved = Foundation.realpath(url.path, nil) else { return url.path }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    static func hookOutput(cwd: URL, source: String = "startup") throws -> String? {
        let ledger = try TemporaryDirectory.make("ledger").appendingPathComponent("run.jsonl")
        return SessionStartCommand.output(
            payload: ["cwd": cwd.path, "hook_event_name": "SessionStart", "source": source],
            cwd: nil,
            event: nil,
            runLedgerURL: ledger,
            resumptionDeadline: 60,
            // No wall-clock budget on the declaration comparison: on a loaded machine the blob read alone can
            // outlast the hook's quarter second, and the block falls back to a bare count this suite is not about.
            declarationParseBudget: .infinity
        )
    }
}
