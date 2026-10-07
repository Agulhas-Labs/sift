//
// Copyright © Agulhas Labs
//

import ArgumentParser
import SiftCore

/// `sift similar` — the declarations whose shape is closest to one you already hold.
///
/// CLI only, on `affected`'s and `run`'s reasoning: the MCP tool list is re-sent on every turn of every agent, and this is a question asked once before a helper is written rather than one asked all day. `Sift.md` points at it from Bash.
struct SimilarCommand: AsyncParsableCommand {
    static var configuration: CommandConfiguration {
        CommandConfiguration(
            commandName: "similar",
            abstract: "Rank the declarations whose syntactic shape is closest to one you name.",
            discussion: """
            Answers "does this helper already exist?" when you already hold something shaped like it — the companion to `search calls:…`, which asks the same question when you only know the one call it cannot do without.

            Ranks on three axes, and says which shared callees earned each hit: the callees both bodies name, weighted by how rare each is across the tree scanned, so sharing `append` or `map` counts for a fraction of what sharing `rename` does; the control-flow skeleton; and the parameter and return type names as written.

            Candidates are funcs, inits, subscripts and computed vars that have a body. Read it as a lead, not a verdict: the match is syntactic, over written names, and an empty answer means nothing close by callee or shape — never that there is nothing to reuse.

            Examples:
              sift similar 'SetAsideStore.writeDurably(_:to:)'
              sift similar ShardLedger.replaceFile
              sift similar Sources/SiftCore/ShardLedger.swift:310-326
            """
        )
    }

    @Argument(help: "A member (Type.member, a labeled Type.save(_:to:), or the Module.Type.member that digest and where print) or a File.swift:12-40 line range. An overloaded or unresolvable target is answered with the candidates, as digest is.")
    var target: String

    @OptionGroup var rootOptions: RootOptions

    func run() async throws {
        try await StandardStreams.emit(answer())
    }

    /// The whole answer, header first and any adopted-root note under it.
    func answer(registry: RootsRegistry = .standard()) async throws -> String {
        let (engine, note) = try rootOptions.makeEngine(probing: target, registry: registry)
        return await Freshness.placing([note], under: engine.similar(target: target))
    }
}
