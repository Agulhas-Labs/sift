//
// Copyright © Agulhas Labs
//

import SiftCore
import SiftMCP

extension PreToolUseCommand.Lookup {
    /// The path this lookup names outright — `searchPath` first, then `readPath` — or `nil` where it names neither and the working directory is all there is to anchor it on.
    var anchor: String? {
        searchPath ?? readPath
    }

    /// Every file this lookup reads, whole or through a line window — a `Read`, or a shell command whose every lookup is a read (`cat`, `cat -n`, `sed -n '1,200p'`, several of them) — spelled out against `directory`; empty for any other lookup.
    func readPaths(from directory: String?) -> [String] {
        if let readPath {
            return [SwiftTree.resolve(readPath: readPath, relativeTo: directory) ?? readPath]
        }
        guard let inPlace else {
            return windowPaths.map { SwiftTree.resolve(readPath: $0, relativeTo: directory) ?? $0 }
        }
        let paths = inPlace.calls.compactMap(\.readPath)
        guard paths.count == inPlace.calls.count else { return [] }
        return paths.map { SwiftTree.resolve(readPath: $0, relativeTo: inPlace.directory) ?? $0 }
    }

    /// The keys an answer given for `match` is recorded under: those of every statement its calls answered (``SiftMCP/InPlaceShape/Match/statements``), or `key` alone where it answered no shell statement.
    ///
    /// A lookup the answer dropped is not among them, even where it is `key` itself: its re-run is not the identical re-run of anything served.
    func keys(answeredBy match: InPlaceShape.Match) -> [String] {
        let keys = ServedReading.keys(answeredBy: match, among: statementKeys)
        return keys.isEmpty ? [key] : keys
    }
}
