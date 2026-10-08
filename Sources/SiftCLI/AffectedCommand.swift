//
// Copyright © Agulhas Labs
//

import ArgumentParser
import SiftCore

/// `sift affected` — the test targets and tests that reference what a diff changed, and the arguments a runner selects them by.
///
/// CLI only, deliberately. Docs/Design.md §4 keeps the MCP surface to the query tools because every exposed tool costs description tokens in every session, and this one is invoked next to the build it informs — from a shell, beside `sift run -- swift test`, or from a gate script — rather than mid-conversation. `run` is CLI-only for the same reason.
struct AffectedCommand: AsyncParsableCommand {
    static var configuration: CommandConfiguration {
        CommandConfiguration(
            commandName: "affected",
            abstract: "Which tests reference the symbols a diff changed, with the -only-testing: arguments. It reports: it never runs tests and never decides what to skip."
        )
    }

    @Option(name: .customLong("from"), help: "Read the change set from this commit up to --to (default HEAD), instead of from the working tree. Unlike `sift diff X`, a lone --from X is X..HEAD, not X's own change; for that, pass --from X~1 --to X.")
    var from: String?

    @Option(name: .customLong("to"), help: "The far end of --from's range (default HEAD).")
    var to: String = "HEAD"

    @Option(name: .customLong("depth"), help: "Reference hops followed out from the changed declarations. A bounded walk is bounded, and the answer says at what.")
    var depth: Int = AffectedOptions.defaultDepth

    @Option(name: .customLong("reached"), help: "Also say whether this test or suite was reached, and at how many hops, even where the lists cut it off. Spell it as the list prints it (Target.Suite/function()); a fragment matches every name containing it. Repeat it for several names.")
    var reached: [String] = []

    @OptionGroup var rootOptions: RootOptions

    func validate() throws {
        guard from != nil || to == "HEAD" else {
            throw ValidationError("--to names the far end of --from's range; pass --from as well, or neither to read the working tree.")
        }
        guard depth >= 1 else {
            throw ValidationError("--depth must be at least 1: zero hops would report no tests at all, which reads as 'nothing is affected'.")
        }
    }

    func run() async throws {
        try await StandardStreams.emit(answer())
    }

    /// The whole answer, header first and any adopted-root note under it.
    func answer(registry: RootsRegistry = .standard()) async throws -> String {
        let (engine, note) = try rootOptions.makeEngine(registry: registry)
        let freshness = try await engine.ensureFresh()
        let options = AffectedOptions(range: from.map { AffectedOptions.CommitRange(from: $0, to: to) }, depth: depth, probes: reached)
        return try await Freshness.placing([note], under: engine.affected(options: options, freshness: freshness))
    }
}
