//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCLI
import SiftCore
@testable import SiftMCP
import Testing

/// `at` on the server's `digest` and `where` tools answers exactly as `--at` does on the command line.
@Suite(.temporaryDirectories)
struct RevisionAnswerTests {
    private static func registry() throws -> RootsRegistry {
        try RootsRegistry(fileURL: TemporaryDirectory.make("roots").appendingPathComponent("roots.json"))
    }

    @Test func theServersDigestAtARevisionIsTheCommandLinesAnswer() async throws {
        let root = try MCPTestRepo.make()
        let registry = try Self.registry()
        let command = try await DigestCommand.parse(["Alpha", "--at", "HEAD", "--root", root.path]).answer(registry: registry)
        let server = try AnswerHeaderTests.Server(defaultRoot: root, registry: registry)
        let served = try await server.call("digest", ["target": "Alpha", "at": "HEAD"])
        await server.close()

        #expect(served == command)
        #expect(served.split(separator: "\n").first?.contains("at: HEAD = ") == true, "\(served)")
        #expect(served.contains("func go()"), "\(served)")
    }

    @Test func theServersWhereAtARevisionIsTheCommandLinesAnswer() async throws {
        let root = try MCPTestRepo.make()
        let registry = try Self.registry()
        let command = try await WhereCommand.parse(["Alpha.go", "--at", "HEAD", "--root", root.path]).answer(registry: registry)
        let server = try AnswerHeaderTests.Server(defaultRoot: root, registry: registry)
        let served = try await server.call("where", ["symbol": "Alpha.go", "at": "HEAD"])
        await server.close()

        #expect(served == command)
        #expect(served.contains("Sources/App/Alpha.swift:4"), "\(served)")
    }
}
