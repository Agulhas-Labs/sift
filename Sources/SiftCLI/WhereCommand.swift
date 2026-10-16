//
// Copyright © Agulhas Labs
//

import ArgumentParser
import SiftCore

/// `sift where` — one resolved answer for a symbol: declarations, extensions, conformers.
struct WhereCommand: AsyncParsableCommand {
    static var configuration: CommandConfiguration {
        CommandConfiguration(commandName: "where", abstract: "Resolve a symbol: declarations, extensions, conformers, callers — and, for a type, what uses it.")
    }

    @Argument(help: "Name, Module.Name, Type.member, or a labeled form like save(_:to:).")
    var symbol: String

    @Flag(name: .customLong("syntactic"), help: "Skip the index store: no callers/overrides, no store open.")
    var syntacticOnly = false

    @Flag(name: .customLong("refs"), help: "List every reference site, for rename/delete sweeps — a type's usage verdict comes without it. After the code sites, the comments, strings, Markdown lines and file names that write the name, under not code.")
    var includeReferences = false

    @Flag(name: .customLong("files"), help: "With --refs (implied): only the files the sweep names, one per line, with counts.")
    var filesOnly = false

    @Flag(name: .customLong("decl"), help: "Only the declarations: where it is defined, nothing else.")
    var declarationsOnly = false

    @Option(name: .customLong("offset"), help: "Skip this many files in the references listing (from a truncated: marker).")
    var offset: Int = 0

    @Option(name: .customLong("at"), help: "Answer as of this commit, branch or tag: declarations from a syntactic parse of that revision's files that name the symbol, call sites by name only — never the index or the working tree.")
    var revision: String?

    @OptionGroup var rootOptions: RootOptions

    /// Name-matched call sites listed per unanswered symbol at the shell: the block's heading carries the total, so a sample says what kind of sites they are without a page of leads.
    static var nameMatchedSiteCap: Int {
        5
    }

    func validate() throws {
        if let message = BlankTargetRefusal.message(tool: "where", targets: [symbol]) {
            throw ValidationError(message)
        }
        if declarationsOnly, includeReferences || filesOnly {
            throw ValidationError("--decl answers where \(symbol) is declared, and --refs and --files every place it is written: pass one.")
        }
    }

    func run() async throws {
        // An answer as of another revision lists where the symbol was then, which locates nothing in today's files.
        try await LoggedLookup.emit(tool: "where", target: symbol, in: rootOptions.directory, locates: revision == nil) { try await served() }
    }

    /// The whole answer, header first and any adopted-root note under it.
    func answer(registry: RootsRegistry = .standard()) async throws -> String {
        try await served(registry: registry).text
    }

    /// That answer with what the log records beside it: the repository it was computed against, and nothing to weigh it against.
    func served(registry: RootsRegistry = .standard()) async throws -> LoggedLookup.Served {
        let (engine, note) = try rootOptions.makeEngine(probing: symbol, registry: registry, storesNothing: syntacticOnly)
        let options = WhereOptions(
            includeSemantic: !syntacticOnly, includeReferences: includeReferences || filesOnly, offset: offset, nameMatchedSiteCap: Self.nameMatchedSiteCap, filesOnly: filesOnly, declarationsOnly: declarationsOnly
        )
        if let revision {
            let text = try await engine.lookup(symbol: symbol, at: revision, options: options)
            return LoggedLookup.Served(text: Freshness.placing([note], under: text), root: engine.repoRoot.path)
        }
        let freshness = try await engine.ensureFresh()
        // No denominator: a symbol lookup stands in for a grep, not for a run of source, so it records what it
        // served and nothing it could not weigh — the same split the server records (``SiftCore/MeasuredAnswer``).
        let text = try await Freshness.placing([note], under: engine.lookup(symbol: symbol, freshness: freshness, options: options))
        return LoggedLookup.Served(text: text, root: engine.repoRoot.path)
    }
}
