//
// Copyright © Agulhas Labs
//

import Foundation

/// The sites an answer's store reads left out as recorded only by a build older than their file's last edit, and the one line that says so.
///
/// Counted per symbol asked and per store, so the same symbol noted by two readers of one answer is counted once, while one resolved by two stores is counted in each, a site both stores record once.
struct SetAsideSites: Sendable {
    /// The sites set aside, by the USR they are references to, then by the store that set them aside.
    fileprivate var byUSR: [String: [String: [Site: Int]]] = [:]
    /// The attribute sites of a property wrapper left out of its listing, per wrapper type and file, counted against the lines a stale build recorded in that file.
    fileprivate var wrapperFiles: Set<WrapperFile> = []

    var isEmpty: Bool {
        byUSR.isEmpty && wrapperFiles.isEmpty
    }

    /// Adds the sites the store `store` set aside for the symbol `usr`, `byLine` counting them per absolute file path and line.
    mutating func note(ofUSR usr: String, inStore store: String, _ byLine: [String: [Int: Int]], relativePath: (String) -> String) {
        var counts: [Site: Int] = [:]
        for (path, lines) in byLine {
            for (line, count) in lines {
                counts[Site(path: relativePath(path), line: line), default: 0] += count
            }
        }
        guard !counts.isEmpty else { return }
        byUSR[usr, default: [:]][store] = counts
    }

    /// Adds the attribute sites of one property wrapper, in the repo-relative file `path`, that the wrapper listing left out with no store recording the type there.
    ///
    /// `unexplained` holds their lines in the working tree and `setAside` the lines in `path` of the wrapper's references only a build older than the file's last edit records, at that build's lines: an edit above a site moves one from the other, so `line` counts the sites per file, never more than either set holds, and none in a file with no set-aside line.
    mutating func noteWrapperSites(path: String, unexplained: Set<Int>, setAside: Set<Int>) {
        guard !unexplained.isEmpty, !setAside.isEmpty else { return }
        wrapperFiles.insert(WrapperFile(path: path, unexplained: unexplained, setAside: setAside))
    }

    /// Adds what `other` noted, a symbol both noted in one store counted once.
    mutating func merge(_ other: SetAsideSites) {
        for (usr, stores) in other.byUSR {
            byUSR[usr, default: [:]].merge(stores) { current, _ in current }
        }
        wrapperFiles.formUnion(other.wrapperFiles)
    }

    /// The one line saying how many sites were set aside, or `nil` where none were: the three files with most of them are named, the rest as `+N more`.
    var line: String? {
        var sites: [Site: Int] = [:]
        for stores in byUSR.values {
            // One source site two stale stores both record is still one site: the larger of their counts.
            let symbol = stores.values.reduce(into: [Site: Int]()) { $0.merge($1, uniquingKeysWith: max) }
            sites.merge(symbol, uniquingKeysWith: +)
        }
        // A wrapper site stands as a line the stale build recorded: its own where it is still on that line, then the file's
        // other set-aside lines, one already counted for a symbol last, since that line may be another reference and
        // standing for a site there would leave the site uncounted.
        for file in wrapperFiles.sorted(by: { $0.order < $1.order }) {
            let exact = file.unexplained.intersection(file.setAside)
            let moved = file.setAside.subtracting(exact).map { Site(path: file.path, line: $0) }
                .sorted { (sites[$0] == nil ? 0 : 1, $0.line) < (sites[$1] == nil ? 0 : 1, $1.line) }
            for site in exact.map({ Site(path: file.path, line: $0) }) + moved.prefix(file.unexplained.count - exact.count) where sites[site] == nil {
                sites[site] = 1
            }
        }
        var setAside: [String: Int] = [:]
        for (site, count) in sites {
            setAside[site.path, default: 0] += count
        }
        guard !setAside.isEmpty else { return nil }
        let ranked = setAside.sorted { ($1.value, $0.key) < ($0.value, $1.key) }
        let total = setAside.values.reduce(0, +)
        let named = ranked.prefix(3).map { setAside.count == 1 ? $0.key : "\($0.key) (\($0.value))" }
        let rest = ranked.count > 3 ? ", +\(ranked.count - 3) more" : ""
        return "\(total) site\(total == 1 ? "" : "s") in \(named.joined(separator: ", "))\(rest) set aside: recorded only by a build older than the file's last edit (a configuration not rebuilt since — rebuild it to see them)"
    }
}

private extension SetAsideSites {
    /// A site, by repo-relative path and line.
    struct Site: Hashable, Sendable {
        let path: String
        let line: Int
    }

    /// The attribute sites of one property wrapper left out of its listing in one file, by their lines today and the lines a stale build recorded.
    struct WrapperFile: Hashable, Sendable {
        let path: String
        let unexplained: Set<Int>
        let setAside: Set<Int>

        /// A key that orders the files the same way on every run, since a set's order is not.
        var order: String {
            "\(path) \(unexplained.sorted()) \(setAside.sorted())"
        }
    }
}
