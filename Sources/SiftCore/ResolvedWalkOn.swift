//
// Copyright © Agulhas Labs
//

import Foundation

/// The resolved walk past its bound, for a changed file none of whose declarations reached a test within it.
///
/// A file deep in a pipeline reaches its first test many hops out, so at the default depth it would list nothing. Each such file is walked on, one hop at a time, until the first hop that reaches a test function (a suite's helper names its suite and is followed on, not stopped at), and the answer names the file and that hop. Every other file keeps the bound, since walking all of them on would reach most of a suite.
struct ResolvedWalkOn {
    /// The bounded walk's expansions, by declaration, extended by the walk-on's own.
    var hits: [Int64: [Hit]]

    /// Expands a declaration the bounded walk never reached, or `nil` where the store cannot answer for it — a file written since the build, a declaration with no USR.
    let expand: (SymbolRow) throws -> [Hit]?
}

extension ResolvedWalkOn {
    /// One reference the store recorded to an expanded declaration: the declaration it landed in, the test that declaration is or sits in, and whether the walk follows it on.
    struct Hit {
        let enclosing: SymbolRow
        let test: TestDeclaration?
        let state: OccurrenceState
        let leadsOn: Bool

        /// Whether the hit lands in a test function, which is where the walk-on ends.
        ///
        /// A suite's helper names its suite and is followed on, so it is a route to a test, not an arrival at one.
        var arrives: Bool {
            test?.symbol.function != nil
        }
    }

    /// A test the walk-on reached, and the hop it reached it at.
    struct Reached {
        let test: TestDeclaration
        let hop: Int
        let state: OccurrenceState
    }

    /// What the walk-on did for one changed file: the hop it reached its first test at, or `nil` where it reached none or the cap stopped it.
    struct Outcome {
        let path: String
        let hop: Int?
        let capped: Bool
        /// The last hop the walk completed for this file, which is where it stopped when it reached no test or the cap spent its room.
        let through: Int

        var described: String {
            if let hop {
                return "\(path) at \(hop) hops"
            }
            return capped ? "\(path) not walked: cap (expansion cap spent after \(through) hops)" : "\(path) reached none (walked \(through) hops)"
        }
    }

    /// Everything the walk-on found, and whether the expansion cap stopped it.
    struct Result {
        var reached: [Reached] = []
        var outcomes: [Outcome] = []
        var capped = false

        /// The furthest hop any file was walked to, or `nil` where none was walked on.
        var furthest: Int? {
            outcomes.map(\.through).max()
        }

        /// What the walk-on says when the expansion cap stopped it, or `nil` where it did not: the bounded walk ahead of it was complete, and the files it names were not followed on.
        func capNote(cap: Int) -> String? {
            capped ? "note: the walk-on past the bound spent the \(cap)-declaration expansion cap before it finished (the bounded walk itself was complete); the files marked `not walked: cap` above were not followed on" : nil
        }

        /// The note naming each file walked on and how far, or `nil` where none was.
        func note(depth: Int) -> String? {
            guard !outcomes.isEmpty else { return nil }
            let count = outcomes.count
            let each = outcomes.map(\.described).joined(separator: ", ")
            return "note: \(count) changed file\(count == 1 ? "" : "s") reached no test within \(depth) hop\(depth == 1 ? "" : "s"), so the resolved walk went on from \(count == 1 ? "it" : "each") to the first hop that reaches one: \(each)"
        }
    }

    /// Walks on from each file in `files` that reached no test within `depth` hops, spending at most `budget` new expansions across all of them.
    mutating func run(from files: [String: [SymbolRow]], depth: Int, budget: inout Int) throws -> Result {
        var result = Result()
        // A file the cap reaches is given its outcome and the walk goes on to the next: one still answered from the expansions already held keeps its own, and the rest are counted as not walked rather than left out of the note.
        files: for (path, roots) in files.sorted(by: { $0.key < $1.key }) {
            guard let (start, within) = beyond(roots, depth: depth), !start.isEmpty else { continue }
            var seen = within
            var frontier = start
            var hop = depth + 1
            var reachedAt: Int?
            while !frontier.isEmpty, reachedAt == nil {
                var next: [SymbolRow] = []
                for row in frontier where seen.insert(row.id).inserted {
                    guard let rowHits = try hits(of: row, budget: &budget) else {
                        result.capped = true
                        result.outcomes.append(Outcome(path: path, hop: nil, capped: true, through: hop - 1))
                        continue files
                    }
                    for hit in rowHits {
                        if let test = hit.test {
                            result.reached.append(Reached(test: test, hop: hop, state: hit.state))
                            if hit.arrives {
                                reachedAt = hop
                            }
                        }
                        if hit.leadsOn {
                            next.append(hit.enclosing)
                        }
                    }
                }
                frontier = next
                hop += 1
            }
            result.outcomes.append(Outcome(path: path, hop: reachedAt, capped: false, through: hop - 1))
        }
        return result
    }
}

private extension ResolvedWalkOn {
    /// The declarations one hop past the bound from `roots`, with every declaration within it, or `nil` where a test lies within it.
    ///
    /// Read from the bounded walk's expansions alone: that walk expands every declaration at the first hop any root reaches it, so each declaration within `depth` hops of these roots has been expanded, unless the store could not answer for it.
    func beyond(_ roots: [SymbolRow], depth: Int) -> (start: [SymbolRow], within: Set<Int64>)? {
        var within: Set<Int64> = []
        var layer = roots
        for _ in 1 ... depth {
            var next: [SymbolRow] = []
            for row in layer where within.insert(row.id).inserted {
                guard let rowHits = hits[row.id] else { continue }
                guard !rowHits.contains(where: { $0.test != nil }) else { return nil }
                next.append(contentsOf: rowHits.filter(\.leadsOn).map(\.enclosing))
            }
            layer = next
        }
        return (layer.filter { !within.contains($0.id) }, within)
    }

    /// One declaration's hits, expanding it where the bounded walk did not; none where the store cannot answer for it, and `nil` where the budget is spent.
    mutating func hits(of row: SymbolRow, budget: inout Int) throws -> [Hit]? {
        if let cached = hits[row.id] {
            return cached
        }
        guard budget > 0 else { return nil }
        budget -= 1
        let expanded = try expand(row) ?? []
        hits[row.id] = expanded
        return expanded
    }
}
