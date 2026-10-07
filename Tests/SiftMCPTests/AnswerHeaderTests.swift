//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCLI
import SiftCore
@testable import SiftMCP
import Testing

/// The header leads every answer from the four query tools, on both faces (Docs/AnswerContract.md §1).
///
/// Two properties. `search` and `strings` open with a header like the other two, because without one a subagent in a worktree has no way to tell which checkout a search was run over — the question the `tree:` field exists to settle, on the two tools that read the working tree directly. And a note — an adopted root, an argument read under another key — goes *under* the header, never above it, or the line a reader has learned to find the tree on holds something else whenever a note has anything to say.
@Suite(.temporaryDirectories)
struct AnswerHeaderTests {
    /// What a live read opens with, spelled out rather than rebuilt from the function under test.
    private static func liveHeader(repository: URL, worktree: String) -> String {
        "tree: \(repository.lastPathComponent) (worktree \(worktree))  source: working tree, read live — nothing stored to go stale"
    }

    private static func temporaryRegistry() throws -> RootsRegistry {
        try RootsRegistry(fileURL: TemporaryDirectory.make("roots").appendingPathComponent("roots.json"))
    }

    /// An indexed repository alone inside a folder that is not a repository, so a query from the folder has to adopt it.
    private static func portfolio(registry: RootsRegistry) async throws -> (folder: URL, repository: URL) {
        let folder = try TemporaryDirectory.make("portfolio")
        let repository = folder.resolvingSymlinksInPath().appendingPathComponent("app")
        try FileManager.default.moveItem(at: MCPTestRepo.make(), to: repository)
        try await SiftEngine(directory: repository, registry: registry).ensureFresh()
        return (folder.resolvingSymlinksInPath(), repository)
    }

    private static func lines(_ text: String) -> [String] {
        text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    }

    // MARK: - search, strings and similar carry a header

    @Test
    func searchStringsAndSimilarOpenWithTheLiveHeaderOnTheCommandLine() async throws {
        let repository = try MCPTestRepo.make()
        let worktree = try MCPTestRepo.worktree(of: repository, named: "agent-1a2b3c4d")
        let registry = try Self.temporaryRegistry()

        let search = try await SearchCommand.parse(["name:Alpha", "--root", worktree.path]).answer(registry: registry)
        let strings = try StringsCommand.parse(["anything", "--root", worktree.path]).answer(registry: registry)
        // Alpha.go() has no calls in its body, which the similar search always ranks below the callee
        // floor — so its answer is the "too thin to compare" outcome, not the target merely echoed back
        // (every outcome — ranked, thin, ambiguous, unresolved — echoes the target in its heading).
        let similar = try await SimilarCommand.parse(["Alpha.go()", "--root", worktree.path]).answer(registry: registry)

        #expect(Self.lines(search).first == Self.liveHeader(repository: repository, worktree: worktree.lastPathComponent))
        #expect(search.contains("Alpha"))
        #expect(Self.lines(strings).first == Self.liveHeader(repository: repository, worktree: worktree.lastPathComponent))
        #expect(Self.lines(similar).first == Self.liveHeader(repository: repository, worktree: worktree.lastPathComponent))
        #expect(similar.contains("too thin to compare"))
    }

    @Test
    func searchAndStringsOpenWithTheLiveHeaderOverMCP() async throws {
        let repository = try MCPTestRepo.make()
        let worktree = try MCPTestRepo.worktree(of: repository, named: "agent-1a2b3c4d")
        let server = try Server(defaultRoot: worktree, registry: Self.temporaryRegistry())

        let search = try await server.call("search", ["query": "name:Alpha"])
        let strings = try await server.call("strings", ["query": "anything"])
        await server.close()

        #expect(Self.lines(search).first == Self.liveHeader(repository: repository, worktree: worktree.lastPathComponent))
        #expect(search.contains("Alpha"))
        #expect(Self.lines(strings).first == Self.liveHeader(repository: repository, worktree: worktree.lastPathComponent))
    }

    // MARK: - A note goes under the header, never above it

    @Test
    func anAdoptedRootIsNotedUnderTheHeaderOnTheCommandLine() async throws {
        let registry = try Self.temporaryRegistry()
        let (folder, repository) = try await Self.portfolio(registry: registry)
        let root = ["--root", folder.path]

        let answers = try await [
            DigestCommand.parse(["Alpha"] + root).answer(registry: registry),
            WhereCommand.parse(["Alpha", "--syntactic"] + root).answer(registry: registry),
            SearchCommand.parse(["name:Alpha"] + root).answer(registry: registry),
            StringsCommand.parse(["anything"] + root).answer(registry: registry),
            SimilarCommand.parse(["Alpha.go()"] + root).answer(registry: registry),
            DupesCommand.parse(root).answer(registry: registry),
        ]

        for answer in answers {
            let lines = Self.lines(answer)
            #expect(lines.first?.hasPrefix("tree: app") == true, "the header leads: \(answer)")
            #expect(lines.dropFirst().first?.contains("resolved to \(repository.path)") == true, "the note sits directly under it: \(answer)")
        }
    }

    /// The same rule on the two other commands whose answer opens with the header: `status` and `affected`.
    ///
    /// Both resolve their root with no name to probe, so from a folder holding one indexed repository they adopt it and say so — and that note used to be joined in front of the header they print.
    @Test
    func statusAndAffectedNoteAnAdoptedRootUnderTheHeader() async throws {
        let registry = try Self.temporaryRegistry()
        let (folder, repository) = try await Self.portfolio(registry: registry)
        let root = ["--root", folder.path]

        let answers = try await [
            StatusCommand.parse(root).answer(registry: registry),
            AffectedCommand.parse(root).answer(registry: registry),
        ]

        for answer in answers {
            let lines = Self.lines(answer)
            #expect(lines.first?.hasPrefix("tree: app  head: ") == true, "the header leads: \(answer)")
            #expect(lines.dropFirst().first?.contains("resolved to \(repository.path)") == true, "the note sits directly under it: \(answer)")
        }
    }

    @Test
    func everyNoteIsPlacedUnderTheHeaderOverMCP() async throws {
        let registry = try Self.temporaryRegistry()
        let (folder, repository) = try await Self.portfolio(registry: registry)
        let server = try Server(defaultRoot: folder, registry: registry)

        let answers = try await [
            server.call("digest", ["target": "Alpha"]),
            server.call("where", ["symbol": "Alpha"]),
            server.call("search", ["query": "name:Alpha"]),
            server.call("strings", ["query": "anything"]),
        ]
        // Both kinds of note at once: the argument read under another key, and the root it resolved to.
        let aliased = try await server.call("digest", ["query": "Alpha"])
        await server.close()

        for answer in answers {
            let lines = Self.lines(answer)
            #expect(lines.first?.hasPrefix("tree: app") == true, "the header leads: \(answer)")
            #expect(lines.dropFirst().first?.contains("resolved to \(repository.path)") == true, "the note sits directly under it: \(answer)")
        }
        let aliasedLines = Self.lines(aliased)

        #expect(aliasedLines.first?.hasPrefix("tree: app") == true)
        #expect(aliasedLines.dropFirst().first?.hasPrefix("read query: as target:") == true)
        #expect(aliasedLines.dropFirst(2).first?.contains("resolved to \(repository.path)") == true)
    }

    /// A replaced binary's notice sits under the header like every other note, and runs straight into the rest of the answer.
    ///
    /// It used to be prepended with a blank line after it, which put a warning on the line where every reader looks for the tree. Under the header it is one note among the others, so it takes their spacing: no blank line, because a blank line there would split one answer's preamble into two blocks, and the leading `⚠` already sets it apart.
    @Test
    func aReplacedBinarysNoticeSitsUnderTheHeader() async throws {
        let repository = try MCPTestRepo.make()
        let binary = try TemporaryDirectory.make("binary").appendingPathComponent("binary")
        try Data("old code".utf8).write(to: binary)
        let server = try Server(defaultRoot: repository, registry: Self.temporaryRegistry(), binaryPath: binary.path)
        // The upgrade shape: a new inode at the same path.
        try FileManager.default.removeItem(at: binary)
        try Data("new code".utf8).write(to: binary)

        let answer = try await server.call("digest", ["target": "Alpha"])
        await server.close()
        let lines = Self.lines(answer)

        #expect(lines.first?.hasPrefix("tree: \(repository.lastPathComponent)  head: ") == true, "\(answer)")
        #expect(lines.dropFirst().first?.hasPrefix("⚠ the sift binary was replaced on disk") == true, "\(answer)")
        #expect(lines.dropFirst(2).first?.isEmpty == false, "no blank line after the notice: \(answer)")
        #expect(answer.contains("struct Alpha"))
    }
}

extension AnswerHeaderTests {
    /// One live server over a pipe pair, answering tool calls in order.
    final class Server {
        private let toServer = Pipe()
        private let fromServer = Pipe()
        private let task: Task<ServerStop, Never>
        private var responses: AsyncStream<String>.AsyncIterator
        private var nextID = 1

        init(defaultRoot: URL, registry: RootsRegistry, binaryPath: String = BinaryIdentity.executablePath) throws {
            let server = MCPServer(
                input: toServer.fileHandleForReading,
                output: fromServer.fileHandleForWriting,
                defaultRoot: defaultRoot,
                log: { _ in },
                registry: registry,
                binaryPath: binaryPath
            )
            task = Task { await server.run() }
            responses = FileHandleLines.lines(from: fromServer.fileHandleForReading).makeAsyncIterator()
        }

        /// The text of one tool call's answer, which must not be an error.
        func call(_ tool: String, _ arguments: [String: Any], sourceLocation: SourceLocation = #_sourceLocation) async throws -> String {
            var request = try JSONSerialization.data(withJSONObject: [
                "jsonrpc": "2.0", "id": nextID, "method": "tools/call",
                "params": ["name": tool, "arguments": arguments],
            ])
            nextID += 1
            request.append(0x0A)
            toServer.fileHandleForWriting.write(request)
            let line = try #require(await responses.next(), sourceLocation: sourceLocation)
            let response = try #require(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any], sourceLocation: sourceLocation)
            let result = try #require(response["result"] as? [String: Any], sourceLocation: sourceLocation)
            let text = try #require((result["content"] as? [[String: Any]])?.first?["text"] as? String, sourceLocation: sourceLocation)
            #expect(result["isError"] as? Bool == false, "\(tool) failed: \(text)", sourceLocation: sourceLocation)
            return text
        }

        func close() async {
            toServer.fileHandleForWriting.closeFile()
            _ = await task.value
        }
    }
}
