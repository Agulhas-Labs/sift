//
// Copyright © Agulhas Labs
//

import Foundation

/// The line `sift run` adds under a refused `--filter` that names a type or function the index declares: the test suites that reference it, so the next command is one the reader does not have to find.
///
/// A `--filter` names a test suite or a module, not the source type a change touched, and the refusal alone leaves the reader to find the suites by hand. The line is a note: it never changes the refusal, its first line or the exit code, and it is left out wherever it cannot be made cheaply and honestly.
public struct UnmatchedFilterHint: Sendable, Equatable {
    /// The identifier the filter spelled, which the index declares.
    let name: String
    /// The files that declare it, sorted.
    let declaredIn: [String]
    /// The suites that reach it, nearest first, each spelled as `--filter` takes it.
    let suites: [String]
    /// How many of ``suites``, from the front, name it themselves; the rest reach it through other code, as far out as `affected`'s walk goes.
    var direct = 0

    /// How many suites the line names before it counts the rest.
    static let listedSuites = 5

    /// The most filters one answer adds a line for.
    static let listedFilters = 3

    /// How long finding the suites may take before the line is left out rather than waited on.
    public static let lookupBudget: TimeInterval = 2

    /// The line, indented as the answer's other notes are, or `nil` where no suite reaches the name.
    ///
    /// A suite is said to reference the name only where it names it itself: one reached through other code exercises it without naming it, and calling that a reference would send the reader looking for a mention that is not there.
    var line: String? {
        guard let first = declaredIn.first, !suites.isEmpty else { return nil }
        let elsewhere = declaredIn.count > 1 ? " and \(declaredIn.count - 1) more" : ""
        let listed = suites.prefix(Self.listedSuites)
        let rest = suites.count - listed.count
        let more = rest > 0 ? ", +\(rest) more" : ""
        let near = listed.prefix(direct).joined(separator: ", ")
        let far = listed.dropFirst(direct).joined(separator: ", ")
        let named = if far.isEmpty {
            "suites referencing it: \(near)\(more)"
        } else if near.isEmpty {
            "no suite references it; suites reaching it through other code: \(far)\(more)"
        } else {
            "suites referencing it: \(near); reaching it through other code: \(far)\(more)"
        }
        return "  \(name) is declared in \(first)\(elsewhere); \(named) — pass one as --filter"
    }

    /// Whether `pattern` is a bare identifier, the only spelling that can name a declaration: a dotted, anchored or regex pattern names a test id, not a type.
    static func isBareIdentifier(_ pattern: String) -> Bool {
        guard let first = pattern.unicodeScalars.first, first == "_" || CharacterSet.letters.contains(first) else { return false }
        return pattern.unicodeScalars.allSatisfy { $0 == "_" || CharacterSet.alphanumerics.contains($0) }
    }

    /// The lines `outcome`'s refusal owes: empty for every run that ran its tests, so a passing run pays nothing for them.
    public static func lines(after outcome: RunOutcome, selector: RunTestSelector?, repositoryRoot: URL?, budget: TimeInterval = lookupBudget) -> [String] {
        guard let report = outcome.report, let selector, let repositoryRoot else { return [] }
        let patterns = selector.unmatchedPatterns(report, exitCode: outcome.exitCode)
        return patterns.isEmpty ? [] : lines(forPatterns: patterns, repositoryRoot: repositoryRoot, budget: budget)
    }

    /// The lines for the `patterns` a run's selectors matched no test with, one per pattern that is a declared name some suite references, at most ``listedFilters``.
    ///
    /// Empty without an index at `repositoryRoot`, which is never built for this: the line is not worth an index. It answers from the stored index as it stands: nothing is freshened or written, so a stale index gives a stale note rather than a slow one. The lookup runs on its own task and is abandoned past `budget`, so a slow or failing one costs the run its wait and no more.
    public static func lines(forPatterns patterns: [String], repositoryRoot: URL, budget: TimeInterval = lookupBudget) -> [String] {
        let names = patterns.filter(isBareIdentifier)
        let database = SiftPaths.cache(in: repositoryRoot).appendingPathComponent(SiftPaths.indexFileName)
        guard !names.isEmpty, FileManager.default.fileExists(atPath: database.path) else { return [] }
        let box = HintBox()
        let finished = DispatchSemaphore(value: 0)
        Task.detached {
            do {
                let engine = try SiftEngine(directory: repositoryRoot)
                // The index as it stands, never freshened: a note may be stale and must never be slow, and a reindex
                // abandoned at the budget would still be writing `index.db` as the process exits.
                engine.openBudget = budget
                var found: [String] = []
                for name in names where found.count < listedFilters {
                    if let line = try await engine.filterHint(named: name)?.line {
                        found.append(line)
                    }
                }
                box.store(found)
            } catch {
                box.store([])
            }
            finished.signal()
        }
        guard finished.wait(timeout: .now() + budget) == .success else { return [] }
        return box.value
    }
}

private extension UnmatchedFilterHint {
    final class HintBox: @unchecked Sendable {
        private(set) var value: [String] = []

        func store(_ lines: [String]) {
            value = lines
        }
    }
}
