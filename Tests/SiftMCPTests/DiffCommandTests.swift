//
// Copyright © Agulhas Labs
//

import ArgumentParser
import Foundation
@testable import SiftCLI
@testable import SiftCore
import Testing

/// `sift diff` as the command line runs it: a range it will not read is refused in its own words, under the header, and with a nonzero exit — so a script can tell a refusal from an empty change without parsing prose.
@Suite(.temporaryDirectories)
struct DiffCommandTests {
    private static func temporaryRegistry() throws -> RootsRegistry {
        try RootsRegistry(fileURL: TemporaryDirectory.make("roots").appendingPathComponent("roots.json"))
    }

    @Test
    func aNameThatIsNoCommitIsRefusedUnderTheHeader() async throws {
        let repository = try MCPTestRepo.make()

        let (text, refused) = try await DiffCommand.parse(["nonexistent", "--root", repository.path]).answer(registry: Self.temporaryRegistry())
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)

        #expect(refused)
        #expect(lines.first?.hasPrefix("tree: ") == true)
        #expect(lines.dropFirst().first?.hasPrefix("sift diff: `nonexistent` does not name a commit in this repository") == true)
    }

    /// A refusal reads nothing the index holds, so it does not pay for bringing the index up to date — and its header says it read nothing stored.
    @Test
    func aRefusedRangeDoesNotRefreshTheIndex() async throws {
        let repository = try MCPTestRepo.make()

        let (text, refused) = try await DiffCommand.parse(["HEAD..", "--root", repository.path]).answer(registry: Self.temporaryRegistry())
        let counts = try SiftEngine(directory: repository).store.counts()

        #expect(refused)
        #expect(counts.files == 0)
        #expect(text.split(separator: "\n").first?.contains("nothing stored to go stale") == true)
    }

    @Test
    func aRefusedRangeExitsNonzero() async throws {
        let repository = try MCPTestRepo.make()
        var command = try DiffCommand.parse(["HEAD..", "--root", repository.path])
        let registry = try Self.temporaryRegistry()
        command.registry = { registry }

        await #expect(throws: ExitCode(1)) {
            try await command.run()
        }
    }
}
