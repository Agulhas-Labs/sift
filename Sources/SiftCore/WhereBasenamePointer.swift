//
// Copyright © Agulhas Labs
//

import Foundation

/// The line every answer of `where` and `digest` that finds no declaration of the name carries when the name is the basename of indexed Swift files: a name with no declaration is often a file of extensions, so the answer names the file and the next call.
struct WhereBasenamePointer {
    /// The paths named before the rest are counted.
    private static let pathCap = 3

    static func lines(for query: String, in store: IndexStore, at revision: Revision? = nil, spelling: CallSpelling = .commandLine) throws -> [String] {
        guard !query.isEmpty, !query.contains("/") else {
            return []
        }
        // A name the index declares as anything (a typealias, a function, a case) is not declared nowhere.
        guard try store.symbols(named: query).isEmpty else {
            return []
        }
        let suffix = "/\(query).swift"
        let population = try revision?.paths ?? Array(store.fileInventory().keys)
        let paths = population
            .filter { ("/" + $0).hasSuffix(suffix) }
            .sorted()
        guard !paths.isEmpty else {
            return []
        }
        let shown = paths.prefix(pathCap).map { path in revision.map { spelling.digest(path, at: $0.name) } ?? "digest \(path)" }.joined(separator: ", ")
        let more = paths.count > pathCap ? ", and \(paths.count - pathCap) more" : ""
        let lead = paths.count == 1 ? "a file has that name" : "\(paths.count) files have that name"
        return ["no declaration named \(query); \(lead): \(shown)\(more)"]
    }
}

extension WhereBasenamePointer {
    /// A past revision's Swift files: the revision as the query wrote it, and the repo-relative paths git lists there.
    struct Revision {
        let name: String
        let paths: [String]
    }
}
