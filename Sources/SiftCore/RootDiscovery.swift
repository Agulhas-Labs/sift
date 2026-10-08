//
// Copyright © Agulhas Labs
//

import Foundation

/// Repository roots discovered once per directory, for the length of a scope that binds it and asks the same directories over and over.
///
/// Unbound — the lookup hook, the MCP server, every command — ``GitContext/discoverRoot(from:)`` spawns `git rev-parse --show-toplevel` for every question, as it always has: a server outlives the checkouts it answers for, so it may not keep an answer past the question. A replay of a week of transcripts asks the same few directories tens of thousands of times inside one process whose directories do not move while it runs, and binds one of these for its life so each is asked of git once. The stop hook binds one for its one-second judgement, which can ask an edited directory twice: once reading the transcript at a green run, once placing the edits in their repositories.
///
/// Bound as a task-local, so it reaches only the code running inside the scope that bound it, never another task of the same process. Work the scope hands to a detached task has to carry it across itself.
public final class RootDiscovery: @unchecked Sendable {
    /// The discovery bound for the current scope, or `nil` where every question spawns its own `git`.
    @TaskLocal public static var current: RootDiscovery?

    private let discover: @Sendable (URL) -> URL?
    private let lock = NSLock()
    private var remembered: [String: URL?] = [:]

    /// A discovery that asks `discover` about each directory the first time it is asked, and remembers the answer — a missing root as much as a found one.
    public init(discover: @escaping @Sendable (URL) -> URL? = GitContext.spawnedRoot(from:)) {
        self.discover = discover
    }

    /// The root enclosing `directory`, asked of `discover` only the first time this directory is asked.
    public func root(from directory: URL) -> URL? {
        let key = directory.path
        if let known = lock.withLock({ remembered[key] }) {
            return known
        }
        let found = discover(directory)
        lock.withLock { remembered[key] = found }
        return found
    }
}
