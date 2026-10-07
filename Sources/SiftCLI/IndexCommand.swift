//
// Copyright © Agulhas Labs
//

import ArgumentParser
import SiftCore

/// `sift index` — build or refresh the index (full with `--full`, else incremental).
struct IndexCommand: AsyncParsableCommand {
    static var configuration: CommandConfiguration {
        CommandConfiguration(commandName: "index", abstract: "Build or incrementally refresh the repository's index.")
    }

    @Flag(help: "Rebuild from scratch instead of refreshing incrementally.")
    var full = false

    @OptionGroup var rootOptions: RootOptions

    func run() async throws {
        try await run(registry: .standard())
    }

    /// The command against `registry`, which a test owns; refused where the tree cannot be written, since an index built in memory would be thrown away.
    func run(registry: RootsRegistry) async throws {
        let (engine, note) = try rootOptions.makeEngine(registry: registry)
        try engine.requireStoredIndex()
        // Emitted before the work, not after: this one writes an index, so which repository it picked is the first thing to say.
        if let note {
            StandardStreams.emit(note)
        }
        if full {
            let count = try await engine.fullIndex()
            let freshness = try await engine.ensureFresh()
            StandardStreams.emit(freshness.headerLine)
            StandardStreams.emit("indexed \(count) files (full rebuild)")
        } else {
            let freshness = try await engine.ensureFresh()
            StandardStreams.emit(freshness.headerLine)
            StandardStreams.emit("index up to date")
        }
    }
}
