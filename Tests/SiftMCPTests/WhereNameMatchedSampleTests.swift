//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCLI
import SiftCore
@testable import SiftMCP
import Testing

/// A function the store cannot answer callers for is answered at the shell with its name-matched sites' count and the first few of them.
///
/// Over MCP, and in the hook's in-place answer, the block keeps its full capped list: those answers are a contract other tools read, and the hook stands its answer in for a search whose every site it must show.
@Suite(.temporaryDirectories)
struct WhereNameMatchedSampleTests {
    /// The lines the fixture's caller writes its calls on, in order.
    private static let callLines = Array(3 ... 14)

    private static func registry() throws -> RootsRegistry {
        try RootsRegistry(fileURL: TemporaryDirectory.make("roots").appendingPathComponent("roots.json"))
    }

    /// A repository whose one static function is called by name on twelve lines, with no index store to say who calls it.
    private static func repository() throws -> URL {
        let root = try MCPTestRepo.make()
        let calls = callLines.map { _ in "        Beta.assemble()" }.joined(separator: "\n")
        try MCPTestRepo.add([
            "Sources/App/Beta.swift": "enum Beta {\n    static func assemble() {}\n}\n",
            "Sources/App/Caller.swift": "struct Caller {\n    func run() {\n\(calls)\n    }\n}\n",
        ], to: root)
        return root
    }

    /// The line numbers the name-matched block lists, read off its site rows.
    private static func listedLines(in answer: String) -> [Int] {
        answer.split(separator: "\n").flatMap { line -> [Int] in
            let trimmed = line.drop(while: \.isWhitespace)
            guard trimmed.hasPrefix(":"), let detail = trimmed.range(of: "  in ") else { return [] }
            return trimmed[..<detail.lowerBound].split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces).dropFirst()) }
        }
    }

    /// The answer with the block's site rows and its truncation count taken out — everything that is not the list itself.
    private static func withoutSiteRows(_ answer: String) -> [Substring] {
        answer.split(separator: "\n", omittingEmptySubsequences: false).filter { line in
            let trimmed = line.drop(while: \.isWhitespace)
            return !(trimmed.hasPrefix(":") || trimmed.hasPrefix("truncated:"))
        }
    }

    @Test
    func theCommandLineListsTheCountAndTheFirstFiveSites() async throws {
        let root = try Self.repository()
        let answer = try await WhereCommand.parse(["Beta.assemble", "--root", root.path]).answer(registry: Self.registry())

        #expect(answer.contains("callers/overrides: NOT ANSWERED"), "\(answer)")
        #expect(answer.contains("\"assemble\" (12 call sites in 1 file"), "\(answer)")
        #expect(Self.listedLines(in: answer) == Array(Self.callLines.prefix(5)), "\(answer)")
        #expect(answer.contains("\n    truncated: 7 more call sites"), "\(answer)")
    }

    @Test
    func theServerAndTheInPlaceAnswerKeepEverySite() async throws {
        let root = try Self.repository()
        let registry = try Self.registry()
        let command = try await WhereCommand.parse(["Beta.assemble", "--root", root.path]).answer(registry: registry)
        let server = try AnswerHeaderTests.Server(defaultRoot: root, registry: registry)
        let served = try await server.call("where", ["symbol": "Beta.assemble"])
        await server.close()
        let engine = try SiftEngine(directory: root, registry: registry)
        let inPlace = try #require(await ExactAnswer.lookup(in: engine, of: "Beta.assemble", freshness: engine.ensureFresh()))

        #expect(Self.listedLines(in: served) == Self.callLines, "\(served)")
        #expect(!served.contains("truncated:"), "\(served)")
        #expect(Self.listedLines(in: inPlace.body) == Self.callLines, "\(inPlace.body)")
        // Only the list differs between the faces, and it locates nothing either way.
        #expect(Self.withoutSiteRows(served) == Self.withoutSiteRows(command), "\(served)\n---\n\(command)")
        #expect(ExactAnswer.locations(inWhereAnswer: served) == ExactAnswer.locations(inWhereAnswer: command))
        #expect(!ExactAnswer.locations(inWhereAnswer: served).isEmpty, "\(served)")
    }
}
