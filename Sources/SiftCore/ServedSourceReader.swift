//
// Copyright © Agulhas Labs
//

import CryptoKit
import Foundation

/// Reads the source a digest serves as it stands on disk, and notes each file whose bytes are not the ones its stored row was parsed from.
///
/// A digest that serves source pairs live bytes with what the row recorded: the heading, the line range it slices, the outline the passthrough was weighed against. The query path re-checks every file git names, which leaves out a file git is told to overlook (`--assume-unchanged`, `--skip-worktree`) and one written after the query's `git status`, and for those the answer would show new bytes under an old row. The check costs no read of its own: it hashes the bytes the answer read anyway and compares them with the row's `content_hash`, the same hash over the same raw bytes the parser records. A file with no row is never named, and a reader made without a store checks nothing.
final class ServedSourceReader {
    private let store: IndexStore?

    /// The files read whose bytes differ from their row, for the engine to reparse before rendering again.
    private(set) var stalePaths: Set<String> = []

    init(checkingAgainst store: IndexStore? = nil) {
        self.store = store
    }

    /// The file at `path` as UTF-8 text, or `nil` when it cannot be read or decoded.
    func text(of path: String, under repoRoot: URL) -> String? {
        guard let data = try? Data(contentsOf: repoRoot.appendingPathComponent(path)) else { return nil }
        if let store, let row = try? store.fileRow(path: path), row.contentHash != Self.contentHash(of: data) {
            stalePaths.insert(path)
        }
        return String(data: data, encoding: .utf8)
    }

    /// The hash a row records for `data`, as `FileParser` writes it.
    static func contentHash(of data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
