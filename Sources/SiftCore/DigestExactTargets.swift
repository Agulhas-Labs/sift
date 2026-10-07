//
// Copyright © Agulhas Labs
//

import Foundation

/// The targets an ambiguity list suggests, one per candidate: wraps `DigestRenderer` rather than extending it, to keep `DigestRenderer.swift` under the line-length guideline.
struct DigestExactTargets {
    let renderer: DigestRenderer

    /// The target each candidate is suggested under, in order: its qualified name, or its file range where another candidate shares that name, so that every suggested target answers rather than repeating the ambiguity.
    func of(_ rows: [SymbolRow]) throws -> [String] {
        let qualified = try rows.map(renderer.qualifiedTarget(of:))
        let shared = Dictionary(grouping: qualified, by: { $0 }).filter { $1.count > 1 }.keys
        return zip(rows, qualified).map { row, name in
            shared.contains(name) ? "\(row.path)\(row.rangeDescription)" : name
        }
    }
}
