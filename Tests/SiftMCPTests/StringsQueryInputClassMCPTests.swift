//
// Copyright © Agulhas Labs
//

import Foundation
import SiftCore
@testable import SiftMCP
import Testing

/// Covers the MCP `strings` tool over queries that are not plain words, where a trap would end the server for the whole session: each is answered by one server, which still answers the call after them.
@Suite(.temporaryDirectories)
struct StringsQueryInputClassMCPTests {
    static let queries: [String] = [
        ".title", "°C", "% complete", "%lld", "%1$@", "%#@count@", "%arg days", "%@ against", "@ against",
        "", " ", "  Hello  ", "%", "@", "\\", "\"", "'", "%%%", "\0", "\0Alpha", "\nAlpha", "Al\npha",
        "\u{301}Alpha", "👍 Alpha", "İ Alpha", "Sources/App/Alpha.swift", String(repeating: "%a ", count: 400),
    ]

    @Test
    func everyQueryOfTheClassIsAnsweredByOneServer() async throws {
        let root = try MCPTestRepo.make()
        let registry = try RootsRegistry(fileURL: TemporaryDirectory.make("roots").appendingPathComponent("roots.json"))
        let server = try AnswerHeaderTests.Server(defaultRoot: root, registry: registry)

        for query in Self.queries {
            let answer = try await server.call("strings", ["query": query])

            #expect(answer.contains("no string catalogs"), "\(query.debugDescription): \(answer)")
        }
        let after = try await server.call("strings", ["query": "Alpha"])
        await server.close()

        #expect(after.contains("no string catalogs"), "\(after)")
    }
}
