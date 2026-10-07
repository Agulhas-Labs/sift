//
// Copyright © Agulhas Labs
//

import Foundation
import SiftCore

/// One path operand of a search an answer stands in for — a tree, a Swift file, or a shell glob of Swift files — read for what roots that answer and what bounds it.
struct SearchOperand: Equatable {
    /// The operand spelled out in full, as the command wrote it once resolved against its directory.
    let path: String

    /// Whether this names Swift files rather than a tree: one file outright, or a glob whose last component closes on `.swift`.
    var namesFiles: Bool {
        path.hasSuffix(".swift")
    }

    /// Whether this is a shell glob, which the shell expands to the files it matches before the search ever runs.
    ///
    /// Wider than ``SwiftSourcePath/isGlob(_:)``: that one leaves a bracket out because it is as likely to be a directory's name as a character class, and reads such a path as one file to digest. Once a search asks whether a *site* lies within an operand, though, the operand is never digested as a file on its own — only matched against sites `fnmatch` already reads a bracket class in, the same as the shell would.
    var isGlob: Bool {
        Self.hasWildcard(path)
    }

    /// The directory a repository is asked of: the tree itself, the directory a file stands in, or the directory before a glob's first wildcard.
    var directory: String {
        guard namesFiles else { return path }
        return literalPrefix(dropping: 1)
    }

    /// The operand relative to the repository at `root`, its literal directory spelled as the filesystem spells it: empty where it is the repository itself, and `nil` where it lies outside it or names a file that is not there.
    ///
    /// A file is spelled by the directory it stands in, which is there to ask, and its own name, so a directory reached through a symlink bounds as its target does; and a file that is not there is no operand at all, since the search prints only that it is missing.
    func scope(inRepositoryAt root: String) -> String? {
        if isGlob {
            let literal = literalPrefix(dropping: 0)
            let pattern = String(path.dropFirst(literal.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            return Self.relative(CanonicalPath.of(literal), to: root).map { $0.isEmpty ? pattern : $0 + "/" + pattern }
        }
        guard namesFiles else { return Self.relative(CanonicalPath.of(path), to: root) }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), !isDirectory.boolValue else { return nil }
        let file = URL(fileURLWithPath: path)
        return Self.relative(CanonicalPath.of(file.deletingLastPathComponent().path) + "/" + file.lastPathComponent, to: root)
    }

    /// Whether the repository-relative `site` is a file this operand's search reads, given the operand's own `scope`.
    func holds(_ site: String, scope: String) -> Bool {
        if isGlob {
            return fnmatch(scope, site, FNM_PATHNAME) == 0
        }
        return site == scope || (!namesFiles && (scope.isEmpty || site.hasPrefix(scope + "/")))
    }

    /// The operand's leading components before the first one holding a wildcard, less `dropping` more of them.
    private func literalPrefix(dropping extra: Int) -> String {
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        let literal = components.prefix { !Self.hasWildcard($0) }
        let kept = literal.count == components.count ? literal.dropLast(extra) : literal[...]
        let joined = kept.joined(separator: "/")
        return joined.isEmpty ? "/" : joined
    }

    /// Whether one path component holds a character `fnmatch` reads specially — a wildcard or a bracket class.
    ///
    /// Wider than ``SwiftSourcePath/isGlob(_:)``, which leaves a bracket out for a different question: whether a path is one file to digest outright. Here a bracket is read the way the shell and `fnmatch` both read it.
    private static func hasWildcard(_ component: some StringProtocol) -> Bool {
        component.contains { $0 == "*" || $0 == "?" || $0 == "[" }
    }

    /// `path` relative to `root`, empty where it is `root` itself, or `nil` where it lies outside it.
    private static func relative(_ path: String, to root: String) -> String? {
        let base = CanonicalPath.of(root)
        guard path != base else { return "" }
        let prefix = base.hasSuffix("/") ? base : base + "/"
        guard path.hasPrefix(prefix) else { return nil }
        return String(path.dropFirst(prefix.count))
    }
}
