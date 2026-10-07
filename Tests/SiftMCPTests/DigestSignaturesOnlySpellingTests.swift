//
// Copyright © Agulhas Labs
//

import Foundation
@testable import SiftCLI
import SiftCore
import Testing

/// The `digest` flag for dropping doc summaries and attributes, in both spellings.
///
/// The MCP parameter is `signaturesOnly` and the CLI flag was `--signatures-only`, so a caller carrying the parameter's name over to the command line was refused. Both spellings reach the same option.
@Suite(.temporaryDirectories)
struct DigestSignaturesOnlySpellingTests {
    @Test
    func bothSpellingsSetTheOption() throws {
        #expect(try DigestCommand.parse(["Alpha", "--signatures-only"]).signaturesOnly)
        #expect(try DigestCommand.parse(["Alpha", "--signaturesOnly"]).signaturesOnly)
        #expect(try !DigestCommand.parse(["Alpha"]).signaturesOnly)
    }

    @Test
    func bothSpellingsGiveTheSameAnswer() async throws {
        let root = try MCPTestRepo.make()
        let registry = try RootsRegistry(fileURL: TemporaryDirectory.make("roots").appendingPathComponent("roots.json"))

        let hyphenated = try await DigestCommand.parse(["Alpha", "--signatures-only", "--root", root.path]).answer(registry: registry)
        let camelCase = try await DigestCommand.parse(["Alpha", "--signaturesOnly", "--root", root.path]).answer(registry: registry)

        #expect(!hyphenated.isEmpty)
        #expect(hyphenated == camelCase)
    }
}
