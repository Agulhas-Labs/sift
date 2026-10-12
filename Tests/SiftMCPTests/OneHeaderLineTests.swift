//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCore
@testable import SiftMCP
import Testing

/// Each answer opens with one header line and repeats nothing the call already carries (Docs/Design.md §2, *One header line*): `digest` has no `semantic:` field where `where` keeps it, and no answer echoes its query, except the hook's answer for several names, which labels each part.
@Suite(.temporaryDirectories)
struct OneHeaderLineTests {
    private static func temporaryRegistry() throws -> RootsRegistry {
        try RootsRegistry(fileURL: TemporaryDirectory.make("roots").appendingPathComponent("roots.json"))
    }

    private static func lines(_ text: String) -> [String] {
        text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    }

    @Test
    func digestSearchAndStringsCarryNoSemanticFieldWhereWhereKeepsIt() async throws {
        let repository = try MCPTestRepo.make()
        let server = try AnswerHeaderTests.Server(defaultRoot: repository, registry: Self.temporaryRegistry())

        let digest = try await server.call("digest", ["target": "Alpha"])
        let search = try await server.call("search", ["query": "name:Alpha"])
        let strings = try await server.call("strings", ["query": "anything"])
        let lookup = try await server.call("where", ["symbol": "Alpha"])
        await server.close()

        #expect(Self.lines(digest)[0].hasPrefix("tree: \(repository.lastPathComponent)  head: "))
        #expect(Self.lines(search)[0] == "tree: \(repository.lastPathComponent)  source: live")
        #expect(Self.lines(lookup)[0].contains("  semantic: "), "\(lookup)")
        for answer in [digest, search, strings] {
            #expect(!Self.lines(answer)[0].contains("semantic:"), "\(answer)")
        }
    }

    @Test
    func noAnswerEchoesAQueryReadAsSent() async throws {
        let repository = try MCPTestRepo.make()
        let server = try AnswerHeaderTests.Server(defaultRoot: repository, registry: Self.temporaryRegistry())

        let search = try await server.call("search", ["query": "name:Alpha"])
        let strings = try await server.call("strings", ["query": "anything"])
        let lookup = try await server.call("where", ["symbol": "Alpha"])
        await server.close()

        #expect(!Self.lines(search).contains { $0.hasPrefix("search ") }, "\(search)")
        #expect(!Self.lines(strings).contains { $0.hasPrefix("strings ") }, "\(strings)")
        #expect(!Self.lines(lookup).contains { $0.hasPrefix("where ") }, "\(lookup)")
    }

    @Test
    func aSearchReadAsOtherThanSentKeepsItsEcho() throws {
        #expect(try StructuralQuery("Alpha").echo == "search name:Alpha")
        #expect(try StructuralQuery("name:Alpha|Beta").echo == "search name:Alpha|Beta — name: any of Alpha, Beta")
        #expect(try StructuralQuery("name:Alpha").echo == nil)
    }

    @Test
    func theHooksAnswerForSeveralNamesLabelsEachPartAndForOneNameNone() async throws {
        let root = try await InPlaceNamesTests.builtPackage()

        let one = try #require(try await InPlaceAnswerTests.answered("grep -rn Depot Sources", in: root))
        let both = try #require(try await InPlaceAnswerTests.answered("grep -rnE 'Depot|Gizmo' Sources", in: root))
        let single = try #require(InPlaceAnswer.answer(inReason: one.reason))
        let several = try #require(InPlaceAnswer.answer(inReason: both.reason))

        #expect(!Self.lines(single).contains("where Depot"), "\(single)")
        #expect(Self.lines(several).contains("where Depot"), "\(several)")
        #expect(Self.lines(several).contains("where Gizmo"), "\(several)")
    }
}
