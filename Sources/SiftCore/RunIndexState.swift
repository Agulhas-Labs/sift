//
// Copyright © Agulhas Labs
//

import Foundation

/// One run's reading of this machine's indexes — which roots are registered, each root's store, and what each name question answered — taken the first time each is needed and kept for the rest of the run.
///
/// An audit asks ``AdvisableName`` the same questions across thousands of lookups while other sessions rebuild, delete and register indexes around it, so asking live would let one run count half its lookups against a store and half against its absence. The first question about a root opens one read-only connection to its store inside a read transaction (``ReadOnlyIndex/held(atRoot:)``), and every later question about that root goes through it: a store deleted, replaced or rebuilt mid-run is seen by the next run, never by the rest of this one. A root whose store could not be opened the first time is treated as having none for the whole run.
public final class RunIndexState: @unchecked Sendable {
    private let lock = NSLock()
    /// Guards `stores` and every query run on a connection in it, since one connection is not to be used from two threads at once.
    private let probes = NSLock()
    private let registry: () -> [String]
    private var registered: [String]?
    private var stores: [String: HeldStore] = [:]
    private var names: [String: Bool] = [:]
    private var members: [String: Bool] = [:]

    /// The registry a state made in the current scope reads, or `nil` where it reads the machine's own.
    ///
    /// Bound by a test so that a state made without a registry of its own sees no repositories rather than whatever this machine has registered. Read when the state is made, not when it first asks, so the scope that made it decides even where its questions come from another thread.
    @TaskLocal public static var scopedRegistry: (@Sendable () -> [String])?

    /// A state that reads the registered roots from `registry` the first time they are asked for; without one, from the registry bound for the current scope (``scopedRegistry``), else from `~/.sift/roots.json`.
    public init(registry: (() -> [String])? = nil) {
        self.registry = registry ?? Self.scopedRegistry ?? { RootsRegistry.standard().currentRoots() }
    }

    /// The roots registered on this machine, as they stood the first time this run asked.
    var registeredRoots: [String] {
        lock.withLock {
            if let registered {
                return registered
            }
            let roots = registry()
            registered = roots
            return roots
        }
    }

    /// Whether the store at `root` has completed a build, as it stood the first time this run asked about that root.
    func isUsable(_ root: String) -> Bool {
        probes.withLock { store(atRoot: root).isUsable }
    }

    /// `body`'s answer against the connection this run holds to `root`'s store: `false` where the run holds none, and `nil` where `body` could not read it.
    func probing(_ root: String, _ body: (SQLiteDatabase) -> Bool?) -> Bool? {
        probes.withLock { store(atRoot: root).database.map(body) ?? false }
    }

    /// Ends the run, releasing every connection it held.
    ///
    /// Nothing is asked after it: a question about a root would open that root's store afresh.
    public func close() {
        probes.withLock { stores = [:] }
    }

    /// A bare name's answer under `key`, computed by `answer` only the first time this run asks.
    func name(_ key: String, _ answer: () -> Bool) -> Bool {
        remembered(key, in: \.names, answer)
    }

    /// A member's answer under `key`, computed by `answer` only the first time this run asks.
    func member(_ key: String, _ answer: () -> Bool) -> Bool {
        remembered(key, in: \.members, answer)
    }

    /// The store held for `root`, opened the first time it is asked for; the caller holds `probes`.
    private func store(atRoot root: String) -> HeldStore {
        if let held = stores[root] {
            return held
        }
        let database = ReadOnlyIndex.held(atRoot: root)
        let held = HeldStore(database: database, isUsable: database.map(ReadOnlyIndex.isUsable) ?? false)
        stores[root] = held
        return held
    }

    /// The value kept under `key` in `table`, or `answer`'s, kept there, where none is yet.
    ///
    /// The answer is computed outside the lock, since it may ask this state about a root in turn; two callers racing on one key both compute it and the first kept stands.
    private func remembered(_ key: String, in table: ReferenceWritableKeyPath<RunIndexState, [String: Bool]>, _ answer: () -> Bool) -> Bool {
        if let known = lock.withLock({ self[keyPath: table][key] }) {
            return known
        }
        let value = answer()
        return lock.withLock {
            if let known = self[keyPath: table][key] {
                return known
            }
            self[keyPath: table][key] = value
            return value
        }
    }
}

private extension RunIndexState {
    /// One root's store as a run holds it: the connection, if the store could be opened at all, and whether it had completed a build.
    struct HeldStore {
        let database: SQLiteDatabase?
        let isUsable: Bool
    }
}
