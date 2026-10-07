//
// Copyright © Agulhas Labs
//

import Foundation

/// A declaration a change added, changed or moved, with the after-side lines it answers for — what coverage is measured over.
public struct ChangedDeclaration: Sendable, Equatable {
    /// The file, repository-relative.
    public let path: String
    /// The declaration as `diff` addresses it: its container path and its name.
    public let label: String
    /// The after-side lines this declaration answers for, as `diff` pairs them — a type matched on both sides answers only for its own lines.
    public let lines: [ClosedRange<Int>]

    public init(path: String, label: String, lines: [ClosedRange<Int>]) {
        self.path = path
        self.label = label
        self.lines = lines
    }
}

public extension ChangedDeclaration {
    /// Every declaration the working tree added, changed or moved against `revision`, untracked files included, in path and line order.
    ///
    /// The after side is the working tree, since that is what a run builds; a removal has no after side and is left out, and so is a move whose text did not change.
    static func inWorkingTree(against revision: String, git: GitContext) throws -> [ChangedDeclaration] {
        var changes = try git.dirtySwiftFiles()
        if try git.head().map({ git.commitHash(revision) != git.commitHash($0) }) ?? false {
            let dirty = Set(changes.map(\.path))
            changes += try git.changedSwiftFiles(from: revision, to: "HEAD").filter { !dirty.contains($0.path) }
        }
        let live = changes.filter {
            if case .deleted = $0.kind {
                false
            } else {
                true
            }
        }
        let old = try git.blobs(live.map { change in
            if case let .renamed(from) = change.kind {
                return (rev: revision, path: from)
            }
            return (rev: revision, path: change.path)
        })
        var found: [ChangedDeclaration] = []
        for (offset, change) in live.enumerated() {
            guard let new = try? Data(contentsOf: git.repoRoot.appendingPathComponent(change.path)) else { continue }
            let file = FileDiff.compare(path: change.path, status: old[offset] == nil ? .added : .modified, lineStat: nil, bytes: (old[offset], new))
            for entry in file.changes where entry.kind != .removed && !(entry.kind == .moved && entry.movedIntact) {
                let lines = entry.newSpans.map { $0.line ... $0.endLine }
                guard !lines.isEmpty else { continue }
                found.append(ChangedDeclaration(path: change.path, label: entry.label, lines: lines))
            }
        }
        return found.sorted { ($0.path, $0.lines[0].lowerBound) < ($1.path, $1.lines[0].lowerBound) }
    }
}
