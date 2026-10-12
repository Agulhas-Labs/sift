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

    /// Whether the files and subtrees `paths` names hold any of the sites one name's answer shows — the one bound on the names shape nothing else proves.
    ///
    /// A search narrower than the repository asks a narrower question, and the `where` answer standing in for it does not: `grep -rn Depot Sources` asks whether `Depot` is used in `Sources`, and an answer listing its declaration under `Tests` reads as a yes where the search itself would have printed nothing. So where every site falls outside the operands the answer is withheld and the search runs, printing the nothing that is the truth. It is asked of one name's sites at a time, and an alternation is answered only where every name has a site inside: one name found inside is no evidence about another found only outside, and dropping that one would hand back a partial answer that reads as complete. Where a name has a site inside, its answer stands whole rather than narrowed to it, since dropping the rest would be a narrowing nobody could see; the answer says instead that it was widened, and by how much (``widening(of:by:spelled:from:inRepositoryAt:)``).
    ///
    /// **A site is any line the answer shows by its path and number** (``ExactAnswer/shownLocations(inWhereAnswer:)``): one it resolved, and one it lists by written name. The question is whether the reader is handed a line inside the search, and a name-matched use is that line; a tree with no index store resolves only its declarations, and lists every use that way.
    ///
    /// An operand may be a tree, a Swift file or a shell glob of them: a file holds only a site in that file, and a glob only a site in a file it matches as the shell matches it. An operand that *is* the repository bounds nothing (its scope is empty), and neither does a call carrying no operands — a `Grep` with no path searches everything under the caller. An operand with no scope at all — a file that is not there, a path that resolves nowhere in the repository — holds nothing, so an answer is never handed over for a search that would only have printed an error.
    static func operands(_ paths: [String], from directory: String?, inRepositoryAt root: String, holdAnyOf shown: Set<ExactAnswer.Location>) -> Bool {
        guard !paths.isEmpty else { return true }
        let scopes = operandScopes(of: paths, from: directory, inRepositoryAt: root)
        guard scopes.count == paths.count else { return false }
        guard !scopes.contains(where: \.1.isEmpty) else { return true }
        return shown.contains { site in
            scopes.contains { $0.holds(site.path, scope: $1) }
        }
    }

    /// The line an answer standing whole for a search of `paths` carries where it shows sites outside them, counting the sites inside against every site shown, or `nil` where every site is inside or the operands bound nothing.
    ///
    /// The answer is not narrowed to the operands (``operands(_:from:inRepositoryAt:holdAnyOf:)``), so it says it was widened past them: `grep -rn Depot Sources` answered with `Depot`'s eleven sites, ten of them under `Tests`, otherwise reads as eleven sites in `Sources`. No operand, or one that is the repository itself, bounds nothing, so it widens nothing either. The operands are named as `spelled` where the call carries them resolved (a `Grep`'s path).
    static func widening(of shown: Set<ExactAnswer.Location>, by paths: [String], spelled: [String]? = nil, from directory: String?, inRepositoryAt root: String) -> String? {
        guard !paths.isEmpty else { return nil }
        let scopes = operandScopes(of: paths, from: directory, inRepositoryAt: root)
        guard !scopes.contains(where: \.1.isEmpty) else { return nil }
        let inside = shown.count { site in
            scopes.contains { $0.holds(site.path, scope: $1) }
        }
        guard inside < shown.count else { return nil }
        let verb = inside == 1 ? "is" : "are"
        return "answered across the tree: \(inside) of \(shown.count) sites shown \(verb) under \((spelled ?? paths).joined(separator: " "))"
    }

    /// Each of `paths` resolved against `directory` as an operand, beside its scope in the repository at `root`, leaving out an operand that has none.
    private static func operandScopes(of paths: [String], from directory: String?, inRepositoryAt root: String) -> [(SearchOperand, String)] {
        let operands = paths.compactMap { OperandFile.absolute($0, in: directory) }.map(SearchOperand.init(path:))
        return operands.compactMap { operand in operand.scope(inRepositoryAt: root).map { (operand, $0) } }
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
