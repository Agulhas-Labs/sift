//
// Copyright © Agulhas Labs
//

import Foundation
import SiftCore

/// Engines the in-place answerer keeps open per repository root, for the length of a scope that binds it and answers from the same few roots over and over.
///
/// Unbound — the live hook — every answer opens an engine of its own, as it always has: a hook is one process per call. A replay of a week of transcripts answers tens of thousands of calls inside one process, and opening an engine costs more than most answers do (two `git` spawns, the module resolver's walk of the build files); bound, an engine is opened once per root and handed back to each answer after it. What must not outlive a change is re-checked on every answer by the engine itself: each answer still brings it up to date (``SiftEngine/ensureFresh()``), which reads the head and the dirty files afresh, as the long-lived MCP server's engine does on every query. What the engine holds of the index store is let go each time it is handed out (``SiftEngine/openSemanticStoresAfresh()``), since a live hook's answer always opens the store from nothing: a store still warming when one answer gave up on it reads as warming to the next too, and a failed open is tried again, rather than a replay answering warmer than the hook would have.
///
/// An engine is handed to one answer at a time: one still out — an answer abandoned past its time budget and still running — is never handed to a second, which opens one of its own instead. An engine whose database file went is dropped rather than handed out again, and past ``capacity`` idle engines the one used longest ago is closed.
///
/// Bound as a task-local, so it reaches only the code running inside the scope that bound it; work the scope hands to a detached task has to carry it across itself.
public final class EngineReuse: @unchecked Sendable {
    /// The reuse bound for the current scope, or `nil` where every answer opens its own engine.
    @TaskLocal public static var current: EngineReuse?

    /// The most idle engines kept open at once, so a replay across many worktrees holds a bounded number of databases and file descriptors.
    public let capacity: Int
    private let open: @Sendable (String) throws -> SiftEngine
    private let lock = NSLock()
    /// The engines no answer holds, the one used most recently last.
    private var idle: [(root: String, engine: SiftEngine)] = []
    private var openedCount = 0

    /// A reuse that opens an engine on a root with `open` the first time the root is asked for, or whenever its engine is out.
    public init(capacity: Int = 16, open: @escaping @Sendable (String) throws -> SiftEngine = { try SiftEngine(directory: URL(fileURLWithPath: $0), registry: nil) }) {
        self.capacity = capacity
        self.open = open
    }

    /// How many engines this reuse has opened in all.
    public var opened: Int {
        lock.withLock { openedCount }
    }

    /// An engine on `root` for one answer to hold until it hands it back with ``checkIn(_:root:)``: the idle one kept for the root, or one opened now.
    public func checkOut(root: String) throws -> SiftEngine {
        let kept = lock.withLock { () -> SiftEngine? in
            guard let index = idle.lastIndex(where: { $0.root == root }) else { return nil }
            return idle.remove(at: index).engine
        }
        if let kept, kept.isUsable {
            kept.openSemanticStoresAfresh()
            return kept
        }
        let engine = try open(root)
        lock.withLock { openedCount += 1 }
        return engine
    }

    /// Hands `engine` back for the next answer on `root`, unless its database file went while it was out.
    public func checkIn(_ engine: SiftEngine, root: String) {
        guard engine.isUsable else { return }
        lock.withLock {
            idle.append((root, engine))
            if idle.count > capacity {
                idle.removeFirst()
            }
        }
    }

    /// An engine on `root`: out of the bound reuse where one is bound, and opened for this answer alone where none is.
    static func engine(on root: String) throws -> SiftEngine {
        if let reuse = current {
            return try reuse.checkOut(root: root)
        }
        return try SiftEngine(directory: URL(fileURLWithPath: root), registry: nil)
    }

    /// An engine on `root` for an answer that brings it up to date, as ``engine(on:)`` gives one, or `nil` where the tree cannot be written: its index would be held in memory and built from a parse of the whole tree by every engine opened on it, which a hook call, a process of its own, would pay every time (``SiftEngine/wouldKeepIndexInMemory(root:)``).
    ///
    /// `nil` with a reuse bound too, so a replay withholds what the hook would.
    static func freshenable(on root: String) throws -> SiftEngine? {
        SiftEngine.wouldKeepIndexInMemory(root: URL(fileURLWithPath: root)) ? nil : try engine(on: root)
    }

    /// Hands `engine` back to the bound reuse, where one is bound; unbound, the engine closes with its answer.
    static func release(_ engine: SiftEngine, root: String) {
        current?.checkIn(engine, root: root)
    }
}
