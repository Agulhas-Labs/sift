//
// Copyright © Agulhas Labs
//

import ArgumentParser
import SiftCore

/// `sift init` — inspect a repository's layout and propose the config it needs.
struct InitCommand: AsyncParsableCommand {
    static var configuration: CommandConfiguration {
        CommandConfiguration(
            commandName: "init",
            abstract: "Inspect the repo layout and propose .sift.json.",
            discussion: """
            Reports which files get their module from a real build file (SwiftPM manifests, XcodeGen \
            specs under any file name, .xcodeproj targets) and which fall back to a guess from the \
            directory name. You should rarely need this: all three are discovered automatically and an \
            upgraded binary re-attributes an existing index on its own. The fallback is the \
            thing worth knowing: those files still answer, they just answer about a module that does \
            not exist — every answer drawn from one carries a `⚠ module guessed` banner, and \
            `sift status` lists them all.

            Prints only, unless you pass --write. An existing .sift.json is never overwritten \
            without --force, and even then existing values are kept — only missing keys are added, so \
            anything you maintain by hand survives.
            """
        )
    }

    @Flag(help: "Write .sift.json instead of only printing the proposal.")
    var write = false

    @Flag(help: "Merge into an existing .sift.json (existing values are kept).")
    var force = false

    @OptionGroup var rootOptions: RootOptions

    func run() async throws {
        let (engine, note) = try rootOptions.makeEngine()
        try StandardStreams.emit(([note, engine.initializeConfig(write: write || force, force: force)].compactMap(\.self)).joined(separator: "\n"))
    }
}
