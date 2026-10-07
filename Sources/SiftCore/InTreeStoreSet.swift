//
// Copyright © Agulhas Labs
//

import Foundation

/// The in-tree stores one engine reads for `where`: the walk that found them and each store's open, kept across queries and let go as soon as discovery stops naming them.
///
/// Only `where` asks for these, so nothing `affected`, `diff`, `status` or the deletion ledger reads depends on them.
final class InTreeStoreSet: @unchecked Sendable {
    /// The last walk of the ignored directories, reused while it still holds.
    private var walk: InTreeStoreWalk?
    /// The stores the last query opened, by cache directory, each reused while discovery still names it and no newer unit has landed.
    private var opened: [String: SemanticStore] = [:]
    /// One open at a time per store, by cache directory, so a store warming past one query's budget is waited on by the next rather than opened twice.
    private var openers: [String: BudgetedOpen<SemanticStore>] = [:]
    /// How many times this set has walked the tree, for a test that a walk is reused while it holds.
    private(set) var walks = 0

    /// How many opens this set is holding, for a test that a store gone from discovery is let go.
    var openerCount: Int {
        openers.count
    }

    /// Whether the last walk hit its cap with directories still unvisited — a store beyond where it stopped may exist, and the `where` mode line says so rather than pointing at a build that already happened.
    var walkTruncated: Bool {
        walk?.truncated ?? false
    }

    /// The in-tree stores discovery names now, walking the tree again only when the last walk no longer holds.
    func discover(_ discovery: IndexStoreDiscovery) -> [DiscoveredStore] {
        let found = discovery.discoverInTree(excluding: nil, reusing: walk)
        if let fresh = found.walk, fresh !== walk {
            walks += 1
        }
        walk = found.walk
        return found.stores
    }

    /// Opens each of `stores` within `budget` by the primary's rules — a cache of its own, reopened when discovery names another cache or a newer unit lands — and lets go of every open and opener discovery no longer names.
    func open(_ stores: [DiscoveredStore], repoRoot: URL, budget: TimeInterval) -> InTreeOpenings {
        let started = Date()
        var openings = InTreeOpenings()
        var kept: [String: SemanticStore] = [:]
        var named: Set<String> = []
        for discovered in stores {
            guard let cache = SemanticCache(store: discovered.path, in: SiftPaths.cache(in: repoRoot)) else { continue }
            let key = cache.directory.path
            named.insert(key)
            let anchor = IndexStoreDiscovery.newestUnitDate(in: discovered.path) ?? .distantPast
            if let reused = opened[key], reused.cache == cache, reused.newestUnitDate >= anchor {
                openings.opened.append(reused)
                kept[key] = reused
                continue
            }
            let opener = openers[key] ?? BudgetedOpen<SemanticStore>()
            openers[key] = opener
            let outcome = opener.open(key: BudgetedOpen<SemanticStore>.Key(path: key, anchor: anchor), budget: max(0, budget - Date().timeIntervalSince(started))) {
                try SemanticStore(discovered: discovered, newestUnitDate: anchor, cache: cache)
            }
            switch outcome {
            case let .opened(store):
                openings.opened.append(store)
                kept[key] = store
            case let .warming(seconds):
                openings.warmingNote = openings.warmingNote ?? SiftEngine.warmingNote(provenance: discovered.provenance, seconds: seconds)
                openings.pending.append("in-tree store \(discovered.provenance.name) still warming — \(Int(seconds.rounded()))s so far")
            case let .failed(error):
                openings.pending.append("in-tree store \(discovered.provenance.name) failed to open: \(SemanticOpenFailure.cause(of: error))")
            }
        }
        opened = kept
        // An open is keyed by its store's cache, which names the units directory's identity, so every rebuild of a store is a new key: one discovery no longer names is never asked for again.
        openers = openers.filter { named.contains($0.key) }
        return openings
    }
}

extension SemanticContext {
    /// This context with the in-tree stores that opened joined behind its own, and the ones that did not named.
    func joining(_ openings: InTreeOpenings) -> SemanticContext {
        var context = self
        context.inTreeStores = openings.opened
        context.pendingInTree = openings.pending
        context.inTreeWarming = openings.warmingNote != nil
        return context
    }
}
