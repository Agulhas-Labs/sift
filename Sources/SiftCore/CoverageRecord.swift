//
// Copyright © Agulhas Labs
//

import Foundation

/// The last coverage `run --coverage` measured in a repository, kept so `diff --coverage` can show it for the same tree and never for another.
public struct CoverageRecord: Codable, Sendable, Equatable {
    /// The content key of the tree the run measured.
    public let tree: String
    /// The command the run launched.
    public let command: [String]
    /// Each changed file the run measured, repository-relative, with its executable lines' counts; empty for a file compiled with no code to run.
    public let measured: [String: [Int: UInt64]]
    /// The changed files no test bundle the run built compiles.
    public let unmeasured: [String]
    /// When the run measured, or `nil` for a record written without it, which is never shown.
    public let measuredAt: Date?

    public init(tree: String, command: [String], measured: [String: [Int: UInt64]], unmeasured: [String], measuredAt: Date? = Date()) {
        self.tree = tree
        self.command = command
        self.measured = measured
        self.unmeasured = unmeasured
        self.measuredAt = measuredAt
    }
}

public extension CoverageRecord {
    /// `<repoRoot>/.sift/coverage.json`, the one record a repository keeps, replaced by each run that measures.
    static func location(in repoRoot: URL) -> URL {
        SiftPaths.cache(in: repoRoot).appendingPathComponent("coverage.json")
    }

    /// Replaces the repository's record with this one.
    func write(in repoRoot: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try FileManager.default.createDirectory(at: SiftPaths.cache(in: repoRoot), withIntermediateDirectories: true)
        try encoder.encode(self).write(to: Self.location(in: repoRoot), options: .atomic)
    }

    /// The repository's record, or `nil` where no run has measured one or it cannot be read.
    static func read(in repoRoot: URL) -> CoverageRecord? {
        guard let data = try? Data(contentsOf: location(in: repoRoot)) else {
            return nil
        }
        return try? JSONDecoder().decode(CoverageRecord.self, from: data)
    }

    /// The coverage section `diff --coverage` adds: the recorded numbers for the working tree's change where the record is this tree's, and otherwise why there are none.
    ///
    /// Line counts describe file content and git sees only part of what a build reads, so a record is shown only where the tree's content key is the one the run measured and it is younger than ``RunLedger/trustWindow``; the change is paired afresh against `HEAD`, and a changed file the record never looked at makes the whole record stale rather than part of the answer.
    static func section(in repoRoot: URL, tree: TreeKey?, now: Date = Date()) -> [String] {
        guard let record = read(in: repoRoot) else {
            return ["coverage: none recorded for this repository — `sift run --coverage -- <tests>` records it for the tree it runs on"]
        }
        let command = record.command.joined(separator: " ")
        guard let tree else {
            return CoverageAnswer.refused("the tree's content could not be keyed, so the recorded coverage cannot be tied to it")
        }
        guard record.tree == tree.value else {
            let recorded = TreeKey(value: record.tree).displayValue
            return ["coverage: stale — `\(command)` measured tree \(recorded), and the tree is now \(tree.displayValue); run it again for numbers"]
        }
        guard let measuredAt = record.measuredAt else {
            return ["coverage: stale — `\(command)` recorded no time it measured, so its age cannot be told; run it again for numbers"]
        }
        let age = now.timeIntervalSince(measuredAt)
        guard age <= RunLedger.trustWindow else {
            return ["coverage: stale — `\(command)` measured this tree \(ProvedRunAnswer.elapsed(max(0, age))) ago, past the \(ProvedRunAnswer.elapsed(RunLedger.trustWindow)) a record stands for; run it again for numbers"]
        }
        guard let declarations = try? ChangedDeclaration.inWorkingTree(against: "HEAD", git: GitContext(repoRoot: repoRoot)) else {
            return CoverageAnswer.refused("git could not list the change")
        }
        let missing = Set(declarations.map(\.path)).subtracting(record.measured.keys).subtracting(record.unmeasured).sorted()
        guard missing.isEmpty else {
            return ["coverage: stale — `\(command)` measured a change from another revision, which left out \(missing.joined(separator: ", "))"]
        }
        return CoverageAnswer.render(declarations, counts: record.measured, change: "the working tree against HEAD, as `\(command)` measured it")
    }
}
