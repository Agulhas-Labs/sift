//
// Copyright © Agulhas Labs
//

import ArgumentParser
import SiftCore

/// `sift search` — find declarations by shape rather than by name.
struct SearchCommand: AsyncParsableCommand {
    static var configuration: CommandConfiguration {
        CommandConfiguration(
            commandName: "search",
            abstract: "Find Swift declarations by structural shape.",
            discussion: """
            The query is whitespace-separated field:value terms, ANDed, each negated with a leading !.
            Every field takes a|b for any of several values (kind:struct|enum); a negated one matches none of them.

              kind:      func struct class actor enum protocol extension init var subscript deinit
                         case typealias associatedtype operator precedencegroup macro
              attr:      an attribute written on the declaration, without the @ (Test, MainActor)
              name:      substring of the declaration's name, case-insensitive; a|b for any of several,
                         /regex/ for a pattern (case-insensitive, unanchored); either pattern lists
                         the names it matches whole first
              calls:     a call in the declaration's subtree, matched on the callee's base name
              uses:      any identifier in the subtree — a superset of calls:
              inherits:  a written conformance or superclass
              modifier:  static private public final override nonisolated …
              effect:    async throws
              has:       closure await try forceUnwrap forceTry forceCast optionalChain
              sig:       substring of the declaration's signature as written (return and parameter types),
                         case-sensitive; /regex/ for a case-insensitive pattern
              imports:   exact module name the file imports — file-scoped, gates every declaration in it
              path:      substring of the file path, case-sensitive, applied before the file is parsed;
                         /regex/ for a case-insensitive pattern
              owner:     the type a member is declared in, its extensions included (exact name or Outer.Inner)

            Examples:
              sift search 'kind:func attr:Test calls:Task !has:await'
              sift search 'kind:class inherits:UIViewController has:forceUnwrap'
              sift search 'kind:func effect:async !has:await path:Sources'
              sift search 'kind:func sig:completion !effect:async'
              sift search 'imports:HealthKit kind:class'
              sift search 'kind:func modifier:static owner:StructuralQuery'
            """
        )
    }

    @Argument(help: "field:value terms, ANDed, negated with a leading !.")
    var query: String

    @Option(help: "Skip this many matches (from a truncated: marker).")
    var offset = 0

    @Flag(help: "The header and the summary line only, plus a per-module breakdown — no listing.")
    var count = false

    @OptionGroup var rootOptions: RootOptions

    func run() async throws {
        try await LoggedLookup.emit(tool: "search", target: query, in: rootOptions.directory) { try await served() }
    }

    /// The whole answer, header first and any adopted-root note under it.
    func answer(registry: RootsRegistry = .standard()) async throws -> String {
        try await served(registry: registry).text
    }

    /// That answer with what the log records beside it: the repository it was computed against, and nothing to weigh it against.
    func served(registry: RootsRegistry = .standard()) async throws -> LoggedLookup.Served {
        // A malformed query probes nothing; the parse below rejects it with the field list, which is the error worth showing.
        let (engine, note) = try rootOptions.makeEngine(probing: (try? StructuralQuery(query))?.probeName, registry: registry)
        let text = try await Freshness.placing([note], under: engine.search(query: query, offset: offset, count: count))
        return LoggedLookup.Served(text: text, root: engine.repoRoot.path)
    }
}
