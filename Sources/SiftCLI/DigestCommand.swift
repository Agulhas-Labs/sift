//
// Copyright © Agulhas Labs
//

import ArgumentParser
import SiftCore

/// `sift digest` — a type's, file's, or module's declaration surface at a fraction of its file cost.
struct DigestCommand: AsyncParsableCommand {
    static var configuration: CommandConfiguration {
        CommandConfiguration(
            commandName: "digest",
            abstract: "Print the declaration surface of a type, file, or module — one member's source, or a .md file's heading outline."
        )
    }

    @Argument(help: "A type (Type, Module.Type, Outer.Nested), a member (Type.member, or a labeled Type.save(_:to:)) to print its source, a file path, a module name, . for the repo overview, or a File.swift:12-40 line range. A .md path (exact, repo-relative or absolute under the root; a bare document name is not matched) answers with its heading outline and each section's line range, read live from disk — the locating step for a ranged read of a large doc. Each argument is one target, so a quoted path with spaces in it is one; several answer in this one call.")
    var targets: [String]

    @Flag(name: .customLong("all"), help: "Include private/fileprivate symbols in a module digest; type and file digests always show them.")
    var includeAll = false

    @Flag(name: [.customLong("signatures-only"), .customLong("signaturesOnly")], help: "Drop doc summaries and leading attributes.")
    var signaturesOnly = false

    @Option(help: "Skip this many member lines — declaration lines for a module, heading lines for a .md outline (pagination cursor from a truncated: marker).")
    var offset = 0

    @Option(name: .customLong("at"), help: "Answer as of this commit, branch or tag: a syntactic parse of that revision's files that name the target, read through git — never the index, and never the working tree.")
    var revision: String?

    @OptionGroup var rootOptions: RootOptions

    func run() async throws {
        // An answer as of another revision lists that revision's files, which locates nothing in today's.
        try await LoggedLookup.emit(tool: "digest", target: targets.first, targets: targets, in: rootOptions.directory, locates: revision == nil) {
            try await served()
        }
    }

    /// The whole answer, header first and any adopted-root note under it.
    func answer(registry: RootsRegistry = .standard()) async throws -> String {
        try await served(registry: registry).text
    }

    /// That answer with what the log records beside it: the repository it was computed against, and the source it stood in for.
    func served(registry: RootsRegistry = .standard()) async throws -> LoggedLookup.Served {
        let (engine, note) = try rootOptions.makeEngine(probing: targets.first, registry: registry)
        let options = DigestOptions(includeAllAccess: includeAll, signaturesOnly: signaturesOnly, offset: offset)
        if let revision {
            // Read from the revision's tree, so the index is neither brought up to date nor opened for it.
            let text = try engine.digest(targets: targets, at: revision, options: options)
            return LoggedLookup.Served(text: Freshness.placing([note], under: text), root: engine.repoRoot.path)
        }
        var freshness = try await engine.ensureFresh()
        // The measured form of the same call — identical text, and the denominator with it. `digest` is the one
        // query that has one, and it is settled here, before the framing, exactly as the server settles it.
        let digest = try engine.measuredDigest(targets: targets, options: options)
        freshness = freshness.noting(digest)
        let text = Freshness.placing([note], under: freshness.headerLine + "\n" + digest.text)
        return LoggedLookup.Served(text: text, root: engine.repoRoot.path, source: digest.bytes?.source, parts: digest.parts)
    }
}
