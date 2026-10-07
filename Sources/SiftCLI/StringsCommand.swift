//
// Copyright © Agulhas Labs
//

import ArgumentParser
import SiftCore

/// `sift strings` — display text ↔ localization key, then the literal call sites and the Swift string literals holding the text.
struct StringsCommand: AsyncParsableCommand {
    static var configuration: CommandConfiguration {
        CommandConfiguration(
            commandName: "strings",
            abstract: "Trace display text to its localization key (or a key to its text) across .xcstrings/.strings catalogs, with literal Swift call sites, and to the Swift string literals that hold the text."
        )
    }

    @Argument(help: "Display text (matched case-insensitively across all languages) or a key (matched exactly or by substring); Swift string literals match with smart case — any uppercase letter in the query makes that match case-sensitive.")
    var query: String

    @OptionGroup var rootOptions: RootOptions

    func run() async throws {
        try await LoggedLookup.emit(tool: "strings", target: query, in: rootOptions.directory) { try served() }
    }

    /// The whole answer, header first and any adopted-root note under it.
    func answer(registry: RootsRegistry = .standard()) throws -> String {
        try served(registry: registry).text
    }

    /// That answer with what the log records beside it: the repository it was computed against, and nothing to weigh it against.
    func served(registry: RootsRegistry = .standard()) throws -> LoggedLookup.Served {
        let (engine, note) = try rootOptions.makeEngine(registry: registry)
        let text = try Freshness.placing([note], under: engine.strings(query: query))
        return LoggedLookup.Served(text: text, root: engine.repoRoot.path)
    }
}
