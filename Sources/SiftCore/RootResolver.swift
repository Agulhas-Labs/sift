//
// Copyright © Agulhas Labs
//

import Foundation

/// Resolves the repository a query runs against, healing the rootless case instead of refusing it.
///
/// A portfolio session sits above every repo, so a query with no `root:` has nothing to resolve against, and failing outright — printing the registry's roots and asking the caller to pick — is never justified: `SiblingIndexProbe` can ask every one of those indexes "do you declare this name?" — or "do you contain this file?" — in microseconds without opening a writable connection, which is exactly the question whose answer decides the root. A rootless query names a symbol or a file, and either one is a retry against a root the tool can find for itself.
///
/// The line this draws — and the reason `where`'s staleness refusal is untouched — is that self-healing is only ever right for a *lookup*. Resolving a root is a read the tool can complete in-process; refreshing a stale index store needs a build, which is minutes long, side-effecting, and may fail. Answering from stale semantic data is the thing the freshness contract exists to prevent, so that one stays a refusal.
public struct RootResolver {
    /// The root for `directory`, adopting an indexed root that accounts for `target` when nothing encloses it.
    ///
    /// Ambiguity is reported rather than guessed — but only among the roots that actually match, which is a far shorter and more useful list than every root on the machine. And before it is reported at all, the directory gets a vote: a query made from a *container* folder — a product folder holding the `app` and `web` repos — names a subtree, and a candidate the directory encloses beats candidates elsewhere on the machine. That is not a guess, it is what the caller already said; four `Theme`s across four apps collapse to the one under the folder the session is sitting in. Only a tie *among enclosed candidates*, or a directory enclosing none of them, still has to ask.
    ///
    /// When no evidence matches at all — including when the target is nothing the index can be asked about — the directory gets the last word too, via `soleEnclosedRoot`. `target` is therefore optional rather than required: a registry with one repository under the working directory answers `digest .` without needing a name.
    ///
    /// The named-explicitly flag marks a directory the caller chose (`--root`, `root:`) rather than the one the session happens to sit in. A named directory is the tree the answer is about, so only an indexed root *under* it may stand in for it (a container folder holding repos); one elsewhere on the machine never does, and a folder that is no git work tree and holds none is refused by name (`EngineError.notAGitWorkTree`).
    public static func resolve(directory: URL, registry: RootsRegistry?, probing target: String?, namedExplicitly: Bool = false) throws -> ResolvedRoot {
        if let root = GitContext.discoverRoot(from: directory) {
            return .enclosing(root)
        }
        let origin = directory.standardizedFileURL.path
        let known = (registry?.knownRoots() ?? []).filter { !namedExplicitly || encloses(origin, root: $0) }
        if namedExplicitly, known.isEmpty {
            throw EngineError.notAGitWorkTree(origin)
        }
        guard !known.isEmpty else {
            throw EngineError.notAGitRepository(origin, knownRoots: known)
        }
        for evidence in target.map(probeEvidence(for:)) ?? [] {
            // Collapsed after the probe, never before: the probe is a read of an existing index, and this spawns git per surviving root.
            let matching = RepositoryIdentity.collapsingWorktrees(of: known.filter { matches(evidence, atRoot: $0) })
            switch matching.count {
            case 0:
                continue
            case 1:
                return .adopted(URL(fileURLWithPath: matching[0]), matching: evidence, from: origin, within: false)
            default:
                let enclosed = matching.filter { encloses(origin, root: $0) }
                if enclosed.count == 1 {
                    return .adopted(URL(fileURLWithPath: enclosed[0]), matching: evidence, from: origin, within: true)
                }
                // A narrowed tie lists only the enclosed candidates — the shorter list is the actionable one.
                throw EngineError.foundInSeveralRoots(evidence, roots: enclosed.isEmpty ? matching : enclosed)
            }
        }
        if let sole = soleEnclosedRoot(of: known, under: origin) {
            return .enclosedSole(URL(fileURLWithPath: sole), from: origin)
        }
        if namedExplicitly {
            throw EngineError.notAGitWorkTree(origin)
        }
        throw EngineError.notAGitRepository(origin, knownRoots: known)
    }

    /// The one indexed repository sitting under `origin`, when there is exactly one.
    ///
    /// The last resort, and the one that does not need the index to have heard of the target. Name evidence answers a question the index can be asked; this answers the question the *directory* already asked, and it covers the three cases evidence never reaches: a target that names nothing probeable (`digest .`), a name too new to be indexed yet (written minutes ago, and the probe is deliberately a read of the last index rather than a rebuild), and a name no indexed root declares — where adopting the enclosing repository at least produces an honest "no such type here" instead of a lecture about git.
    ///
    /// It runs last so evidence keeps winning: a name that lives in a repository *outside* the container still resolves there rather than being captured by proximity.
    private static func soleEnclosedRoot(of known: [String], under origin: String) -> String? {
        let under = known.filter { encloses(origin, root: $0) }
        // Collapsed only when it would change the count, since collapsing spawns git per root.
        let repositories = under.count > 1 ? RepositoryIdentity.collapsingWorktrees(of: under) : under
        return repositories.count == 1 ? repositories[0] : nil
    }

    /// Whether `root` sits at or below `origin` — the boundary is a path component, so `app-archive` is not under `app`.
    private static func encloses(_ origin: String, root: String) -> Bool {
        root == origin || root.hasPrefix(origin.hasSuffix("/") ? origin : origin + "/")
    }

    /// The questions worth asking each indexed root about `target`, most specific first.
    ///
    /// A path target asks a *different* question than a name one: a path names no symbol, so the name probe can only ever miss, and `digest Some/File.swift` from a portfolio directory would dead-end on the registry listing while the file sat in an indexed root that records that exact path. The index knows its own files, so it is the same one-probe question with a different table behind it.
    ///
    /// Declaration evidence outranks extension evidence for *every* key: the type lives where it is declared, so a root that declares the name beats any number of roots that merely extend it — and the extension question is asked at all because a dependency's type (declared in a package no registry indexes) can be extended in exactly one root, which is then the only root with anything to say about it.
    ///
    /// A line range (`File.swift:120`, `File.swift:12-40`) asks about the file it names, so the probe is of that file's path: the files table records paths, never lines, and asking it for `File.swift:120` would miss in every root while the file itself resolved.
    static func probeEvidence(for target: String) -> [RootEvidence] {
        if let range = DigestLineRange.parse(target) {
            return [.containing(range.path)]
        }
        if target.contains("/") || target.hasSuffix(".swift") {
            return [.containing(target)]
        }
        let keys = probeKeys(from: target)
        return keys.map { .declaring($0) } + keys.map { .extending($0) }
    }

    /// Whether the index at `root` supports `evidence`.
    private static func matches(_ evidence: RootEvidence, atRoot root: String) -> Bool {
        switch evidence {
        case let .declaring(name): SiblingIndexProbe.declares(name: name, atRoot: root)
        case let .extending(name): SiblingIndexProbe.extends(name: name, atRoot: root)
        case let .containing(path): SiblingIndexProbe.records(path: path, atRoot: root)
        }
    }

    /// The names worth probing for a target, most specific first.
    ///
    /// A dotted target is tried by its first component and then its last, which covers the two shapes that carry a real type name in different places: `Type.member` resolves on the first, `Module.Type` on the last (a module is not a symbol, so probing it alone would always miss). The `.` overview names nothing the index can be asked about, and yields no keys at all.
    static func probeKeys(from target: String) -> [String] {
        guard target != ".", !target.contains("/"), !target.hasSuffix(".swift") else { return [] }
        // Split by `QualifiedPath`, so a labeled component survives here exactly as it does everywhere else —
        // reduced to its base name after the split, because these keys are matched as *names* and each is named
        // in the answer as the evidence it is. That is what keeps this looser check honest where the cross-root
        // pointer's is tight: this one never claims the path, only the component it matched.
        let components = QualifiedPath.components(of: target).map { QualifiedPath.baseName(of: $0) }.filter { !$0.isEmpty }
        guard let first = components.first, let last = components.last else { return [] }
        return first == last ? [first] : [first, last]
    }
}
