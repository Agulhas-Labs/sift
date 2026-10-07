//
// Copyright © Agulhas Labs
//

import ArgumentParser
import Foundation
import SiftCore

/// The shared `--root` option: explicit override, else the repository enclosing the working directory.
struct RootOptions: ParsableArguments {
    @Option(name: .customLong("root"), help: "Repository root (defaults to the repo enclosing the current directory).")
    var root: String?

    var directory: URL {
        if let root {
            return URL(fileURLWithPath: root)
        }
        return URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    }

    /// The engine every command opens: registry-wired, so each opened root is recorded for cross-root answers.
    ///
    /// `probing` is the query's target, which lets a session rooted above every repo resolve to the one that declares it rather than failing (see `RootResolver`). Commands whose argument names no symbol — and those with no argument at all — pass nothing and keep the plain "not a git repository" error.
    ///
    /// `registry` is the per-user one everywhere but a test, which needs a registry it owns: resolving an adopted root is only exercisable against roots the test put there, and the standard one would record every temporary repository the suite makes.
    func makeEngine(probing target: String? = nil, registry: RootsRegistry = .standard(), storesNothing: Bool = false) throws -> (engine: SiftEngine, note: String?) {
        let resolved = try RootResolver.resolve(directory: directory, registry: registry, probing: target, namedExplicitly: root != nil)
        return try (SiftEngine(resolved: resolved, registry: registry, storesNothing: storesNothing), resolved.note)
    }
}
