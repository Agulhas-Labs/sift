//
// Copyright © Agulhas Labs
//

/// The lines of a type's name-matched uses that write it in the inheritance clause of a conformer the conformers block lists, which a plain answer lists there rather than among the uses.
struct ConformanceUseLines {
    let store: IndexStore
    /// A repo-relative file's current text, or `nil` where it cannot be read.
    let fileSource: ((String) -> String?)?

    /// Per file, the lines of `used` that write `name` in the inheritance clause of a conformer the conformers block lists.
    ///
    /// A clause continued onto the next lines is read from the file's parse, and a line is a conformance only where every use on it, by `used`'s columns, is a head of those clauses: a line that also uses the type elsewhere stays a use. Where the file cannot be read, a conformer's declaration line stands for it. The block lists the first ``WhereRenderer/listCap`` conformers, so no more are counted.
    func lines(of name: String, among used: [String: [Int: Set<Int>]]) throws -> [String: Set<Int>] {
        var unread: [String: Set<Int>] = [:]
        var unreadable: Set<String> = []
        var heads: [String: [Int: Set<Int>]] = [:]
        var parsed: [String: [ConformanceHeads.Start: [String: Set<ConformanceHeads.Start>]]] = [:]
        for row in try store.conformers(of: name).prefix(WhereRenderer.listCap) {
            guard let lines = used[row.path] else { continue }
            if parsed[row.path] == nil {
                let source = fileSource?(row.path)
                parsed[row.path] = source.map(ConformanceHeads.declarations(in:)) ?? [:]
                if source == nil {
                    unreadable.insert(row.path)
                }
            }
            let clause = ConformanceHeads.starts(writing: name, in: row, of: parsed[row.path] ?? [:])
            if clause.isEmpty, unreadable.contains(row.path), lines[row.line] != nil {
                unread[row.path, default: []].insert(row.line)
            }
            for start in clause {
                heads[row.path, default: [:]][start.line, default: []].insert(start.column)
            }
        }
        var found = unread
        for (path, lines) in heads {
            for (line, columns) in lines where used[path]?[line]?.isSubset(of: columns) == true {
                found[path, default: []].insert(line)
            }
        }
        return found
    }
}
