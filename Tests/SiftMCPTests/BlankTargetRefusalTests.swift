//
// Copyright © Agulhas Labs
//

import ArgumentParser
import Foundation
@testable import SiftCLI
import SiftCore
@testable import SiftMCP
import Testing

/// A lookup target that is empty or only whitespace, on the shell and over the server.
///
/// It names nothing, so it is refused before any lookup runs and before any usage-log row is written, rather than answered "no declarations found" as though a symbol were missing.
@Suite(.temporaryDirectories)
struct BlankTargetRefusalTests {
    // MARK: - The CLI

    @Test
    func whereRefusesABlankSymbolWithAUsageError() {
        for blank in ["", "   ", "\t\n"] {
            #expect(Self.refusal(WhereCommand.self, [blank]) == "where needs a symbol, and was given an empty one (or only whitespace): name a type or a Type.member.")
        }
    }

    @Test
    func digestRefusesABlankTargetEvenBesideARealOne() {
        let expected = "digest needs a target, and was given an empty one (or only whitespace): name a type, a Type.member, a module or a file path, or . for the repo."

        #expect(Self.refusal(DigestCommand.self, [""]) == expected)
        #expect(Self.refusal(DigestCommand.self, ["Alpha", "  "]) == expected)
    }

    @Test
    func stringsRefusesABlankQuery() {
        let expected = "strings needs a query, and was given an empty one (or only whitespace): name the display text or key to trace."

        #expect(Self.refusal(StringsCommand.self, [""]) == expected)
        #expect(Self.refusal(StringsCommand.self, ["  "]) == expected)
    }

    @Test
    func aNamedTargetIsStillAccepted() throws {
        #expect(try WhereCommand.parse(["Alpha"]).symbol == "Alpha")
        #expect(try DigestCommand.parse(["Alpha"]).targets == ["Alpha"])
        #expect(try StringsCommand.parse(["Save"]).query == "Save")
    }

    // MARK: - The server

    @Test
    func theServerRefusesABlankTargetOnEachToolWithoutLoggingIt() async throws {
        let root = try MCPTestRepo.make()
        var server = try Server(defaultRoot: root)

        let blankWhere = try await server.call("where", ["symbol": ""])
        let blankDigest = try await server.call("digest", ["target": "   "])
        let blankInList = try await server.call("digest", ["targets": ["Alpha", ""]])
        let blankStrings = try await server.call("strings", ["query": "\t"])
        let lines = try await server.finish()

        #expect(blankWhere.isError)
        #expect(blankWhere.text == "where needs a symbol, and was given an empty one (or only whitespace): name a type or a Type.member.")
        #expect(blankDigest.isError)
        #expect(blankDigest.text == "digest needs a target, and was given an empty one (or only whitespace): name a type, a Type.member, a module or a file path, or . for the repo.")
        #expect(blankInList.isError)
        #expect(blankStrings.isError)
        #expect(blankStrings.text == "strings needs a query, and was given an empty one (or only whitespace): name the display text or key to trace.")
        #expect(lines.isEmpty, "\(lines)")
    }

    @Test
    func aNamedTargetIsAnsweredAndLogged() async throws {
        let root = try MCPTestRepo.make()
        var server = try Server(defaultRoot: root)

        let answer = try await server.call("where", ["symbol": "Alpha"])
        let lines = try await server.finish()

        #expect(!answer.isError)
        #expect(lines.count == 1)
    }
}

extension BlankTargetRefusalTests {
    /// The message the command's parse is refused with, or `nil` when it parses.
    private static func refusal<Command: ParsableCommand>(_: Command.Type, _ arguments: [String]) -> String? {
        do {
            _ = try Command.parse(arguments)
            return nil
        } catch {
            return Command.message(for: error)
        }
    }

    /// An in-process server logging to a file of its own, driven one call at a time.
    private struct Server {
        let usage: URL
        let toServer = Pipe()
        let fromServer = Pipe()
        let task: Task<ServerStop, Never>
        var responses: AsyncStream<String>.Iterator
        var nextID = 1

        init(defaultRoot: URL) throws {
            usage = try TemporaryDirectory.make("usage")
                .appendingPathComponent("usage", isDirectory: true)
                .appendingPathComponent("usage.jsonl")
            let server = try MCPServer(
                input: toServer.fileHandleForReading,
                output: fromServer.fileHandleForWriting,
                defaultRoot: defaultRoot,
                log: { _ in },
                usage: UsageLog(fileURL: usage),
                registry: RootsRegistry(fileURL: TemporaryDirectory.make("roots").appendingPathComponent("roots.json")),
                callers: CallAttribution(directory: TemporaryDirectory.make("callers")
                    .appendingPathComponent("callers", isDirectory: true)),
                session: "blank-target-tests-\(UUID().uuidString)"
            )
            task = Task { await server.run() }
            responses = FileHandleLines.lines(from: fromServer.fileHandleForReading).makeAsyncIterator()
        }

        /// Sends one tool call and returns what it answered.
        mutating func call(
            _ tool: String,
            _ arguments: [String: Any],
            sourceLocation: SourceLocation = #_sourceLocation
        ) async throws -> (text: String, isError: Bool) {
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
            let object = try #require(
                JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                sourceLocation: sourceLocation
            )
            let result = try #require(object["result"] as? [String: Any], sourceLocation: sourceLocation)
            let text = try #require(
                (result["content"] as? [[String: Any]])?.first?["text"] as? String,
                sourceLocation: sourceLocation
            )
            return (text, result["isError"] as? Bool == true)
        }

        /// Closes the input, waits for the server to stop, and returns the usage lines it wrote.
        func finish() async throws -> [String] {
            toServer.fileHandleForWriting.closeFile()
            _ = await task.value
            guard FileManager.default.fileExists(atPath: usage.path) else { return [] }
            return try String(contentsOf: usage, encoding: .utf8)
                .split(separator: "\n")
                .map(String.init)
        }
    }
}
