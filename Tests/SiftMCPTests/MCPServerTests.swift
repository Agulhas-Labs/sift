//
// Copyright © Agulhas Labs
//

import Foundation
import SiftCore
@testable import SiftMCP
import Testing

/// Covers the stdio face over real pipes: handshake, discovery, tool calls, and byte-clean protocol output.
@Suite(.temporaryDirectories)
struct MCPServerTests {
    private static func startSession(defaultRoot: URL? = nil, registry: RootsRegistry? = nil) throws -> Session {
        let root = try defaultRoot ?? MCPTestRepo.make()
        let toServer = Pipe()
        let fromServer = Pipe()
        let server = MCPServer(
            input: toServer.fileHandleForReading,
            output: fromServer.fileHandleForWriting,
            defaultRoot: root,
            log: { _ in },
            registry: registry
        )
        let task = Task { await server.run() }
        return Session(
            root: root,
            toServer: toServer,
            fromServer: fromServer,
            task: task,
            responses: FileHandleLines.lines(from: fromServer.fileHandleForReading).makeAsyncIterator()
        )
    }

    /// A single `target` is one target whatever it holds: a path with a space in it — the default layout for an app's sources — is served as the file, relative or absolute, exactly as it always was.
    @Test
    func aTargetWithASpaceInItsPathIsOneTarget() async throws {
        let root = try MCPTestRepo.make()
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Sources/My App"), withIntermediateDirectories: true)
        try "struct ContentView {\n    let one = 1\n}\n".write(
            to: root.appendingPathComponent("Sources/My App/ContentView.swift"), atomically: true, encoding: .utf8
        )

        for target in ["Sources/My App/ContentView.swift", root.appendingPathComponent("Sources/My App/ContentView.swift").path] {
            let answer = try await Self.digest(["target": target], in: root)

            #expect(!answer.isError)
            #expect(answer.text.contains("struct ContentView"), "\(target): \(answer.text)")
            #expect(!answer.text.contains("no indexed file matches"))
            #expect(!answer.text.contains("targets:"))
        }
    }

    /// Several targets go in `targets`, each answered in the order given; a `target` beside them is answered first.
    @Test
    func severalTargetsAreSentAsAnArray() async throws {
        let root = try MCPTestRepo.make()

        let answer = try await Self.digest(["target": "Alpha.go()", "targets": ["Alpha.one", "Alpha"]], in: root)

        #expect(!answer.isError)
        let member = try #require(answer.text.range(of: "Alpha.go() — func"))
        let property = try #require(answer.text.range(of: "Alpha.one — var"))
        #expect(member.lowerBound < property.lowerBound)
        #expect(answer.text.contains("struct Alpha"))
    }

    /// A spaced `target` none of whose names resolves says it was read whole, and names `targets` — spelled with the pieces it was sent — as the way to ask for several.
    @Test
    func aSpacedTargetThatMissesNamesTheTargetsArgument() async throws {
        let root = try MCPTestRepo.make()

        let answer = try await Self.digest(["target": "Phantom Mirage"], in: root)

        #expect(answer.text.contains("read target: as one name, whitespace included — several targets go in targets: [\"Phantom\", \"Mirage\"]"))
        // Under the header, like every other note.
        #expect(answer.text.split(separator: "\n").dropFirst().first?.hasPrefix("read target:") == true)
    }

    /// `targets` holding anything but strings is refused with the shape it takes, rather than read as absent.
    @Test
    func aTargetsArgumentThatIsNotAnArrayOfStringsIsRefusedByShape() async throws {
        let root = try MCPTestRepo.make()

        let answer = try await Self.digest(["targets": "Alpha"], in: root)

        #expect(answer.isError)
        #expect(answer.text.contains("targets: takes an array of strings"))
    }

    /// `at:` sent as anything but a string is refused rather than falling through to a working-tree answer — a number, an explicit `null` — while a string revision and an absent `at:` both answer as before.
    @Test
    func aNonStringAtIsRefusedRatherThanFallingThroughToTheWorkingTree() async throws {
        let root = try MCPTestRepo.make()

        let numeric = try await Self.digest(["target": "Alpha", "at": 12], in: root)
        #expect(numeric.isError)
        #expect(numeric.text.contains("at:"))

        let null = try await Self.digest(["target": "Alpha", "at": NSNull()], in: root)
        #expect(null.isError)
        #expect(null.text.contains("at:"))

        let named = try await Self.digest(["target": "Alpha", "at": "HEAD"], in: root)
        #expect(!named.isError)
        #expect(named.text.contains("at: HEAD = "), "\(named.text)")

        let absent = try await Self.digest(["target": "Alpha"], in: root)
        #expect(!absent.isError)
        #expect(!absent.text.contains("at: "), "\(absent.text)")
    }

    /// `symbol:` — the key `where` uses for the same thing — sent alongside `targets:` is refused, naming both arguments, rather than silently dropped where `target:` would have healed from it.
    @Test
    func aStrayAliasKeyAlongsideTargetsIsRefused() async throws {
        let root = try MCPTestRepo.make()

        let answer = try await Self.digest(["symbol": "Big", "targets": ["Alpha"]], in: root)

        #expect(answer.isError)
        #expect(answer.text.contains("targets:"))
        #expect(answer.text.contains("symbol:"))
    }

    /// An offset pages one answer, so a call naming several targets with one is refused rather than applied to each.
    @Test
    func anOffsetWithSeveralTargetsIsRefused() async throws {
        let root = try MCPTestRepo.make()

        let answer = try await Self.digest(["targets": ["Alpha", "Alpha.go()"], "offset": 20], in: root)

        #expect(answer.isError)
        #expect(answer.text.contains("an offset pages one answer, and this call named 2 targets"))
    }

    /// A digest whose Swift name arrived under `query:` is answered, not refused.
    ///
    /// The end-to-end half of ``ArgumentAliasTests``: the resolver deciding to read the key is worth nothing if the server never asks it.
    @Test
    func aDigestNamedUnderAnotherToolsKeyIsAnswered() async throws {
        var session = try Self.startSession()
        try session.send([
            "jsonrpc": "2.0", "id": 1, "method": "initialize",
            "params": ["protocolVersion": "2025-06-18", "capabilities": [String: Any](), "clientInfo": ["name": "test", "version": "0"]],
        ])
        _ = try await session.next()
        try session.send(["jsonrpc": "2.0", "method": "notifications/initialized"])

        try session.send([
            "jsonrpc": "2.0", "id": 2, "method": "tools/call",
            "params": ["name": "digest", "arguments": ["query": "Alpha"]],
        ])
        let call = try await session.next()
        let callResult = try #require(call["result"] as? [String: Any])
        let content = try #require(callResult["content"] as? [[String: Any]])
        let text = try #require(content.first?["text"] as? String)

        #expect(callResult["isError"] as? Bool == false)
        #expect(text.contains("struct Alpha"))
        // Said out loud rather than silently healed, so the next call is spelled right by the caller.
        #expect(text.contains("read query: as target:"))

        await session.close()
    }

    /// The end-to-end half of the `path:`/`text:` donor keys: a real server call, not just `ArgumentAlias.resolve`.
    @Test
    func aDigestNamedUnderPathIsAnswered() async throws {
        var session = try Self.startSession()
        try session.send([
            "jsonrpc": "2.0", "id": 1, "method": "initialize",
            "params": ["protocolVersion": "2025-06-18", "capabilities": [String: Any](), "clientInfo": ["name": "test", "version": "0"]],
        ])
        _ = try await session.next()
        try session.send(["jsonrpc": "2.0", "method": "notifications/initialized"])

        try session.send([
            "jsonrpc": "2.0", "id": 2, "method": "tools/call",
            "params": ["name": "digest", "arguments": ["path": "Sources/App/Alpha.swift"]],
        ])
        let call = try await session.next()
        let callResult = try #require(call["result"] as? [String: Any])
        let content = try #require(callResult["content"] as? [[String: Any]])
        let text = try #require(content.first?["text"] as? String)

        #expect(callResult["isError"] as? Bool == false)
        #expect(text.contains("struct Alpha"))
        #expect(text.contains("read path: as target:"))

        await session.close()
    }

    /// The same, for `strings`' own `text:` donor key.
    @Test
    func aStringsQueryNamedUnderTextIsAnswered() async throws {
        var session = try Self.startSession()
        try session.send([
            "jsonrpc": "2.0", "id": 1, "method": "initialize",
            "params": ["protocolVersion": "2025-06-18", "capabilities": [String: Any](), "clientInfo": ["name": "test", "version": "0"]],
        ])
        _ = try await session.next()
        try session.send(["jsonrpc": "2.0", "method": "notifications/initialized"])

        try session.send([
            "jsonrpc": "2.0", "id": 2, "method": "tools/call",
            "params": ["name": "strings", "arguments": ["text": "Save changes"]],
        ])
        let call = try await session.next()
        let callResult = try #require(call["result"] as? [String: Any])
        let content = try #require(callResult["content"] as? [[String: Any]])
        let text = try #require(content.first?["text"] as? String)

        #expect(callResult["isError"] as? Bool == false)
        #expect(text.contains("read text: as query:"))

        await session.close()
    }

    /// A query that is not a Swift name is still refused — and the refusal now names the key that was sent.
    @Test
    func aStructuralQuerySentToDigestIsRefusedByName() async throws {
        var session = try Self.startSession()
        try session.send([
            "jsonrpc": "2.0", "id": 1, "method": "initialize",
            "params": ["protocolVersion": "2025-06-18", "capabilities": [String: Any](), "clientInfo": ["name": "test", "version": "0"]],
        ])
        _ = try await session.next()
        try session.send(["jsonrpc": "2.0", "method": "notifications/initialized"])

        try session.send([
            "jsonrpc": "2.0", "id": 2, "method": "tools/call",
            "params": ["name": "digest", "arguments": ["query": "kind:struct"]],
        ])
        let call = try await session.next()
        let callResult = try #require(call["result"] as? [String: Any])
        let content = try #require(callResult["content"] as? [[String: Any]])
        let text = try #require(content.first?["text"] as? String)

        #expect(callResult["isError"] as? Bool == true)
        #expect(text.contains("digest needs a target"))
        #expect(text.contains("query:"))

        await session.close()
    }

    @Test
    func handshakeDiscoveryAndDigestCall() async throws {
        var session = try Self.startSession()
        try session.send([
            "jsonrpc": "2.0", "id": 1, "method": "initialize",
            "params": ["protocolVersion": "2025-06-18", "capabilities": [String: Any](), "clientInfo": ["name": "test", "version": "0"]],
        ])
        let initialize = try await session.next()
        let initResult = try #require(initialize["result"] as? [String: Any])
        let serverInfo = try #require(initResult["serverInfo"] as? [String: Any])

        #expect(serverInfo["name"] as? String == "sift")

        try session.send(["jsonrpc": "2.0", "method": "notifications/initialized"])
        try session.send(["jsonrpc": "2.0", "id": 2, "method": "tools/list"])
        let list = try await session.next()
        let listResult = try #require(list["result"] as? [String: Any])
        let tools = try #require(listResult["tools"] as? [[String: Any]])

        #expect(tools.count == 4)
        #expect(tools.map { $0["name"] as? String } == ["digest", "where", "search", "strings"])
        // The properties that are load-bearing, not the sentence carrying them: descriptions are
        // trigger-phrased so the model knows *when* to reach, and they name the shell because that is the
        // alternative actually being chosen. Pinning the exact opening made every wording change a test
        // failure, and the wording is meant to be iterated on and measured.
        let digestDescription = try #require(tools[0]["description"] as? String)
        #expect(digestDescription.hasPrefix("Call this"))
        #expect(digestDescription.contains("shell"))

        try session.send([
            "jsonrpc": "2.0", "id": 3, "method": "tools/call",
            "params": ["name": "digest", "arguments": ["target": "Alpha"]],
        ])
        let call = try await session.next()
        let callResult = try #require(call["result"] as? [String: Any])
        let content = try #require(callResult["content"] as? [[String: Any]])
        let text = try #require(content.first?["text"] as? String)

        #expect(callResult["isError"] as? Bool == false)
        // The header leads with the tree it was measured against — the field that tells a worktree's answer
        // from its parent checkout's, which nothing else in an answer can.
        #expect(text.hasPrefix("tree: \(session.root.lastPathComponent)  head: "))
        #expect(text.contains("struct Alpha"))
        #expect(text.contains("func go()"))

        await session.close()
    }

    @Test
    func unknownToolReportsInsideTheResultNotAsProtocolError() async throws {
        var session = try Self.startSession()
        try session.send([
            "jsonrpc": "2.0", "id": 1, "method": "tools/call",
            "params": ["name": "bogus", "arguments": [String: Any]()],
        ])
        let call = try await session.next()
        let callResult = try #require(call["result"] as? [String: Any])

        #expect(callResult["isError"] as? Bool == true)
        #expect(call["error"] == nil)

        await session.close()
    }

    /// `where` given `target:` and `digest` given `symbol:` name the same thing either way — `where target:InboundCard` and `where target:ArchiveReader.lastEntry()` would otherwise each be refused as "where needs a symbol" without naming the key it wanted.
    @Test
    func aSwiftNameSentUnderTheOtherToolsArgumentNameIsRead() async throws {
        var session = try Self.startSession()

        try session.send([
            "jsonrpc": "2.0", "id": 1, "method": "tools/call",
            "params": ["name": "where", "arguments": ["target": "Alpha"]],
        ])
        let lookup = try await session.next()
        let lookupResult = try #require(lookup["result"] as? [String: Any])
        let lookupText = try #require((lookupResult["content"] as? [[String: Any]])?.first?["text"] as? String)

        #expect(lookupResult["isError"] as? Bool == false)
        #expect(lookupText.contains("Alpha"))
        // The correction is stated, so the next call uses the right key.
        #expect(lookupText.contains("read target: as symbol:"))

        // The same slip in the other direction.
        try session.send([
            "jsonrpc": "2.0", "id": 2, "method": "tools/call",
            "params": ["name": "digest", "arguments": ["symbol": "Alpha"]],
        ])
        let digest = try await session.next()
        let digestResult = try #require(digest["result"] as? [String: Any])
        let digestText = try #require((digestResult["content"] as? [[String: Any]])?.first?["text"] as? String)

        #expect(digestResult["isError"] as? Bool == false)
        #expect(digestText.contains("Alpha"))
        #expect(digestText.contains("read symbol: as target:"))

        // An argument the tool actually names wins, and says nothing.
        try session.send([
            "jsonrpc": "2.0", "id": 3, "method": "tools/call",
            "params": ["name": "where", "arguments": ["symbol": "Alpha", "target": "Beta"]],
        ])
        let explicit = try await session.next()
        let explicitResult = try #require(explicit["result"] as? [String: Any])
        let explicitText = try #require((explicitResult["content"] as? [[String: Any]])?.first?["text"] as? String)

        #expect(explicitResult["isError"] as? Bool == false)
        #expect(!explicitText.contains("read target:"))

        // Neither name given is still a refusal — there is nothing to read it as.
        try session.send([
            "jsonrpc": "2.0", "id": 4, "method": "tools/call",
            "params": ["name": "where", "arguments": ["refs": true]],
        ])
        let missing = try await session.next()
        let missingResult = try #require(missing["result"] as? [String: Any])

        #expect(missingResult["isError"] as? Bool == true)

        await session.close()
    }

    /// A `root:` term inside a search query is the root argument, misplaced — `search uses:colorScheme root:/path/to/app` would otherwise be refused as "unknown field root".
    @Test
    func anInlineRootTermInASearchQueryIsLiftedToTheRootArgument() async throws {
        var session = try Self.startSession()
        let other = try MCPTestRepo.make()
        try "struct Beta {}\n".write(
            to: other.appendingPathComponent("Sources/App/Beta.swift"),
            atomically: true,
            encoding: .utf8
        )

        try session.send([
            "jsonrpc": "2.0", "id": 1, "method": "tools/call",
            "params": ["name": "search", "arguments": ["query": "name:beta root:\(other.path)"]],
        ])
        let lifted = try await session.next()
        let liftedResult = try #require(lifted["result"] as? [String: Any])
        let liftedText = try #require((liftedResult["content"] as? [[String: Any]])?.first?["text"] as? String)

        #expect(liftedResult["isError"] as? Bool == false)
        #expect(liftedText.contains("Beta"))
        // The echo shows the query as searched, with the term gone.
        #expect(liftedText.contains("search name:beta\n"))

        // An explicit root argument is deliberate, so it wins over the inline term.
        try session.send([
            "jsonrpc": "2.0", "id": 2, "method": "tools/call",
            "params": ["name": "search", "arguments": ["query": "name:beta root:\(other.path)", "root": session.root.path]],
        ])
        let explicit = try await session.next()
        let explicitResult = try #require(explicit["result"] as? [String: Any])
        let explicitText = try #require((explicitResult["content"] as? [[String: Any]])?.first?["text"] as? String)

        #expect(explicitResult["isError"] as? Bool == false)
        #expect(explicitText.contains("no declarations match"))

        await session.close()
    }

    /// A rootless search resolves itself like a rootless digest, because a `name:` term is the same evidence a digest target is.
    ///
    /// A `search name:…` from a directory holding several repositories — `name:Logger`, `name:RecordStore`, `name:KindType kind:enum`, `name:RecordDetail kind:struct` — would otherwise be refused while `digest` on the same name heals. Search takes a query rather than a name, but a `name:` term in it is a name.
    @Test
    func aRootlessSearchResolvesOnTheNameItAsksAbout() async throws {
        let declaring = try MCPTestRepo.make()
        let registryFile = try TemporaryDirectory.make("roots")
            .appendingPathComponent("roots.json")
        let registry = RootsRegistry(fileURL: registryFile)
        try await SiftEngine(directory: declaring, registry: registry).ensureFresh()
        // A directory enclosing nothing, so only the name can identify the repository.
        let portfolio = try TemporaryDirectory.make("portfolio")
        var session = try Self.startSession(defaultRoot: portfolio, registry: registry)

        try session.send([
            "jsonrpc": "2.0", "id": 1, "method": "tools/call",
            "params": ["name": "search", "arguments": ["query": "name:Alpha kind:struct"]],
        ])
        let resolved = try await session.next()
        let resolvedResult = try #require(resolved["result"] as? [String: Any])
        let resolvedText = try #require((resolvedResult["content"] as? [[String: Any]])?.first?["text"] as? String)

        #expect(resolvedResult["isError"] as? Bool == false)
        #expect(resolvedText.contains("no repository encloses"))
        #expect(resolvedText.contains(declaring.path))
        #expect(resolvedText.contains("Alpha"))

        // The control: a query asking only about shape names nothing to probe, and still has to ask.
        try session.send([
            "jsonrpc": "2.0", "id": 2, "method": "tools/call",
            "params": ["name": "search", "arguments": ["query": "kind:struct"]],
        ])
        let shapeOnly = try await session.next()
        let shapeResult = try #require(shapeOnly["result"] as? [String: Any])

        #expect(shapeResult["isError"] as? Bool == true)

        await session.close()
    }

    /// `count` wires through the MCP face the same as the CLI's `--count`: the summary survives, the listing does not.
    @Test
    func searchCountArgumentDropsTheListing() async throws {
        var session = try Self.startSession()

        try session.send([
            "jsonrpc": "2.0", "id": 1, "method": "tools/call",
            "params": ["name": "search", "arguments": ["query": "kind:struct", "count": true]],
        ])
        let counted = try await session.next()
        let countedResult = try #require(counted["result"] as? [String: Any])
        let countedText = try #require((countedResult["content"] as? [[String: Any]])?.first?["text"] as? String)

        #expect(countedResult["isError"] as? Bool == false)
        #expect(countedText.contains("declaration(s) in"))
        #expect(!countedText.contains(".swift:"))

        await session.close()
    }

    @Test
    func notificationsReceiveNoResponse() async throws {
        var session = try Self.startSession()
        // tools/list WITHOUT an id is a notification — the protocol forbids answering it.
        try session.send(["jsonrpc": "2.0", "method": "tools/list"])
        try session.send(["jsonrpc": "2.0", "id": 5, "method": "ping"])
        let first = try await session.next()

        #expect(first["id"] as? Int == 5)

        await session.close()
    }

    @Test
    func unknownMethodAndParseErrorUseProtocolErrors() async throws {
        var session = try Self.startSession()
        try session.send(["jsonrpc": "2.0", "id": 9, "method": "no/such/method"])
        let unknown = try await session.next()
        let unknownError = try #require(unknown["error"] as? [String: Any])

        #expect(unknownError["code"] as? Int == -32601)

        session.toServer.fileHandleForWriting.write(Data("not json at all\n".utf8))
        let parse = try await session.next()
        let parseError = try #require(parse["error"] as? [String: Any])

        #expect(parseError["code"] as? Int == -32700)

        await session.close()
    }
}

/// A separate extension so the main suite's type body stays under swiftlint's line cap.
extension MCPServerTests {
    /// A cached engine whose database file has gone is reopened rather than answered from.
    ///
    /// The failure is `step failed (code 10)` — `SQLITE_IOERR` — and its shape in the usage log identifies it: a worktree answers perfectly for a stretch, then every later call in that session fails, forever, while a fresh process on the same repo answers instantly. The index is a rebuildable cache, so anything that removes `.sift/` (a `git clean -xfd`, a worktree removed and recreated at the same path) unlinks the file under the server's open handle, and SQLite fails every subsequent step.
    @Test
    func aCachedEngineWhoseDatabaseWasDeletedIsReopenedRatherThanFailingForever() async throws {
        var session = try Self.startSession()
        try session.send([
            "jsonrpc": "2.0", "id": 1, "method": "tools/call",
            "params": ["name": "digest", "arguments": ["target": "Alpha"]],
        ])
        let first = try #require(try await session.next()["result"] as? [String: Any])

        #expect(first["isError"] as? Bool == false)

        // What a `git clean -xfd` in the worktree does to the cache directory.
        try FileManager.default.removeItem(at: session.root.appendingPathComponent(".sift"))
        try session.send([
            "jsonrpc": "2.0", "id": 2, "method": "tools/call",
            "params": ["name": "digest", "arguments": ["target": "Alpha"]],
        ])
        let second = try #require(try await session.next()["result"] as? [String: Any])
        let secondText = try #require((second["content"] as? [[String: Any]])?.first?["text"] as? String)

        #expect(second["isError"] as? Bool == false)
        #expect(!secondText.contains("step failed"))
        #expect(secondText.contains("struct Alpha"))

        // And the reopened engine is durable, not a one-shot recovery.
        try session.send([
            "jsonrpc": "2.0", "id": 3, "method": "tools/call",
            "params": ["name": "where", "arguments": ["symbol": "Alpha"]],
        ])
        let third = try #require(try await session.next()["result"] as? [String: Any])

        #expect(third["isError"] as? Bool == false)

        await session.close()
    }

    /// The loop says why it ended, which is what ``ServerLifecycleLog`` writes down.
    ///
    /// A client closing its end is the ordinary ending, and it has to be distinguishable from every other way a server can stop — a loop that returns nothing at all leaves a session that ended normally and one that was killed in precisely the same state: no record either way.
    @Test
    func aClientClosingItsEndIsReportedAsAnOrdinaryEnding() async throws {
        var session = try Self.startSession()
        try session.send([
            "jsonrpc": "2.0", "id": 1, "method": "initialize",
            "params": ["protocolVersion": "2025-06-18", "capabilities": [String: Any](), "clientInfo": ["name": "test", "version": "0"]],
        ])
        _ = try await session.next()

        #expect(await session.close() == .inputClosed)
    }

    /// A request far larger than one read is answered, not dropped.
    ///
    /// The end-to-end half of ``FileHandleLinesTests``: a framing assumption that holds until a request crosses the buffer would present as a dropped session, one that works and then stops.
    @Test
    func aRequestLargerThanOneReadIsAnswered() async throws {
        var session = try Self.startSession()
        try session.send([
            "jsonrpc": "2.0", "id": 1, "method": "initialize",
            "params": ["protocolVersion": "2025-06-18", "capabilities": [String: Any](), "clientInfo": ["name": "test", "version": "0"]],
        ])
        _ = try await session.next()

        // A target nothing can resolve, padded past the read buffer: the answer is a refusal, and a refusal
        // that arrives at all is the whole point — the frame was reassembled from many reads.
        try session.send([
            "jsonrpc": "2.0", "id": 2, "method": "tools/call",
            "params": ["name": "digest", "arguments": ["target": String(repeating: "A", count: 200_000)]],
        ])
        let call = try await session.next()

        #expect(call["id"] as? Int == 2)
        #expect(call["result"] != nil)

        await session.close()
    }

    /// A server whose stdout has died stops *there*, without waiting for a request that is never coming.
    ///
    /// The client's input is deliberately left open for the whole test, so nothing but the mid-answer check can end the loop. Without it the server sits in `for await` behind a pipe no one will ever write to again — alive, unreachable, holding the repository's index open — which is the orphan shape, reached from the other side.
    @Test
    func aServerWhoseOutputDiedStopsWithoutWaitingForAnotherRequest() async throws {
        let root = try MCPTestRepo.make()
        let toServer = Pipe()
        let fromServer = Pipe()
        let server = MCPServer(
            input: toServer.fileHandleForReading,
            output: fromServer.fileHandleForWriting,
            defaultRoot: root,
            log: { _ in }
        )
        let stopped = ServerStopBox()
        let task = Task { await stopped.record(server.run()) }
        defer {
            toServer.fileHandleForWriting.closeFile()
            task.cancel()
        }

        // Nobody will ever read a response again; the next write the server attempts fails.
        fromServer.fileHandleForReading.closeFile()
        var request = try JSONSerialization.data(withJSONObject: [
            "jsonrpc": "2.0", "id": 1, "method": "initialize",
            "params": ["protocolVersion": "2025-06-18", "capabilities": [String: Any](), "clientInfo": ["name": "test", "version": "0"]],
        ])
        request.append(0x0A)
        try toServer.fileHandleForWriting.write(contentsOf: request)

        let stop = await stopped.settled(within: 10)

        #expect(stop?.reason == "output-closed", "the server was still waiting for input with a dead stdout")
    }

    /// An input that fails is reported as a failed input, not as a client that hung up.
    ///
    /// A write-only descriptor gives `read(2)` a real `EBADF`, so this crosses the whole path — the read loop's failure branch, the closure it hands back, and the stop reason the lifecycle log is handed. The two endings have different culprits and would be diagnosed differently, which is the entire reason they are named apart.
    @Test
    func anInputThatFailsIsNotReportedAsAClientHangingUp() async throws {
        let root = try MCPTestRepo.make()
        let path = try TemporaryDirectory.make("unreadable-input")
            .appendingPathComponent("unreadable-input")
        let descriptor = open(path.path, O_WRONLY | O_CREAT, 0o600)
        #expect(descriptor >= 0)
        let server = MCPServer(
            input: FileHandle(fileDescriptor: descriptor, closeOnDealloc: true),
            output: Pipe().fileHandleForWriting,
            defaultRoot: root,
            log: { _ in }
        )

        let stop = await server.run()

        #expect(stop == .inputFailed(code: EBADF))
    }

    /// A line-range value is a `digest` target and nothing else — `where` refuses it exactly as it refuses any other missing `symbol:`, never healing it into a lookup that would then report "no declarations found" for lines a symbol index was never asked about.
    @Test
    func aLineRangeSentToWhereIsRefusedNotHealed() async throws {
        var session = try Self.startSession()

        try session.send([
            "jsonrpc": "2.0", "id": 1, "method": "tools/call",
            "params": ["name": "where", "arguments": ["target": "Shapes.swift:12:5:"]],
        ])
        let byTarget = try await session.next()
        let byTargetResult = try #require(byTarget["result"] as? [String: Any])
        let byTargetText = try #require((byTargetResult["content"] as? [[String: Any]])?.first?["text"] as? String)

        #expect(byTargetResult["isError"] as? Bool == true)
        #expect(byTargetText.contains("where needs a symbol"))

        try session.send([
            "jsonrpc": "2.0", "id": 2, "method": "tools/call",
            "params": ["name": "where", "arguments": ["query": "Shapes.swift:12"]],
        ])
        let byQuery = try await session.next()
        let byQueryResult = try #require(byQuery["result"] as? [String: Any])
        let byQueryText = try #require((byQueryResult["content"] as? [[String: Any]])?.first?["text"] as? String)

        #expect(byQueryResult["isError"] as? Bool == true)
        #expect(byQueryText.contains("where needs a symbol"))

        await session.close()
    }

    /// The stray key `aStrayAliasKeyAlongsideTargetsIsRefused` covers is refused when `target:` came too: a `target:` beside it stops it being healed, not being dropped, and dropping it answers one target short of what was asked.
    @Test
    func aStrayAliasKeyAlongsideTargetAndTargetsIsRefused() async throws {
        let root = try MCPTestRepo.make()

        let answer = try await Self.digest(["symbol": "Big", "target": "Alpha", "targets": ["Alpha.go()"]], in: root)

        #expect(answer.isError)
        #expect(answer.text.contains("digest was sent both targets: and symbol:"))
        #expect(answer.text.contains("target: and targets: already carry every target here"))
    }

    /// A truncated block served beside another names the call that pages it as a tool call — and that call, sent verbatim, pages the one block, for a leaf and a container alike.
    @Test
    func aTruncatedBlocksAdviceIsAToolCallThatPagesIt() async throws {
        let root = try MCPTestRepo.make()
        let body = (0 ..< 250).map { "    let value\($0) = \($0)" }.joined(separator: "\n")
        let nested = (0 ..< 250).map { "        let value\($0) = \($0)" }.joined(separator: "\n")
        try "func drain() {\n\(body)\n}\n\nstruct Long {\n    func run() {\n\(nested)\n    }\n}\n".write(
            to: root.appendingPathComponent("Sources/App/Long.swift"), atomically: true, encoding: .utf8
        )

        let answer = try await Self.digest(["target": "Sources/App/Long.swift:1-600"], in: root)
        let advice = answer.text.matches(of: /digest target:"(?<target>[^"]+)" offset:(?<offset>\d+)/).map { match in
            (target: String(match.output.target), offset: Int(match.output.offset) ?? 0)
        }

        #expect(advice.map(\.target) == ["Sources/App/Long.swift:1-252", "Sources/App/Long.swift:254-507"])
        for call in advice {
            let page = try await Self.digest(["target": call.target, "offset": call.offset], in: root)

            #expect(!page.isError, "\(call.target): \(page.text)")
            #expect(page.text.contains("(…200 body lines skipped)"), "\(call.target)")
            #expect(page.text.contains("let value249 = 249"), "\(call.target)")
        }
    }
}

private extension MCPServerTests {
    /// Where a server's stop reason lands, so a test can wait for it with a deadline.
    ///
    /// Polled rather than awaited: a regression that leaves `run()` suspended forever must fail this suite, and `await task.value` on a task that never returns hangs it instead.
    final class ServerStopBox: @unchecked Sendable {
        private let mutex = NSLock()
        private var value: ServerStop?

        func record(_ stop: ServerStop) {
            mutex.lock()
            defer { mutex.unlock() }
            value = stop
        }

        var current: ServerStop? {
            mutex.lock()
            defer { mutex.unlock() }
            return value
        }

        func settled(within seconds: Int) async -> ServerStop? {
            for _ in 0 ..< (seconds * 100) {
                if let value = current {
                    return value
                }
                try? await Task.sleep(for: .milliseconds(10))
            }
            return current
        }
    }

    /// One `digest` call against a fresh server over `root`, after the handshake: the answer's text and whether it was an error.
    static func digest(
        _ arguments: [String: Any],
        in root: URL,
        sourceLocation: SourceLocation = #_sourceLocation
    ) async throws -> (text: String, isError: Bool) {
        try await call("digest", arguments, in: root, sourceLocation: sourceLocation)
    }

    /// One tool call against a fresh server over `root`, after the handshake: the answer's text and whether it was an error.
    static func call(
        _ tool: String,
        _ arguments: [String: Any],
        in root: URL,
        sourceLocation: SourceLocation = #_sourceLocation
    ) async throws -> (text: String, isError: Bool) {
        var session = try startSession(defaultRoot: root)
        try session.send([
            "jsonrpc": "2.0", "id": 1, "method": "initialize",
            "params": ["protocolVersion": "2025-06-18", "capabilities": [String: Any](), "clientInfo": ["name": "test", "version": "0"]],
        ])
        _ = try await session.next()
        try session.send(["jsonrpc": "2.0", "method": "notifications/initialized"])
        try session.send(["jsonrpc": "2.0", "id": 2, "method": "tools/call", "params": ["name": tool, "arguments": arguments]])
        let call = try await session.next(sourceLocation: sourceLocation)
        await session.close()
        let result = try #require(call["result"] as? [String: Any], sourceLocation: sourceLocation)
        let content = try #require(result["content"] as? [[String: Any]], sourceLocation: sourceLocation)
        return try (#require(content.first?["text"] as? String, sourceLocation: sourceLocation), result["isError"] as? Bool == true)
    }

    /// One live server over a pipe pair, with helpers to exchange JSON lines.
    struct Session {
        let root: URL
        let toServer: Pipe
        let fromServer: Pipe
        let task: Task<ServerStop, Never>
        var responses: AsyncStream<String>.AsyncIterator

        func send(_ payload: [String: Any]) throws {
            var data = try JSONSerialization.data(withJSONObject: payload)
            data.append(0x0A)
            toServer.fileHandleForWriting.write(data)
        }

        mutating func next(sourceLocation: SourceLocation = #_sourceLocation) async throws -> [String: Any] {
            let line = try #require(await responses.next(), sourceLocation: sourceLocation)
            let object = try JSONSerialization.jsonObject(with: Data(line.utf8))
            return try #require(object as? [String: Any], sourceLocation: sourceLocation)
        }

        @discardableResult
        func close() async -> ServerStop {
            toServer.fileHandleForWriting.closeFile()
            return await task.value
        }
    }
}
