//
// Copyright © Agulhas Labs
//

import Foundation

/// Which side of a range records a path as a symbolic link, read from each revision's own tree rather than the working tree's `lstat`.
///
/// A path can be a link at one end of a range and a regular file at the other, which git calls a type change. A side that holds a link holds no Swift source, only its target's path, so that side is read as holding nothing at all: a link that became a file adds the file's declarations, and a file that became a link removes them. A path is left out of the range as a link only where no side holds it as a regular file.
struct RangeLinks {
    /// Every path the before side's tree holds.
    let beforePaths: Set<String>
    /// The paths the before side's tree records as links.
    let beforeLinks: Set<String>
    /// Where the after side reads a path's mode: its revision's tree, or the working tree.
    let afterModes: FileEnumerator.Modes
}

extension RangeLinks {
    /// Reads the before side's tree, and the after side's where that side is a revision.
    init(from: String, to: DiffRange.End, git: GitContext) throws {
        let before = try git.trackedEntries(at: from)
        let after: FileEnumerator.Modes = switch to {
        case .workingTree: .workingTree
        case let .revision(rev): try .revision(links: git.trackedEntries(at: rev).links)
        }
        self.init(beforePaths: Set(before.paths), beforeLinks: before.links, afterModes: after)
    }

    /// Whether each side of a change records a link: the before side at the path the change moved the file from, and the after side at the path it left the file on.
    func linkSides(of change: GitContext.Change, enumerator: FileEnumerator) -> (before: Bool, after: Bool) {
        let before = beforeLinks.contains(change.renamedFrom ?? change.path)
        let after = !Self.isDeletion(change) && enumerator.isSymbolicLink(change.path, modes: afterModes)
        return (before, after)
    }

    /// The rule that keeps a change out of the range: the enumerator's own, except that a link on one side alone does not.
    ///
    /// Only a path that no side holds as a regular file is left out for being a link.
    func exclusion(of change: GitContext.Change, enumerator: FileEnumerator) -> FileEnumerator.Exclusion? {
        let isDeletion = Self.isDeletion(change)
        // Every rule but the link one reads the path alone, so the side it is tested on changes nothing else.
        let modes: FileEnumerator.Modes = isDeletion ? .revision(links: beforeLinks) : afterModes
        if let exclusion = enumerator.exclusion(of: change.path, modes: modes), exclusion != .symbolicLink {
            return exclusion
        }
        let sides = linkSides(of: change, enumerator: enumerator)
        let beforeHoldsFile = beforePaths.contains(change.renamedFrom ?? change.path) && !sides.before
        let afterHoldsFile = !isDeletion && !sides.after
        return beforeHoldsFile || afterHoldsFile ? nil : .symbolicLink
    }

    /// The changes the range keeps, a file that became a link read as deleted, since the side that holds the link holds no source.
    func kept(_ changes: [GitContext.Change], enumerator: FileEnumerator) -> [GitContext.Change] {
        changes.compactMap { change in
            guard exclusion(of: change, enumerator: enumerator) == nil else { return nil }
            guard linkSides(of: change, enumerator: enumerator).after else { return change }
            return GitContext.Change(kind: .deleted, path: change.renamedFrom ?? change.path)
        }
    }

    private static func isDeletion(_ change: GitContext.Change) -> Bool {
        if case .deleted = change.kind {
            true
        } else {
            false
        }
    }
}
