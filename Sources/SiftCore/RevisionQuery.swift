//
// Copyright © Agulhas Labs
//

import Foundation

/// `digest --at` and `where --at`: a question asked of a past revision's tree, answered syntactically from a transient parse of only the files that could bear on it.
///
/// The renderers are the working tree's own, pointed at a ``RevisionSnapshot`` instead of the store, so an answer about a revision reads exactly as one about the working tree does — under a header that names the revision and says it is syntactic, and a line counting the files parsed.
struct RevisionQuery {
    let repoRoot: URL
    let tree: WorkingTree
    let git: GitContext
    let enumerator: FileEnumerator
    let resolver: ModuleResolver
    let config: SiftConfig
    let revision: String

    /// What the semantic half of a `where --at` answer says in place of the store, which describes the working tree and so nothing at a past revision.
    static var semanticNote: String {
        "semantic not consulted (--at reads a past revision; the build's index store describes the working tree)"
    }

    /// The declaration surface of each target as of the revision; a module, `.` or a `.md` target is refused, since none of them is answerable from a few files.
    func digest(targets: [String], options: DigestOptions) throws -> String {
        let files = try RevisionSnapshot.indexableFiles(revision: revision, git: git, enumerator: enumerator)
        let moduleNames = Self.moduleNames(for: files.paths, resolver: resolver)
        let written = targets.map(relativeTarget)
        var paths: [String] = []
        var names: [String] = []
        for target in written {
            if let refusal = refusal(forDigestTarget: target, moduleNames: moduleNames) {
                throw EngineError.revisionRefused(refusal)
            }
            if let range = DigestLineRange.parse(target) {
                paths.append(range.path)
            } else if target.contains("/") || target.hasSuffix(".swift") {
                paths.append(target)
            } else {
                names += searchNames(for: target, moduleNames: moduleNames)
            }
        }
        if written.count == 1, paths.count == 1, names.isEmpty,
           let notice = try excludedFileNotice(target: paths[0], commit: files.commit)
        {
            return try header(commit: files.commit) + "\n" + notice
        }
        // A path target excluded from today's index answers with the same notice inside a multi-target digest, rather than falling to the renderer's own "no indexed file" miss, which knows nothing about the revision or why the file is out.
        var notices: [String: String] = [:]
        for path in paths {
            if let notice = try excludedFileNotice(target: path, commit: files.commit) {
                notices[path] = notice
            }
        }
        let snapshot = try read(files: files, selecting: { path in paths.contains { Self.path(path, answers: $0) } }, naming: names)
        defer { snapshot.discard() }
        var renderer = DigestRenderer(store: snapshot.store, moduleNames: moduleNames, repoRoot: snapshot.root)
        renderer.config = config
        let rendered: String
        if notices.isEmpty {
            rendered = try renderer.render(targets: written, options: options)
        } else {
            if written.count > 1, options.offset != 0 {
                throw EngineError.offsetWithSeveralTargets(count: written.count)
            }
            let bodies = try written.map { target -> String in
                try notices[target] ?? renderer.render(targets: [target], options: options)
            }
            rendered = DigestRenderer.joinedAnswers(bodies)
        }
        let body = rendered.replacingOccurrences(
            of: #"(no symbol named \S+) in the index"#,
            with: "$1 \(missedAtRevision(snapshot))",
            options: .regularExpression
        )
        return try header(snapshot) + "\n" + readLine(snapshot, names: names, files: paths) + "\n" + body
    }

    /// Why a target answerable only as a file cannot be, when the file is real at the revision but excluded from the index today — read straight from the target's tracked path rather than a miss the snapshot's already-filtered candidates could never explain.
    ///
    /// A target written as a bare file name can match more than one tracked path (``path(_:answers:)`` falls back to matching by name alone); an exact — or suffix-exact — match is preferred over that fallback, so a target naming one file is never excused, or answered, by an unrelated file of the same name. And the notice fires only when every file that could answer the target is excluded: one that is not means the target is served normally.
    private func excludedFileNotice(target: String, commit: String) throws -> String? {
        let tree = try git.trackedEntries(at: commit)
        let modes = FileEnumerator.Modes.revision(links: tree.links)
        let matches = tree.paths.filter { Self.path($0, answers: target) }
        guard !matches.isEmpty else { return nil }
        let exact = matches.filter { $0 == target || $0.hasSuffix("/" + target) }
        let candidates = exact.isEmpty ? matches : exact
        guard candidates.allSatisfy({ enumerator.exclusion(of: $0, modes: modes) != nil }) else { return nil }
        guard let matched = candidates.first, let exclusion = enumerator.exclusion(of: matched, modes: modes) else { return nil }
        let clause = switch exclusion {
        case .configExclude, .outsideRoots:
            "today's config excludes it (\(exclusion.reason))"
        default:
            "is excluded: \(exclusion.reason)"
        }
        return "\(matched) exists at \(commit.prefix(8)) but \(clause)"
    }

    /// The clause a miss earns in place of "in the index" — the store the working tree misses against, which a revision has none of — naming the revision and what parsing it cost instead.
    private func missedAtRevision(_ snapshot: RevisionSnapshot) -> String {
        let noun = snapshot.candidates == 1 ? "file" : "files"
        return "at \(snapshot.commit.prefix(8)) — parsed \(snapshot.paths.count) of \(snapshot.candidates) Swift \(noun) naming it"
    }

    /// The symbol's declarations as of the revision, with call sites matched by name in that revision's files — never the store's callers.
    func lookup(symbol: String, options: WhereOptions) async throws -> String {
        let files = try RevisionSnapshot.indexableFiles(revision: revision, git: git, enumerator: enumerator)
        let moduleNames = Self.moduleNames(for: files.paths, resolver: resolver)
        let names = searchNames(for: symbol, moduleNames: moduleNames)
        // An initializer is also called as `Self(x)` in an extension of a protocol, in a file spelling neither its type nor `init`.
        let isInitializer = names.first == "init"
        let snapshot = try read(files: files, selecting: { _ in false }, naming: names, spelling: { isInitializer && SelfCallSpelling.isWritten(in: $0) })
        defer { snapshot.discard() }
        let listing = FileEnumerator(repoRoot: snapshot.root, config: config, gitListing: { snapshot.paths })
        let scanner = CallSiteScanner(repoRoot: snapshot.root, enumerator: listing)
        let renderer = WhereRenderer(store: snapshot.store, callSites: { await scanner.callSites(named: $0) })
        var syntactic = options
        syntactic.includeSemantic = false
        let output = try await renderer.render(query: symbol, semantic: .inactive(note: Self.semanticNote), options: syntactic)
        // The renderer's call-site wording names the tree it scans, which here is the revision's files, never the working tree's.
        let body = output.body.replacingOccurrences(of: " over the working tree", with: " over the files parsed at \(snapshot.commit.prefix(8))")
        return try header(snapshot) + "\n" + readLine(snapshot, names: names, files: [], spellingSelfCalls: isInitializer) + "\n" + body
    }

    private func read(files: (commit: String, paths: [String]), selecting: (String) -> Bool, naming names: [String], spelling: (Data) -> Bool = { _ in false }) throws -> RevisionSnapshot {
        try RevisionSnapshot.read(
            revision: revision,
            files: files,
            git: git,
            resolver: resolver,
            selecting: selecting,
            naming: names,
            spelling: spelling
        )
    }

    /// The header: the tree, and the revision in place of `head:` — with the commit it resolved to where the revision was not written as one, and a note that the working tree differs only where the revision named is `HEAD`'s own commit and the tree is dirty.
    ///
    /// Any other revision gets no such note: the answer is about that commit whatever the tree holds.
    private func header(_ snapshot: RevisionSnapshot) throws -> String {
        try header(commit: snapshot.commit)
    }

    /// The header built from the commit alone, for an answer that never builds a ``RevisionSnapshot`` at all.
    private func header(commit: String) throws -> String {
        let named = commit.hasPrefix(revision) ? revision : "\(revision) = \(commit.prefix(8))"
        let isDirtyHead = try git.head() == commit && !git.dirtyFiles().isEmpty
        let note = isDirtyHead ? "; the working tree differs" : ""
        return "\(WorkingTree.fieldOpening)\(tree.rendered)\(WorkingTree.fieldSeparator)at: \(named) (syntactic, from git\(note))"
    }

    /// What the answer cost to build: how many of the revision's Swift files were parsed, and what chose them, and where asked that files spelling a `Self(x)` call were read too, as an initializer's sweep reads them.
    private func readLine(_ snapshot: RevisionSnapshot, names: [String], files: [String], spellingSelfCalls: Bool = false) -> String {
        var chosenBy: [String] = []
        if !names.isEmpty {
            chosenBy.append("naming " + names.map { "`\($0)`" }.joined(separator: " or "))
        }
        if spellingSelfCalls {
            chosenBy.append("spelling `Self(`")
        }
        if !files.isEmpty {
            chosenBy.append("at " + files.map { "`\($0)`" }.joined(separator: " or "))
        }
        let noun = snapshot.candidates == 1 ? "file" : "files"
        return "read: parsed \(snapshot.paths.count) of \(snapshot.candidates) Swift \(noun) at \(snapshot.commit.prefix(8)) — those "
            + chosenBy.joined(separator: " or ")
    }

    /// The names a file must spell to bear on `target`: its final component, and the container written just before it unless that is a module.
    private func searchNames(for target: String, moduleNames: [String]) -> [String] {
        var components = QualifiedPath.components(of: target)
        if components.count > 1, moduleNames.contains(components[0]) {
            components.removeFirst()
        }
        let bases = components.suffix(2).map { QualifiedPath.baseName(of: $0) }
        var names: [String] = []
        for base in bases.reversed() where !names.contains(base) {
            names.append(base)
        }
        return names
    }

    /// Why a digest target cannot be answered at a revision, or `nil` when it can.
    private func refusal(forDigestTarget target: String, moduleNames: [String]) -> String? {
        let subject: String
        if target == "." {
            subject = "the repository overview"
        } else if MarkdownOutline.names(target) {
            subject = "a document"
        } else if moduleNames.contains(target) {
            subject = "a module"
        } else {
            return nil
        }
        return "digest --at answers a type, a member or a Swift file, and `\(target)` is \(subject) — ask it of a checkout of \(revision) (`git worktree add`)"
    }

    /// The revision's modules, resolved the way the working-tree indexer resolves them — per file, through the module resolver — never from the (possibly absent or stale) index store.
    private static func moduleNames(for paths: [String], resolver: ModuleResolver) -> [String] {
        Array(Set(paths.map(resolver.module(for:)))).sorted()
    }

    /// An absolute path under the repository, made repo-relative so it names the revision's file rather than the working tree's.
    private func relativeTarget(_ target: String) -> String {
        guard target.hasPrefix("/") else { return target }
        for root in [CanonicalPath.of(repoRoot.path), repoRoot.standardizedFileURL.path] where target.hasPrefix(root + "/") {
            return String(target.dropFirst(root.count + 1))
        }
        return target
    }

    /// Whether a file at `path` could answer a file target written as `asked` — exactly, as a suffix on a directory boundary, or by its file name, which the digest's own fallback serves.
    private static func path(_ path: String, answers asked: String) -> Bool {
        path == asked || path.hasSuffix("/" + asked) || (path as NSString).lastPathComponent == (asked as NSString).lastPathComponent
    }
}
