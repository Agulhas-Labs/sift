//
// Copyright © Agulhas Labs
//

import Foundation
import SiftCore
@testable import SiftMCP
import Testing

/// Covers the logged refusals a spelling caused, replayed through a live server: a misspelt argument key or grammar word is read as the one it spells and said, a misspelt value is still refused, and a statement asked for as a kind is refused with the reason.
///
/// The calls are the whole population of refusals in one usage log, with its names swapped for this repository's placeholders: five `digest type:` calls, two searches writing `in:` for `path:`, one writing `kind:function` and `file:`, and one asking for `kind:switch`.
@Suite(.temporaryDirectories)
struct SpellingHealTests {
    private static func repository() throws -> URL {
        let root = try MCPTestRepo.make()
        try MCPTestRepo.add([
            "Sources/App/Gizmo.swift": "struct Gizmo {}\nstruct GizmoCore {}\nstruct DepotStore {}\nstruct DepotCatalog {}\n",
            "Sources/App/Text/Label.swift": "struct Label {\n    init() {}\n}\n",
            "Sources/App/GizmoApp.swift": """
            struct GizmoApp {
                func save(to path: String) {}
                func save(from path: String) {}
                func left() {
                    save(to: "a")
                }
                func right() {
                    save(from: "b")
                }
            }

            """,
            "Tests/AppTests/AlphaTests.swift": """
            struct AlphaTests {
                func lookup() {
                    Alpha().go()
                }

                func rendered() {}

                func check() {
                    rendered()
                }
            }

            """,
        ], to: root)
        return root
    }

    /// One call of `tool` against a fresh server over `root`, after the handshake: the answer's text and whether it was an error.
    private static func call(
        _ tool: String,
        _ arguments: [String: Any],
        in root: URL,
        sourceLocation: SourceLocation = #_sourceLocation
    ) async throws -> (text: String, isError: Bool) {
        let toServer = Pipe()
        let fromServer = Pipe()
        let server = MCPServer(input: toServer.fileHandleForReading, output: fromServer.fileHandleForWriting, defaultRoot: root, log: { _ in })
        let task = Task { await server.run() }
        var responses = FileHandleLines.lines(from: fromServer.fileHandleForReading).makeAsyncIterator()
        func send(_ payload: [String: Any]) throws {
            var data = try JSONSerialization.data(withJSONObject: payload)
            data.append(0x0A)
            toServer.fileHandleForWriting.write(data)
        }
        try send([
            "jsonrpc": "2.0", "id": 1, "method": "initialize",
            "params": ["protocolVersion": "2025-06-18", "capabilities": [String: Any](), "clientInfo": ["name": "test", "version": "0"]],
        ])
        _ = await responses.next()
        try send(["jsonrpc": "2.0", "method": "notifications/initialized"])
        try send(["jsonrpc": "2.0", "id": 2, "method": "tools/call", "params": ["name": tool, "arguments": arguments]])
        let line = try #require(await responses.next(), sourceLocation: sourceLocation)
        toServer.fileHandleForWriting.closeFile()
        _ = await task.value
        let response = try #require(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any], sourceLocation: sourceLocation)
        let result = try #require(response["result"] as? [String: Any], sourceLocation: sourceLocation)
        let content = try #require(result["content"] as? [[String: Any]], sourceLocation: sourceLocation)
        return try (#require(content.first?["text"] as? String, sourceLocation: sourceLocation), result["isError"] as? Bool == true)
    }

    /// `type:` is the plain word for what a digest names, and a name under it is read as `target:`.
    @Test(arguments: ["Alpha", "Gizmo", "GizmoCore", "DepotStore", "DepotCatalog"])
    func aDigestNamedUnderTypeIsAnswered(name: String) async throws {
        let answer = try await Self.call("digest", ["type": name], in: Self.repository())

        #expect(!answer.isError, "\(answer.text)")
        #expect(answer.text.contains("struct \(name)"))
        #expect(answer.text.contains("read type: as target:"))
    }

    @Test
    func aSearchWritingInForPathIsAnswered() async throws {
        let root = try Self.repository()
        let inFile = try await Self.call("search", ["query": "in:Tests/AppTests/AlphaTests.swift kind:func name:lookup"], in: root)
        let inDirectory = try await Self.call("search", ["query": "kind:init in:Text"], in: root)

        #expect(!inFile.isError, "\(inFile.text)")
        #expect(inFile.text.contains("read in: as path: (a path substring, not a type) — the spelling search takes."))
        #expect(inFile.text.contains("search path:Tests/AppTests/AlphaTests.swift kind:func name:lookup"))
        #expect(inFile.text.contains("AlphaTests.lookup()"))
        #expect(!inDirectory.isError, "\(inDirectory.text)")
        #expect(inDirectory.text.contains("read in: as path: (a path substring, not a type)"))
        #expect(inDirectory.text.contains("Label.init()"))
    }

    /// Both misspellings in the one call are read, and said on one line; the value `rendered()` is not touched.
    @Test
    func aSearchWritingFunctionAndFileIsAnswered() async throws {
        let answer = try await Self.call(
            "search", ["query": "calls:rendered() kind:function file:Tests/AppTests/AlphaTests.swift"], in: Self.repository()
        )

        #expect(!answer.isError, "\(answer.text)")
        #expect(
            answer.text
                .contains("read calls:rendered() as calls:rendered, kind:function as kind:func, file: as path: (a path substring, not a type) — the spellings search takes.")
        )
        #expect(answer.text.contains("search calls:rendered kind:func path:Tests/AppTests/AlphaTests.swift"))
    }

    /// The reading comes as the line under the header, before the answer it explains.
    @Test
    func theReadingIsTheLineUnderTheHeader() async throws {
        let answer = try await Self.call("search", ["query": "kind:function name:lookup"], in: Self.repository())
        let lines = answer.text.split(separator: "\n")

        #expect(lines.dropFirst().first == "read kind:function as kind:func — the spelling search takes.")
        #expect(answer.text.contains("AlphaTests.lookup()"))
    }

    /// A switch is no declaration, so the refusal says so and names the terms that find a name inside a body — never `has:`, which has no switch shape.
    @Test
    func aStatementAskedForAsAKindIsRefusedWithTheReason() async throws {
        let answer = try await Self.call("search", ["query": "kind:switch"], in: Self.repository())

        #expect(answer.isError)
        #expect(answer.text.contains("switch is a statement, not a declaration"))
        #expect(answer.text.contains("uses:"))
        #expect(answer.text.contains("calls:"))
        #expect(!answer.text.contains("has:"))
    }

    /// A value is a meaning, not a spelling: a misspelt name under `type:` is read as `target:` and then refused as a name no declaration carries, never answered as the nearest one.
    @Test
    func aMisspeltValueIsStillRefused() async throws {
        let answer = try await Self.call("digest", ["type": "Alpah"], in: Self.repository())

        #expect(answer.text.contains("read type: as target:"))
        #expect(answer.text.contains("no symbol named Alpah"))
        #expect(!answer.text.contains("struct Alpha"))
    }

    /// `calls:rendered()` finds what `calls:rendered` finds — parentheses spell the callee's own name, not a different value — and says so under the header.
    @Test
    func aParenthesizedCalleeFindsWhatTheBareNameFinds() async throws {
        let root = try Self.repository()
        let parenthesized = try await Self.call("search", ["query": "calls:rendered()"], in: root)
        let bare = try await Self.call("search", ["query": "calls:rendered"], in: root)

        #expect(!parenthesized.isError, "\(parenthesized.text)")
        #expect(parenthesized.text.contains("read calls:rendered() as calls:rendered — the spelling search takes."))
        #expect(parenthesized.text.contains("AlphaTests.check()"))
        #expect(parenthesized.text.contains(bare.text.split(separator: "\n").last.map(String.init) ?? "\0"))
    }

    /// A value with unbalanced parentheses is not a spelling of any callee, so it refuses rather than answering a confident zero.
    @Test
    func anUnbalancedCallsValueRefuses() async throws {
        let answer = try await Self.call("search", ["query": "calls:rendered("], in: Self.repository())

        #expect(answer.isError)
        #expect(answer.text.contains("is not a call"))
    }

    /// `calls:save(to:)` carries a real label the index keeps no record of, so healing it down to `calls:save` widens what the count answers — `save(from:)` callers are counted too — and the note says so plainly rather than calling it a bare spelling; a bare `()` keeps the plain spelling note.
    @Test
    func aLabelledCalleeCountsEveryOverloadAndSaysSo() async throws {
        let root = try Self.repository()
        let labelled = try await Self.call("search", ["query": "calls:save(to:)", "count": true], in: root)
        let bareParens = try await Self.call("search", ["query": "calls:save()", "count": true], in: root)

        #expect(!labelled.isError, "\(labelled.text)")
        #expect(labelled.text.contains("read calls:save(to:) as calls:save — labels are not indexed, so this matches every call named save, whatever its labels."))
        #expect(labelled.text.contains("3 declaration(s)"))
        #expect(!bareParens.isError, "\(bareParens.text)")
        #expect(bareParens.text.contains("read calls:save() as calls:save — the spelling search takes."))
        #expect(!bareParens.text.contains("labels are not indexed"))
    }

    /// `name:save()` gets the same base-name reading as `calls:`/`uses:`, rather than a confident zero for a name no declaration is spelled with parentheses.
    @Test
    func aNameValueWithParenthesesIsHealedTheSameWay() async throws {
        let answer = try await Self.call("search", ["query": "name:save()"], in: Self.repository())

        #expect(!answer.isError, "\(answer.text)")
        #expect(answer.text.contains("read name:save() as name:save — the spelling search takes."))
        #expect(answer.text.contains("GizmoApp.save"))
    }

    /// A refusal that follows a heal names the word the call actually typed, not only the one it was read as.
    @Test
    func aRefusalAfterAHealNamesTheHealedReading() async throws {
        let answer = try await Self.call("search", ["query": "in:"], in: Self.repository())

        #expect(answer.isError)
        #expect(answer.text.contains("\"path:\" has no value"))
        #expect(answer.text.contains("read in: as path:"))
    }
}
