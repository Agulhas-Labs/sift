//
// Copyright © Agulhas Labs
//

import ArgumentParser
import SiftCore

/// `sift dupes` — groups of near-duplicate bodies across a tree, read as an audit rather than asked about one declaration.
///
/// CLI only, on `similar`'s reasoning: the MCP tool list is re-sent on every turn of every agent, and this is an audit run now and then from a shell, not a question asked mid-conversation.
struct DupesCommand: AsyncParsableCommand {
    static var configuration: CommandConfiguration {
        CommandConfiguration(
            commandName: "dupes",
            abstract: "Group the declarations whose bodies are near-duplicates of each other, across the tree or under a path.",
            discussion: """
            `similar`'s comparison run over every pair worth comparing: rarity-weighted shared callees decide it, control flow and written types order it, and pairs are joined into groups only where every two members are close, so A~B and B~C are one group of three only if A~C is close too. Groups rank by the lines folding one would save, discounted by its weakest pair; test and preview code comes after the rest. Each group names the callees its members share.

            Read it as a lower bound, never a verdict: the same callees do not mean the same behaviour, a body that inlines what another calls is invisible to it, and an empty answer means nothing close by callee, not that nothing is duplicated.

            Examples:
              sift dupes
              sift dupes --offset 10
              sift dupes --min 0.8 --no-tests
              sift dupes Sources/SiftCore
              sift dupes Sources/SiftCLI Sources/SiftMCP
            """
        )
    }

    @Argument(help: "Files or directories to audit, relative to the repository root. None audits the whole indexed tree.")
    var paths: [String] = []

    @Option(help: "The shared-callee overlap, 0 to 1, every pair in a group must reach (default 0.50).")
    var min: Double?

    @Option(help: "Skip this many groups (pagination cursor from a truncated: marker).")
    var offset = 0

    @Flag(inversion: .prefixedNo, help: "Rank test and preview code (test functions, fixtures, mocks, previews, generated files, SwiftUI body properties) with the rest; --no-tests leaves it out. Neither: ranked after the rest.")
    var tests: Bool?

    @OptionGroup var rootOptions: RootOptions

    var output: CommandOutput = .standard

    func validate() throws {
        if let min, !(0 ... 1).contains(min) {
            throw ValidationError("--min is a shared-callee overlap, from 0 to 1; \(min) is outside it.")
        }
    }

    func run() async throws {
        try await output.emit(answer())
    }

    /// The whole answer, header first and any adopted-root note under it.
    func answer(registry: RootsRegistry = .standard()) async throws -> String {
        let (engine, note) = try rootOptions.makeEngine(registry: registry)
        let testCode: DupesOptions.TestCode = switch tests {
        case nil: .rankedLast
        case true?: .rankedWithTheRest
        case false?: .leftOut
        }
        let options = DupesOptions(minimumOverlap: min, offset: offset, testCode: testCode)
        return await Freshness.placing([note], under: engine.dupes(scope: paths, options: options))
    }
}

extension DupesCommand {
    /// Only the parsed arguments decode; the output a test injects is not an argument.
    enum CodingKeys: String, CodingKey {
        case paths
        case min
        case offset
        case tests
        case rootOptions
    }
}
