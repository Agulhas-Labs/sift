//
// Copyright © Agulhas Labs
//

import Foundation

/// Judges each distinct occurrence path once per query, and remembers what the judging found.
///
/// Deletion is settled by one `stat` — cached per path, so a symbol with forty references in one file is statted once, and `stat` rather than `FileManager.attributesOfItem` for the same reason `SiftEngine.mtime(of:)` uses it.
///
/// Modification is settled from the *indexed* row's mtime — the very value the declaring-file refusal already compares against the same anchor — so the two halves of the axis agree by construction on what "written since the build" means, rather than one reading a stored mtime and the other a fresh stat. A path the index has no row for — a dependency's source, anything excluded — is left `.live` rather than judged on an mtime nothing vouches for: this reports what it can prove, and proves nothing about files outside the index. Deletion is the exception, because a missing file is a fact about the tree that needs no index row to establish.
///
/// Made over a semantic context, it judges each file against its own build rather than one store-wide anchor: the row's change moment against the file's newest unit in the store that cites it, and a file no store holds a unit for by build membership (``BuildMembership``), then against the store's newest unit (``FileKind``).
final class OccurrenceFreshness {
    private let store: IndexStore
    /// What a file's change is measured against.
    private let basis: Basis
    /// Absolute store path → repo-relative, so the indexed row can be found.
    private let relativePath: (String) -> String
    /// The store whose rows ``state(of:)`` is asked about, whose units a file is judged against first.
    private let citing: SemanticStore?
    private var cache: [String: OccurrenceState] = [:]
    /// Each path's kind against each store that cited it, `nil` standing for a path no store cited.
    private var judgements: [Judged: FileKind] = [:]
    /// Whether each path `stat` read, so a path cited by two stores is statted once.
    private var present: [String: Bool] = [:]
    /// The worst kind each repo-relative path was judged, which decides the one set it is in.
    private var worst: [String: FileKind] = [:]
    /// Whether a unit-less file's module and project lie outside every build, by module and project.
    private var outside: [String: Bool] = [:]
    private lazy var membership: BuildMembership? = basis.context.map { context in
        let files = (try? store.fileInventory().values).map(Array.init) ?? []
        return BuildMembership(files: files, context: context, projectDirectories: basis.projectDirectories)
    }

    /// Distinct files found absent, and found newer than the build, keyed the same way refusals are (repo-relative where the path is inside the repo) so the header can union the two without counting one file twice.
    private(set) var deletedFiles: Set<String> = []
    private(set) var modifiedFiles: Set<String> = []
    /// Distinct files no store holds a unit for whose module a build of the store's project compiles, changed after the store's newest unit; a file is in at most one of the three sets, under the worse kind.
    private(set) var newFiles: Set<String> = []
    /// How many `stat` calls this query actually paid for, which is what makes the cost claim checkable.
    private(set) var stats = 0
    /// How many files' newest units needed the filesystem's spelling of their path asked for (``FileSpellings``), which is what makes that cost claim checkable.
    private(set) var spellingWalks = 0

    init(store: IndexStore, buildAnchor: Double, relativePath: @escaping (String) -> String) {
        self.store = store
        basis = .anchor(buildAnchor)
        self.relativePath = relativePath
        citing = nil
    }

    /// A judge that measures each file against its own build in `context`'s stores, `projectDirectories` (``ModuleResolver/projectDirectories``) deciding which unit-less files no build compiles, and ``state(of:)`` judging a path cited by `citing`'s rows.
    init(store: IndexStore, context: SemanticContext, projectDirectories: [String], citedBy citing: SemanticStore? = nil) {
        self.store = store
        basis = .perFile(context, projectDirectories)
        relativePath = context.relativePath
        self.citing = citing
    }

    func state(of absolutePath: String) -> OccurrenceState {
        if basis.context != nil {
            return kind(of: absolutePath, citedBy: citing).occurrenceState
        }
        if let cached = cache[absolutePath] {
            return cached
        }
        let relative = relativePath(absolutePath)
        let resolved = resolve(absolutePath, relative: relative)
        cache[absolutePath] = resolved
        switch resolved {
        case .live: break
        case .deleted: deletedFiles.insert(relative)
        case .modifiedSinceBuild: modifiedFiles.insert(relative)
        }
        return resolved
    }

    /// The kind of the file at the repo-relative `path`, as ``kind(of:citedBy:)`` judges its absolute path under the context's root.
    func kind(ofFile path: String, citedBy citing: SemanticStore? = nil) -> FileKind {
        kind(of: (basis.context?.repoRoot.standardizedFileURL.path ?? "") + "/" + path, citedBy: citing)
    }

    /// The kind of the file at the absolute `absolutePath`, judged against its newest unit in `citing`, the store whose row cites it, and otherwise in the first of the context's stores holding one.
    func kind(of absolutePath: String, citedBy citing: SemanticStore? = nil) -> FileKind {
        guard let context = basis.context else {
            switch state(of: absolutePath) {
            case .live: return .current
            case .deleted: return .deleted
            case .modifiedSinceBuild: return .changed
            }
        }
        let key = Judged(store: citing.map(ObjectIdentifier.init), path: absolutePath)
        if let known = judgements[key] {
            return known
        }
        let relative = relativePath(absolutePath)
        let kind = judge(absolutePath, relative: relative, citedBy: citing, in: context)
        judgements[key] = kind
        record(kind, for: relative)
        return kind
    }

    /// The kind of the indexed file `row` describes, judged on its row alone: no `stat`, and nothing recorded in the sets, so a scan over every indexed file picks its candidates without counting them.
    func unrecordedKind(of row: FileRow) -> FileKind {
        guard let context = basis.context else {
            return row.mtime > basis.anchor ? .changed : .current
        }
        let absolutePath = context.repoRoot.standardizedFileURL.path + "/" + row.path
        return builtKind(of: row, absolutePath: absolutePath, relative: row.path, citedBy: nil, in: context)
    }

    /// Whether the indexed file at the repo-relative `path` was written since its own build, judged on its row alone as ``unrecordedKind(of:)`` judges it: changed, or new.
    func writtenSinceBuild(file path: String) -> Bool {
        guard let row = try? store.fileRow(path: path) else { return false }
        return unrecordedKind(of: row).occurrenceState == .modifiedSinceBuild
    }

    /// The instant the file at the repo-relative `path` is measured against: its own newest unit, else the newest of the stores answering for it.
    func buildAnchor(ofFile path: String, citedBy citing: SemanticStore? = nil) -> Double {
        guard let context = basis.context else { return basis.anchor }
        let absolutePath = context.repoRoot.standardizedFileURL.path + "/" + path
        let unit = newestUnit(of: absolutePath, relative: path, citedBy: citing, in: context) ?? newestAnswering(path, in: context)
        return SemanticContext.buildAnchor(newestUnit: unit ?? context.store.newestUnitDate)
    }

    private func resolve(_ absolutePath: String, relative: String) -> OccurrenceState {
        stats += 1
        var info = stat()
        guard stat(absolutePath, &info) == 0 else { return .deleted }
        guard let row = try? store.fileRow(path: relative) else { return .live }
        return row.mtime > basis.anchor ? .modifiedSinceBuild : .live
    }
}

private extension OccurrenceFreshness {
    enum Basis {
        /// One store-wide instant, already nudged past equality by the caller.
        case anchor(Double)
        /// Each file's own newest unit in the context's stores.
        case perFile(SemanticContext, [String])

        var anchor: Double {
            if case let .anchor(anchor) = self {
                return anchor
            }
            return 0
        }

        var context: SemanticContext? {
            if case let .perFile(context, _) = self {
                return context
            }
            return nil
        }

        var projectDirectories: [String] {
            if case let .perFile(_, directories) = self {
                return directories
            }
            return []
        }
    }

    struct Judged: Hashable {
        let store: ObjectIdentifier?
        let path: String
    }

    func judge(_ absolutePath: String, relative: String, citedBy citing: SemanticStore?, in context: SemanticContext) -> FileKind {
        guard exists(absolutePath) else { return .deleted }
        guard let row = try? store.fileRow(path: relative) else { return .current }
        return builtKind(of: row, absolutePath: absolutePath, relative: relative, citedBy: citing, in: context)
    }

    /// The kind of a file the tree holds, from its index row: against its newest unit where a store holds one, else by build membership and then the store's newest unit.
    func builtKind(of row: FileRow, absolutePath: String, relative: String, citedBy citing: SemanticStore?, in context: SemanticContext) -> FileKind {
        if let unit = newestUnit(of: absolutePath, relative: relative, citedBy: citing, in: context) {
            return row.mtime > SemanticContext.buildAnchor(newestUnit: unit) ? .changed : .current
        }
        guard !isOutsideTheBuild(row) else { return .notBuilt }
        guard let newest = newestAnswering(relative, in: context) else { return .notBuilt }
        return row.mtime > SemanticContext.buildAnchor(newestUnit: newest) ? .new : .notBuilt
    }

    /// The newest unit of the stores answering for the repo-relative `relative`, what a file none holds a unit for is measured against.
    func newestAnswering(_ relative: String, in context: SemanticContext) -> Date? {
        ([context.store] + context.inTreeStores).filter { $0.answers(forFile: relative) }.map(\.newestUnitDate).max()
    }

    func exists(_ absolutePath: String) -> Bool {
        if let known = present[absolutePath] {
            return known
        }
        stats += 1
        var info = stat()
        let found = stat(absolutePath, &info) == 0
        present[absolutePath] = found
        return found
    }

    /// The newest unit of the file in `citing`, else in the first of the context's stores answering for it that holds one, the path tried as given and then as each spelling a build may have recorded it by, the filesystem's asked only once the others miss (``FileSpellings``).
    func newestUnit(of absolutePath: String, relative: String, citedBy citing: SemanticStore?, in context: SemanticContext) -> Date? {
        let stores = (citing.map { [$0] } ?? []) + ([context.store] + context.inTreeStores).filter { $0 !== citing }
        var spellings = FileSpellings(ofFile: relative, under: context.repoRoot, leading: absolutePath)
        defer { spellingWalks += spellings.askedTheFilesystem ? 1 : 0 }
        for candidate in stores where candidate.answers(forFile: relative) {
            if let spelling = spellings.first(where: { candidate.newestUnit(ofFile: $0) != nil }) {
                return candidate.newestUnit(ofFile: spelling)
            }
        }
        return nil
    }

    func isOutsideTheBuild(_ row: FileRow) -> Bool {
        guard let membership else { return false }
        let key = membership.project(of: row.path) + "\u{0}" + row.module
        if let known = outside[key] {
            return known
        }
        let found = membership.outsideTheBuild([row]).contains(row.path)
        outside[key] = found
        return found
    }

    /// Records `kind` for `relative`, keeping only the worse of it and what the path was judged before, so a file is in one set at most.
    func record(_ kind: FileKind, for relative: String) {
        let before = worst[relative] ?? .current
        guard kind < before else { return }
        worst[relative] = kind
        set(of: before, removing: relative)
        switch kind {
        case .deleted: deletedFiles.insert(relative)
        case .changed: modifiedFiles.insert(relative)
        case .new: newFiles.insert(relative)
        case .notBuilt, .current: break
        }
    }

    func set(of kind: FileKind, removing relative: String) {
        switch kind {
        case .deleted: deletedFiles.remove(relative)
        case .changed: modifiedFiles.remove(relative)
        case .new: newFiles.remove(relative)
        case .notBuilt, .current: break
        }
    }
}
