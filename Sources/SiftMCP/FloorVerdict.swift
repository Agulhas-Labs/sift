//
// Copyright © Agulhas Labs
//

import Foundation
import SiftCore

/// One whole-file digest's decision about its file's floor, and the checkout a read has to be in for it to decide.
///
/// An answer names its file by a path relative to the root that answered, and a transcript does not record that root. So the checkout is derived from the read instead: a read at `P` can be the answer's file only in the directory `X` that is `P` with the answer's path taken off its end, and the verdict decides the read only where what the transcript does record says `X` is the checkout that answered:
///
/// - An answer that says it resolved to a repository — the note ``ResolvedRoot`` writes under the header — names that checkout outright, and `X` must be it.
/// - Otherwise the root was resolved from the directory the call named — its `root` argument, else the directory it was made from — and a resolved root encloses what it was resolved from, so `X` must be that directory or one above it. A sibling checkout is neither.
/// - And `X` must carry the name the answer's header gives its tree: a linked worktree's own directory name, a main checkout's repository name. That rules out the checkout a worktree nests inside, which encloses the worktree's calls without having answered them. An answer whose header cannot be read gives no name, and then `X` must be the call's directory itself.
///
/// Paths and names compare without regard to case wherever the volume holding them does, since there one directory is routinely spelled two ways.
///
/// What this cannot tell apart is a call made from inside one checkout and answered by another of the same directory name — a linked worktree named exactly like its repository — in either direction: the worktree's own answer decides the checkout's copy too, and the checkout's answer decides the worktree's.
struct FloorVerdict: Sendable, Equatable, Codable {
    /// The directory the call named — its `root` argument, else the directory it was made from — or `nil` where neither is known as an absolute path, or the answer's path is absolute and needs none.
    let anchor: String?
    /// The repository the answer said it resolved to, where it said so.
    let adopted: String?
    /// The name the answer's header gives the directory its tree is checked out in, or `nil` where the header could not be read.
    let tree: String?
    /// The file as the answer named it.
    let path: String
    /// Whether the answer was the file's own source.
    let servedSource: Bool
    /// Whether a difference of case alone makes two paths different, as it does on the volume the answering checkout sits on.
    let caseSensitive: Bool

    /// `nil` where the path is relative and nothing absolute places it: matched by suffix, it would take one repository's verdict for another's file.
    ///
    /// `caseSensitive` is asked of the call's directory, or of the repository the answer resolved to where the call named none; it is a parameter so a test can pin both policies on any volume.
    init?(
        _ verdict: SourcePassthrough.FileVerdict,
        anchor: String?,
        adopted: String?,
        tree: WorkingTree?,
        caseSensitive: (String) -> Bool = { FloorVerdict.volumeIsCaseSensitive(at: $0) }
    ) {
        servedSource = verdict.servedSource
        if verdict.path.hasPrefix("/") {
            path = Self.standardized(verdict.path)
            self.anchor = nil
            self.adopted = nil
            self.tree = nil
            self.caseSensitive = caseSensitive(path)
            return
        }
        let anchor = anchor.flatMap(Self.absolute)
        let adopted = adopted.flatMap(Self.absolute)
        guard let placed = anchor ?? adopted, !Self.components(verdict.path).isEmpty else { return nil }
        self.anchor = anchor
        self.adopted = adopted
        self.tree = tree?.directoryName
        path = verdict.path
        self.caseSensitive = caseSensitive(placed)
    }

    /// Whether this verdict is about the file at `read`, an absolute and standardized path.
    func decides(_ read: String) -> Bool {
        let components = Self.components(read)
        guard !path.hasPrefix("/") else { return matches(components, Self.components(path)) }
        let relative = Self.components(path)
        guard components.count >= relative.count, matches(Array(components.suffix(relative.count)), relative) else { return false }
        let checkout = Array(components.dropLast(relative.count))
        if let tree {
            guard let name = checkout.last, same(name, tree) else { return false }
        }
        if let adopted {
            return matches(checkout, Self.components(adopted))
        }
        guard let anchor else { return false }
        let called = Self.components(anchor)
        guard tree != nil else { return matches(checkout, called) }
        return checkout.count <= called.count && matches(checkout, Array(called.prefix(checkout.count)))
    }

    /// Whether the volume holding `path` tells names apart by case, asked of the nearest of `path` and the directories above it that exists; case-insensitive, the platform's default, where nothing can be asked.
    ///
    /// The nearest existing directory rather than `path` itself, because a transcript is often read after the checkout it names is gone, and the volume that held it is still the best evidence of how it spelled its paths. `lookup` is the filesystem question, a parameter so a test can pin the walk without a volume of each kind.
    static func volumeIsCaseSensitive(
        at path: String,
        lookup: (URL) -> Bool? = { try? $0.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey]).volumeSupportsCaseSensitiveNames }
    ) -> Bool {
        let directories = components(path)
        for depth in (0 ... directories.count).reversed() {
            if let sensitive = lookup(URL(fileURLWithPath: "/" + directories.prefix(depth).joined(separator: "/"))) {
                return sensitive
            }
        }
        return false
    }

    private func same(_ lhs: String, _ rhs: String) -> Bool {
        caseSensitive ? lhs == rhs : lhs.compare(rhs, options: .caseInsensitive) == .orderedSame
    }

    private func matches(_ lhs: [String], _ rhs: [String]) -> Bool {
        lhs.count == rhs.count && zip(lhs, rhs).allSatisfy { same($0, $1) }
    }

    private static func components(_ path: String) -> [String] {
        path.split(separator: "/").map(String.init)
    }

    private static func absolute(_ path: String) -> String? {
        path.hasPrefix("/") ? standardized(path) : nil
    }

    private static func standardized(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.path
    }
}
