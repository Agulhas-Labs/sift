//
// Copyright © Agulhas Labs
//

import Foundation
import SiftCore
@testable import SiftMCP
import Testing

/// The `root` a usage line records is the repository the answer was computed against.
///
/// Not the directory the call named and not the server's launch directory: a rootless call is routinely answered from another repository, and every per-repository figure — usage by root, savings attribution, the report, the hook's already-digested check — is read off this one field. A line naming the wrong repository is believed, which is worse than a line that is missing.
@Suite(.temporaryDirectories)
struct UsageRootTests {
    /// A server rooted above two repositories answers each rootless call from the one that declares the name, and logs that one.
    @Test
    func aRootlessCallAboveSeveralRepositoriesLogsTheRepositoryItResolvedTo() async throws {
        let portfolio = try TemporaryDirectory.make("portfolio")
        let alpha = try Self.repository(declaring: "Alpha", in: portfolio)
        let beta = try Self.repository(declaring: "Beta", in: portfolio)
        let registry = try RootsRegistry(fileURL: TemporaryDirectory.make("roots")
            .appendingPathComponent("roots.json"))
        for repository in [alpha, beta] {
            try await SiftEngine(directory: repository, registry: registry).ensureFresh()
        }
        var server = try Server(defaultRoot: portfolio, registry: registry)

        let digest = try await server.call("digest", ["target": "Alpha"])
        let lookup = try await server.call("where", ["symbol": "Beta"])
        // A `root:` written inside a search query is the root argument, misplaced — the server reads it as one,
        // so the log has to as well.
        let search = try await server.call("search", ["query": "name:Beta root:\(beta.path)"])
        let lines = try await server.finish()

        // The answers themselves came from the resolved repositories; the log is what is under test.
        let alphaRoot = try #require(GitContext.discoverRoot(from: alpha)).path
        let betaRoot = try #require(GitContext.discoverRoot(from: beta)).path
        #expect(digest.answered && digest.text.hasPrefix("tree: alpha "))
        #expect(lookup.answered && lookup.text.hasPrefix("tree: beta "))
        #expect(search.answered && search.text.hasPrefix("tree: beta "))
        try #require(lines.count == 3)
        #expect(Self.loggedRoot(lines[0]) == alphaRoot)
        #expect(Self.loggedRoot(lines[1]) == betaRoot)
        #expect(Self.loggedRoot(lines[2]) == betaRoot)
    }

    /// A caller in a worktree is answered from the worktree, and logged against it rather than the checkout the server was launched in.
    ///
    /// The hook pins a rootless call to the worktree's top level; a caller that names a directory *inside* the worktree reaches the same repository through resolution, and a call that fails after resolving still failed there.
    @Test
    func aCallPinnedToAWorktreeLogsTheWorktree() async throws {
        let checkout = try MCPTestRepo.make()
        let worktree = try MCPTestRepo.worktree(of: checkout, named: "agent-1a2b3c4d")
        let inside = worktree.appendingPathComponent("Sources/App").path
        var server = try Server(defaultRoot: checkout, registry: nil)

        let pinned = try #require(CallerRoot.amendment(
            toolName: "mcp__sift__digest",
            input: ["target": "Alpha"],
            cwd: inside
        ))
        let fromPin = try await server.call("digest", pinned)
        let fromInside = try await server.call("digest", ["target": "Alpha", "root": inside])
        let refused = try await server.call("digest", ["root": inside])
        let lines = try await server.finish()

        #expect(fromPin.answered && fromPin.text.contains("(worktree \(worktree.lastPathComponent))"))
        #expect(fromInside.answered && fromInside.text.contains("(worktree \(worktree.lastPathComponent))"))
        #expect(!refused.answered)
        let worktreeRoot = try #require(GitContext.discoverRoot(from: worktree)).path
        try #require(lines.count == 3)
        for line in lines {
            #expect(Self.loggedRoot(line) == worktreeRoot)
        }
        #expect(Self.entry(lines[2])?["ok"] as? Bool == false)
    }

    /// A committed repository declaring `type`, moved under `parent` so a directory can sit above more than one.
    private static func repository(declaring type: String, in parent: URL) throws -> URL {
        let made = try MCPTestRepo.make(declaring: type)
        let destination = parent.appendingPathComponent(type.lowercased())
        try FileManager.default.moveItem(at: made, to: destination)
        return destination
    }

    private static func entry(_ line: String) -> [String: Any]? {
        try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
    }

    /// The logged root, exactly as written: the engine's root is the repository's top level as git names it, which is how the roots registry and the run log spell it too.
    private static func loggedRoot(_ line: String) -> String? {
        entry(line)?["root"] as? String
    }
}

extension UsageRootTests {
    /// An in-process server logging to a file of its own, driven one call at a time.
    private struct Server {
        let usage: URL
        let toServer = Pipe()
        let fromServer = Pipe()
        let task: Task<ServerStop, Never>
        var responses: AsyncStream<String>.Iterator
        var nextID = 1

        init(defaultRoot: URL, registry: RootsRegistry?) throws {
            let id = UUID().uuidString
            usage = try TemporaryDirectory.make("usage")
                .appendingPathComponent("usage", isDirectory: true)
                .appendingPathComponent("usage.jsonl")
            // The caller store and session are this test's own, so nothing reads or claims a slip the real hook
            // left for the session running the suite.
            let server = try MCPServer(
                input: toServer.fileHandleForReading,
                output: fromServer.fileHandleForWriting,
                defaultRoot: defaultRoot,
                log: { _ in },
                usage: UsageLog(fileURL: usage),
                registry: registry,
                callers: CallAttribution(directory: TemporaryDirectory.make("callers")
                    .appendingPathComponent("callers", isDirectory: true)),
                session: "usage-root-tests-\(id)"
            )
            task = Task { await server.run() }
            responses = FileHandleLines.lines(from: fromServer.fileHandleForReading).makeAsyncIterator()
        }

        /// Sends one tool call and returns what it answered.
        mutating func call(
            _ tool: String,
            _ arguments: [String: Any],
            sourceLocation: SourceLocation = #_sourceLocation
        ) async throws -> (text: String, answered: Bool) {
            var data = try JSONSerialization.data(withJSONObject: [
                "jsonrpc": "2.0",
                "id": nextID,
                "method": "tools/call",
                "params": ["name": tool, "arguments": arguments],
            ])
            data.append(0x0A)
            nextID += 1
            toServer.fileHandleForWriting.write(data)
            let line = try #require(await responses.next(), sourceLocation: sourceLocation)
            let result = try #require(
                UsageRootTests.entry(line)?["result"] as? [String: Any],
                sourceLocation: sourceLocation
            )
            let text = try #require(
                (result["content"] as? [[String: Any]])?.first?["text"] as? String,
                sourceLocation: sourceLocation
            )
            return (text, result["isError"] as? Bool == false)
        }

        /// Closes the input, waits for the server to stop, and returns the usage lines it wrote.
        func finish() async throws -> [String] {
            toServer.fileHandleForWriting.closeFile()
            _ = await task.value
            return try String(contentsOf: usage, encoding: .utf8)
                .split(separator: "\n")
                .map(String.init)
        }
    }
}
