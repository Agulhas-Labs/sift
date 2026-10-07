//
// Copyright © Agulhas Labs
//

import Foundation

/// Runs a `StructuralQuery` across the repository's Swift files.
///
/// Reads the **working tree**, not the index, and so has no staleness axis at all: it parses what is on disk at the moment of the query. That is why the schema stores no bodies for this — storing them would buy nothing a re-parse doesn't already give, and would add an invalidation problem where there currently is none.
///
/// Affordable because parsing is the cheap part: tens of thousands of files parse in a second or two, so a whole-repo shape query costs a fraction of a second even on a large monorepo. Files are parsed in parallel and each tree is discarded as soon as its matches are collected.
struct StructuralSearch {
    let repoRoot: URL
    let enumerator: FileEnumerator

    /// Every declaration in the repo satisfying `query`, ordered by path then line, those a `name:` pattern matches whole ahead of the rest.
    ///
    /// An alternation of short words matches inside many longer names (`key` in every `CodingKeys`), so in path order the declarations a caller named would sit anywhere in the answer; putting whole matches first keeps every row and puts the named ones on the first page.
    func run(_ query: StructuralQuery) async -> Result {
        let candidates = enumerator.swiftFiles().filter(query.admitsPath)
        let (matches, eliminations) = await Self.scan(paths: candidates, repoRoot: repoRoot, query: query)
        let ordered = matches.sorted { ($0.path, $0.line) < ($1.path, $1.line) }
        let whole = ordered.filter { query.matchesNameWhole($0.qualifiedName) }
        return Result(
            matches: whole + ordered.filter { !query.matchesNameWhole($0.qualifiedName) },
            filesScanned: candidates.count,
            eliminations: eliminations,
            wholeNameMatches: whole.count
        )
    }

    private static func scan(paths: [String], repoRoot: URL, query: StructuralQuery) async -> (matches: [StructuralMatch], eliminations: [Int: Int]) {
        guard !paths.isEmpty else { return ([], [:]) }
        let cores = ProcessInfo.processInfo.activeProcessorCount
        let rootPath = repoRoot.path
        var collected: [StructuralMatch] = []
        var eliminations: [Int: Int] = [:]
        await withTaskGroup(of: (matches: [StructuralMatch], eliminations: [Int: Int]).self) { group in
            var iterator = paths.makeIterator()
            var inFlight = 0
            while inFlight < cores, let path = iterator.next() {
                group.addTask { matches(at: path, rootPath: rootPath, query: query) }
                inFlight += 1
            }
            for await found in group {
                collected.append(contentsOf: found.matches)
                eliminations.merge(found.eliminations, uniquingKeysWith: +)
                if let path = iterator.next() {
                    group.addTask { matches(at: path, rootPath: rootPath, query: query) }
                }
            }
        }
        return (collected, eliminations)
    }

    /// One file's matches and eliminations; an unreadable or non-UTF-8 file contributes none rather than failing the query.
    private static func matches(at path: String, rootPath: String, query: StructuralQuery) -> (matches: [StructuralMatch], eliminations: [Int: Int]) {
        guard let data = FileManager.default.contents(atPath: rootPath + "/" + path),
              let source = String(data: data, encoding: .utf8) else { return ([], [:]) }
        return StructuralMatcher.scan(source, path: path, query: query)
    }
}

extension StructuralSearch {
    /// The matches plus the denominator they were drawn from — a count of zero means something different against 12 files than against 7,000.
    struct Result {
        let matches: [StructuralMatch]
        let filesScanned: Int
        /// For each position in the query's applied order, how many declarations that term was the first to reject; empty where no declaration reached the terms.
        var eliminations: [Int: Int] = [:]
        /// How many of the leading matches a `name:` pattern matched whole; the rest it matched only in part.
        var wholeNameMatches = 0
    }
}
