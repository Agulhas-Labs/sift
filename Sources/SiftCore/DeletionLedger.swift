//
// Copyright © Agulhas Labs
//

import Foundation

/// The files this index dropped because they left the tree, and the moment each drop happened — the one record of a deletion that outlives the rows it took with it.
///
/// `status` judges its semantic axis without opening the index store (Docs/Design.md §2), so the store's own list of what it compiled is out of its reach, and the syntactic index cannot stand in for it: every path that notices a deletion drops the file's rows before any report reads them, so by the time `status` looks, the file is gone from the disk and from the index alike. A query still sees it, because the store still cites it. This keeps what the drop would otherwise erase, in the index's own `meta` table, where holding it needs no schema change.
///
/// The moment recorded is when the index *noticed*, which is never earlier than the deletion itself. So a deletion noticed after a build was either made after it — the store still holds that file — or made before it and noticed late; counting both over-warns in the second case and never misses the first, the direction every staleness judgment here errs in.
struct DeletionLedger: Equatable {
    /// The `meta` key the ledger is kept under.
    static var metaKey: String {
        "deleted_files"
    }

    /// How many drops are remembered, the most recent kept.
    ///
    /// One entry per path, so repeated deletions of one file never grow it; the bound is for a tree that loses thousands of distinct files at once, where a report's count past it is a count of the most recent — and a report that big has already said everything a count can say.
    static let capacity = 2000

    /// Repository-relative path → the epoch second the index dropped it.
    private(set) var entries: [String: Double]

    /// Reads a stored ledger; anything unreadable is an empty one, since a count this only ever raises is the safe thing to lose.
    init(metaValue: String?) {
        guard let data = metaValue?.data(using: .utf8),
              let decoded = try? JSONDecoder().decode([String: Double].self, from: data)
        else {
            entries = [:]
            return
        }
        entries = decoded
    }

    /// The ledger as it is stored — sorted keys, so an unchanged ledger is byte-identical.
    var metaValue: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        guard let data = try? encoder.encode(entries), let text = String(bytes: data, encoding: .utf8) else { return "{}" }
        return text
    }

    /// Records `paths` as dropped at `instant`, keeping only the ``capacity`` most recent entries.
    mutating func record(_ paths: [String], at instant: Double) {
        for path in paths {
            entries[path] = instant
        }
        guard entries.count > Self.capacity else { return }
        let kept = entries.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }.prefix(Self.capacity)
        entries = Dictionary(uniqueKeysWithValues: kept.map { ($0.key, $0.value) })
    }

    /// The paths dropped after `anchor`, sorted — a build anchor, so these are the files a store built before them may still cite.
    func paths(droppedAfter anchor: Double) -> [String] {
        entries.filter { $0.value > anchor }.keys.sorted()
    }
}
