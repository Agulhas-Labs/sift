//
// Copyright © Agulhas Labs
//

import Foundation

/// The files a digest found stale while it read their source: reparsed from the live file, or left on their old rows because they could not be.
///
/// Kept by the engine between two freshness checks so a header framed after several digests names what any of them reparsed (``SiftEngine/framing(_:)``).
struct ServedReparses {
    private(set) var reparsed: Set<String> = []
    private(set) var unreparsed: Set<String> = []

    var isEmpty: Bool {
        reparsed.isEmpty && unreparsed.isEmpty
    }

    /// A file reparsed by a later digest is no longer one that could not be.
    mutating func record(reparsed paths: [String], unreparsed failed: [String]) {
        reparsed.formUnion(paths)
        unreparsed.subtract(paths)
        unreparsed.formUnion(failed.filter { !reparsed.contains($0) })
    }
}
