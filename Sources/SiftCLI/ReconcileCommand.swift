//
// Copyright © Agulhas Labs
//

import ArgumentParser
import SiftCore

/// `sift reconcile` — walk the tree and converge the index regardless of what other paths missed.
struct ReconcileCommand: AsyncParsableCommand {
    static var configuration: CommandConfiguration {
        CommandConfiguration(commandName: "reconcile", abstract: "Diff the index against the working tree and fix every divergence.")
    }

    @OptionGroup var rootOptions: RootOptions

    func run() async throws {
        try await run(registry: .standard())
    }

    /// The command against `registry`, which a test owns; refused where the tree cannot be written, since an index reconciled in memory would be thrown away.
    func run(registry: RootsRegistry) async throws {
        let (engine, note) = try rootOptions.makeEngine(registry: registry)
        try engine.requireStoredIndex()
        // Emitted before the work, not after: this one rewrites an index, so which repository it picked is the first thing to say.
        if let note {
            StandardStreams.emit(note)
        }
        let result = try await engine.reconcile()
        let freshness = try await engine.ensureFresh()
        StandardStreams.emit(freshness.headerLine)
        StandardStreams.emit("reconcile: removed \(result.removed), reindexed \(result.reindexed)")
    }
}
