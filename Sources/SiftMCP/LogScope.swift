//
// Copyright © Agulhas Labs
//

import Foundation
import SiftCore

/// The one directory a `--root` argument names, resolved once for every log a command reads.
///
/// **Resolved once, against the union of both logs' roots.** `usage --root Catalogue` scopes the calls in `usage.jsonl` *and* the wrapped runs in `run.jsonl`, and those two files hold different sets of roots by construction — a run log started this month has seen fewer repositories than a usage log months older. Resolving the same fragment separately against each lets one heading carry two repositories' numbers: the header says `in /work/Catalogue` while the run row counts `/personal/Catalogue`. The two mirror failures are worse, because neither looks like a mistake — the calls half refuses an ambiguous fragment while the runs half quietly picks one of the candidates and prints a number beneath the refusal, and the other way round the run section vanishes entirely, reading as "no builds wrapped" when there had been builds.
///
/// So a fragment ambiguous across the union refuses for *both* halves, listing candidates drawn from both, and a fragment unique in the union scopes both — including the half whose own log has never recorded that root, which is an empty section rather than an unresolved one.
///
/// **Canonicalised at comparison time, never at write time.** `run.jsonl` records `git rev-parse --show-toplevel` verbatim, `usage.jsonl` records a standardized path an agent supplied, and macOS volumes are case-insensitive by default — so one repository reaches the two logs under two spellings that compare as two directories, which is the case ``CanonicalPath`` exists for. Asking the filesystem here rather than normalising what is written keeps a log an honest record of what happened (`CanonicalPath` resolves symlinks, and rewriting `/tmp/x` to `/private/tmp/x` on the way in would record a spelling nothing else holds — the reason the roots registry stores standardized paths too), and it heals every line already on disk instead of only the ones written from now on — which is the whole point for a file whose only purpose is a report about the past.
public struct LogScope: Sendable, Equatable {
    /// The directory the argument named, as the filesystem spells it.
    public let path: String

    /// Resolves `argument` against every root the logs at `urls` hold; asking for no scope gets none.
    public static func resolve(_ argument: String?, inLogsAt urls: [URL]) -> Result<LogScope?, UsageScan.Problem> {
        guard let argument else { return .success(nil) }
        return resolve(argument, among: roots(inLogsAt: urls)).map(\.self)
    }

    /// Resolves `argument` to the directory it names: an exact path, else the directory a trailing fragment names, which need not itself be a root.
    ///
    /// `Depot/app` saves typing the absolute path, and `Depot` names the product whose calls are all logged one component below it, under `Depot/app`.
    ///
    /// A bare-suffix guess is refused when it is ambiguous rather than picked, the same rule file resolution follows — reporting one repo's usage under another repo's name is worse than asking.
    ///
    /// The fragment is matched against the *canonical* spelling and stays case-sensitive there deliberately. Canonicalising is what a mistyped case needs: the exact-path branch above turns `~/src/sift` into the directory the filesystem calls `Sift`, and a fragment typed from what `ls` shows matches what `ls` shows. Folding case in the match itself would, on a case-sensitive volume, merge two directories that really are two — the same bug pointing the other way, which is exactly what ``CanonicalPath`` refuses to do.
    public static func resolve(_ argument: String, among roots: Set<String>) -> Result<LogScope, UsageScan.Problem> {
        let canonicalRoots = Set(roots.map { CanonicalPath.of($0) })
        let asked = CanonicalPath.of((argument as NSString).expandingTildeInPath)
        if canonicalRoots.contains(asked) {
            return .success(LogScope(path: asked))
        }
        let needle = argument.hasPrefix("/") ? argument : "/" + argument
        let named = Set(canonicalRoots.compactMap { $0.selfOrAncestorEnding(in: needle) }).sorted()
        return switch named.count {
        case 1:
            .success(LogScope(path: named[0]))
        case 0:
            .failure(.rootUnmatched(argument: argument, roots: canonicalRoots.sorted()))
        default:
            .failure(.rootAmbiguous(argument: argument, matches: named))
        }
    }

    /// How a report is allowed to spell a list of candidate directories: verbatim where the reader asked to see them, and otherwise the shortest fragment that names each.
    ///
    /// The refusals are the reason this exists. Both root refusals list what the argument could have been, and listing them as absolute paths would print this machine's directory layout and its owner's username — under a report whose own help says it is pseudonymised so that sharing it is safe. On a machine holding more than one person's checkouts that listing is another person's repository names, so the promise would be not merely imprecise but wrong in the one place it is most likely to be relied on.
    ///
    /// A fragment is what the option takes, so nothing a reader can act on is lost: `--root Depot/app` resolves exactly where the absolute path does, and the fragment is shorter to retype. What the shortening cannot remove is the directory's own name, and that floor is deliberate — a candidate the reader cannot type back is not a candidate at all.
    public static func spellings(of candidates: [String], redacted: Bool) -> [String] {
        guard redacted else { return candidates }
        return shorthands(of: candidates).sorted()
    }

    /// The shortest trailing fragment of each candidate that ``resolve(_:among:)`` sends back to that candidate and to nothing else — the inverse of the resolution above.
    ///
    /// Decided by asking the same question `resolve` asks, rather than by comparing components: a fragment matches a root *or an ancestor of one*, so "unique among these paths" is a claim only the resolution rule can make, and a listing that offered a fragment this command would then refuse as ambiguous would be worse than the absolute path it replaced.
    private static func shorthands(of candidates: [String]) -> [String] {
        let canonical = candidates.map { CanonicalPath.of($0) }
        return canonical.map { candidate in
            let components = candidate.split(separator: "/").map(String.init)
            for width in components.indices {
                let fragment = components.suffix(width + 1).joined(separator: "/")
                if Set(canonical.compactMap { $0.selfOrAncestorEnding(in: "/" + fragment) }) == [candidate] {
                    return fragment
                }
            }
            // Only reachable where another candidate ends in this one's whole path (`/a/b` beside `/x/a/b`):
            // no fragment names this one alone, so the absolute path is the only spelling that resolves to
            // it. Tilded rather than raw, because the username is never the report's to give away.
            return Redactor.tilded(candidate)
        }
    }

    /// Where each of `roots` stands relative to this scope, keyed by the spelling the log used; a root outside the scope is absent rather than present-and-outside.
    ///
    /// Asked per distinct root rather than per log line: canonicalisation is a filesystem question, and these logs hold thousands of lines across a handful of repositories.
    public func positions(of roots: some Sequence<String>) -> [String: Position] {
        var positions: [String: Position] = [:]
        for root in roots {
            let canonical = CanonicalPath.of(root)
            if canonical == path {
                positions[root] = .exact
            } else if canonical.isWithin(path) {
                positions[root] = .below
            }
        }
        return positions
    }

    /// Every root the logs at `urls` recorded.
    ///
    /// Read with a decoder of its own rather than through either scan, because the two scans disagree about what a line *is* — a call has a tool and a target, a run has an exit code and line counts — and a scope is about neither. All a scope needs is the timestamp that makes a line a log line at all, and the root it names.
    private static func roots(inLogsAt urls: [URL]) -> Set<String> {
        RootsRegistry.roots(inLogsAt: urls)
    }
}

public extension LogScope {
    /// Where a root recorded in a log stands relative to a scope; anything else is outside it and gets no entry at all.
    enum Position: Sendable, Equatable {
        /// The scope itself.
        case exact

        /// Beneath it — a checkout under a product folder, a linked worktree under a checkout.
        case below
    }
}

extension String {
    /// This path, or its nearest ancestor, whose path ends in `suffix` — the directory a `--root` fragment names.
    ///
    /// Nearest rather than shallowest: the more specific reading of a fragment is the one meant.
    func selfOrAncestorEnding(in suffix: String) -> String? {
        var candidate = self
        while true {
            if candidate.hasSuffix(suffix) {
                return candidate
            }
            let parent = (candidate as NSString).deletingLastPathComponent
            guard parent != candidate, !parent.isEmpty else { return nil }
            candidate = parent
        }
    }

    /// True when this path is `root` or lies beneath it — whole components, so `/a/b` holds `/a/b/c` but not `/a/bc`.
    func isWithin(_ root: String) -> Bool {
        self == root || hasPrefix(root.hasSuffix("/") ? root : root + "/")
    }
}
