//
// Copyright © Agulhas Labs
//

import Foundation

/// The line after `where`'s `no declarations found` when the queried name is the basename of indexed Swift files: a name with no declaration is often a file of extensions, so the answer names the file and the next call.
struct WhereBasenamePointer {
    /// The paths named before the rest are counted.
    private static let pathCap = 3

    static func lines(for query: String, in store: IndexStore) throws -> [String] {
        guard !query.isEmpty, !query.contains("/") else {
            return []
        }
        let suffix = "/\(query).swift"
        let paths = try store.fileInventory().keys
            .filter { ("/" + $0).hasSuffix(suffix) }
            .sorted()
        guard !paths.isEmpty else {
            return []
        }
        let shown = paths.prefix(pathCap).map { "digest \($0)" }.joined(separator: ", ")
        let more = paths.count > pathCap ? ", and \(paths.count - pathCap) more" : ""
        let lead = paths.count == 1 ? "a file has that name" : "\(paths.count) files have that name"
        return ["no declaration named \(query); \(lead): \(shown)\(more)"]
    }
}
