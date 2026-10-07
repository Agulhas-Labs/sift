//
// Copyright © Agulhas Labs
//

import Foundation
import SiftCore
@testable import SiftMCP
import Testing

/// `sift pre-tool-use`, driven through the built binary, on an index call with no root: left alone where the session's server, on record as launched in the project directory, already answers from the caller's tree, and pinned to the caller's tree everywhere else.
///
/// An amendment is a rewritten call, and Claude Code's auto mode has refused rewritten calls it could not judge, so it is sent only where it can change the answer. Each case that keeps it is one where the server's tree and the caller's differ, or could. Where the server runs comes from the lifecycle log (``ServerRootFromLogTests``); the project directory is set beside it only to show it decides nothing.
@Suite(.temporaryDirectories)
struct CallerRootProjectDirTests {
    /// A call from inside the project's own tree, from its top or a folder below, with the project named at its top or a folder below: the server is already rooted there, so the hook prints nothing.
    @Test(arguments: [("", "Sources/App"), ("Sources/App", ""), ("", "")])
    func aCallInsideTheProjectsOwnTreeDrawsNoOutput(project: String, caller: String) throws {
        let repo = try MCPTestRepo.make()
        let run = try Self.run(
            cwd: Self.path(repo, caller),
            projectDirectory: Self.path(repo, project)
        )

        #expect(run.status == 0)
        #expect(run.printed.isEmpty, "printed \(run.printed)")
    }

    /// A subagent in a linked worktree of the project shares the server rooted in the checkout, so its call is pinned to the worktree.
    @Test
    func aLinkedWorktreeOfTheProjectIsStillPinned() throws {
        let repo = try MCPTestRepo.make()
        let worktree = try MCPTestRepo.worktree(of: repo, named: "agent-1a2b3c4d")

        try Self.expectPinned(cwd: worktree.path, projectDirectory: repo.path, to: worktree.path)
    }

    /// A caller standing in another repository is answered from that one.
    @Test
    func anotherRepositoryIsStillPinned() throws {
        let repo = try MCPTestRepo.make()
        let other = try MCPTestRepo.make(declaring: "Beta")

        try Self.expectPinned(cwd: other.path, projectDirectory: repo.path, to: other.path)
    }

    /// A server launched in no repository answers a rootless call from no one tree, so the caller keeps its pin.
    @Test
    func aProjectDirectoryOutsideAnyRepositoryKeepsThePin() throws {
        let repo = try MCPTestRepo.make()
        let plain = try TemporaryDirectory.make("plain-project")

        try Self.expectPinned(cwd: repo.path, projectDirectory: plain.path, to: repo.path)
    }

    /// A server on record as launched in a linked worktree answers a rootless call from that worktree, so a caller standing in it is left alone like one in a main checkout.
    @Test
    func aServerLaunchedInALinkedWorktreeAnswersItsOwnTree() throws {
        let repo = try MCPTestRepo.make()
        let worktree = try MCPTestRepo.worktree(of: repo, named: "desktop-session")

        let run = try Self.run(cwd: worktree.path, projectDirectory: worktree.path)

        #expect(run.status == 0)
        #expect(run.printed.isEmpty, "printed \(run.printed)")
    }

    /// With no server on record and no project directory, the call is pinned exactly as before.
    @Test
    func noProjectDirectoryPinsAsBefore() throws {
        let repo = try MCPTestRepo.make()

        try Self.expectPinned(cwd: repo.appendingPathComponent("Sources/App").path, projectDirectory: nil, to: repo.path)
    }

    /// Under Cursor a project directory in the hook's environment is not read either, and with no server on record the call is pinned.
    @Test
    func anotherHarnessIgnoresTheProjectDirectory() throws {
        let repo = try MCPTestRepo.make()
        let payload: [String: Any] = [
            "conversation_id": "c1", "generation_id": "g1", "model": "default", "tool_name": "MCP:digest",
            "tool_input": ["target": "Alpha"], "tool_use_id": "t1", "cwd": "", "session_id": "cursor-session",
            "hook_event_name": "preToolUse", "cursor_version": "1.0", "workspace_roots": [repo.path],
        ]
        let run = try ServerRootFromLogTests.run(payload: payload, serverLog: ServerRootFromLogTests.log(recording: []), projectDirectory: repo.path, agent: "cursor")
        let object = try #require(try JSONSerialization.jsonObject(with: Data(run.printed.utf8)) as? [String: Any], "printed \(run.printed)")
        let amended = try #require(object["updated_input"] as? [String: String])

        #expect(amended["root"].map(CanonicalPath.of) == CanonicalPath.of(repo.path))
    }

    private static func path(_ repo: URL, _ relative: String) -> String {
        relative.isEmpty ? repo.path : repo.appendingPathComponent(relative).path
    }

    /// Asserts that a rootless digest from `cwd` comes back with its root set to `root` and its target untouched.
    private static func expectPinned(cwd: String, projectDirectory: String?, to root: String, sourceLocation: SourceLocation = #_sourceLocation) throws {
        let run = try run(cwd: cwd, projectDirectory: projectDirectory, sourceLocation: sourceLocation)
        let object = try #require(
            try JSONSerialization.jsonObject(with: Data(run.printed.utf8)) as? [String: Any],
            "printed \(run.printed)",
            sourceLocation: sourceLocation
        )
        let specific = try #require(object["hookSpecificOutput"] as? [String: Any], sourceLocation: sourceLocation)
        let amended = try #require(specific["updatedInput"] as? [String: String], sourceLocation: sourceLocation)

        #expect(run.status == 0, sourceLocation: sourceLocation)
        #expect(amended["root"].map(CanonicalPath.of) == CanonicalPath.of(root), sourceLocation: sourceLocation)
        #expect(amended["target"] == "Alpha", sourceLocation: sourceLocation)
    }

    /// Runs this build's `sift pre-tool-use` on a rootless digest from `cwd`, with the session's live server recorded in a scratch lifecycle log as launched in the project directory given and `CLAUDE_PROJECT_DIR` naming the same, or neither where none is given.
    private static func run(cwd: String, projectDirectory: String?, sourceLocation: SourceLocation = #_sourceLocation) throws -> (status: Int32, printed: String) {
        let session = "project-dir-session"
        let starts = projectDirectory.map { [ServerRootFromLogTests.RecordedStart.live(session: session, root: $0)] } ?? []
        let log = try ServerRootFromLogTests.log(recording: starts, sourceLocation: sourceLocation)
        return try ServerRootFromLogTests.run(
            payload: ServerRootFromLogTests.payload(cwd: cwd, session: session),
            serverLog: log,
            projectDirectory: projectDirectory,
            sourceLocation: sourceLocation
        )
    }
}
