//
// Copyright © Agulhas Labs
//

import Foundation

/// Answers "does that other repository's index declare this name?" without ever touching that index.
///
/// The read-only discipline this depends on lives in `ReadOnlyIndex`, which is the only thing that knows how to open an index belonging to a repository the current query is not about.
public struct SiblingIndexProbe {
    /// `true` when the repository at `root` has an existing, current-schema index declaring `name` — exactly, or as any labeled form of it.
    ///
    /// Functions are stored labeled (`save(_:to:)`), so an exact match alone can only ever find types and properties; the range clause is the same predicate the engine's own name lookup uses (`name(` sorts before `name)`, and every labeled form sits between them). Extension rows are excluded — a repo that merely *extends* a dependency's type does not declare it, and counting it as declaring turns one true declarer plus two extenders into a false three-way ambiguity.
    static func declares(name: String, atRoot root: String) -> Bool {
        matches(atRoot: root, SiblingProbeStatement.declaresName.sql, name)
    }

    /// ``declares(name:atRoot:)`` asked of a connection the caller already holds, or `nil` when the store can no longer be read through it.
    static func declares(name: String, in database: SQLiteDatabase) -> Bool? {
        matches(in: database, SiblingProbeStatement.declaresName.sql, name)
    }

    /// `true` when the repository at `root` extends a type named `name` without declaring it being required — the secondary evidence for a type whose declaration lives in an unindexed dependency.
    static func extends(name: String, atRoot root: String) -> Bool {
        matches(atRoot: root, SiblingProbeStatement.extendsName.sql, name)
    }

    /// ``extends(name:atRoot:)`` asked of a connection the caller already holds, or `nil` when the store can no longer be read through it.
    static func extends(name: String, in database: SQLiteDatabase) -> Bool? {
        matches(in: database, SiblingProbeStatement.extendsName.sql, name)
    }

    /// `true` when the repository at `root` has an existing, current-schema index recording `path` as one of its files.
    ///
    /// The comparison is the whole repo-relative path, not a suffix: a suffix match would make every repo with a `Package.swift` a candidate for every other's, turning an answerable question into a permanent ambiguity.
    static func records(path: String, atRoot root: String) -> Bool {
        matches(atRoot: root, SiblingProbeStatement.recordsPath.sql, path)
    }

    /// `true` when the repository at `root` declares the whole dotted `path` — the final component *under the qualifiers written before it*, by the same rule this repository's own resolver uses.
    ///
    /// The qualifiers are what makes this a claim worth printing. Probing the last component alone and then wording the answer as the path — "Type.column is declared in …" — is a claim about something never checked, and it would point every repository that merely contains some `column` at a caller looking for one type's case. A pointer costs a repository opened; a wrong one costs as many as it lists.
    static func declares(path: String, atRoot root: String) -> Bool {
        ReadOnlyIndex.open(atRoot: root).flatMap { declares(path: path, in: $0) } ?? false
    }

    /// ``declares(path:atRoot:)`` asked of a connection the caller already holds, or `nil` when the store can no longer be read through it.
    static func declares(path: String, in database: SQLiteDatabase) -> Bool? {
        let components = QualifiedPath.components(of: path)
        guard components.count > 1, let last = components.last else { return false }
        let qualifiers = Array(components.dropLast())
        // The module lives on `files`, so the candidate query joins for it — a symbol's module is what makes `Module.Type.member` resolvable without the module ever being a symbol.
        guard let candidates = try? database.prepare(SiblingProbeStatement.candidatesByLastComponent.sql) else {
            return nil
        }
        // The component as written, labels and all — which is what the local resolver binds, and the whole of
        // what the printed line claims. Reducing it to the base name first would re-open the defect this exists
        // to close one size smaller: `Type.lookup(nonsense:)`, a label existing in no repository at all, would
        // draw a pointer off the fact that some root declares *a* `lookup`. The SQL's range arm still finds every
        // labeled form of a bare component, so nothing is lost where the caller wrote no labels.
        candidates.bind(1, last)
        while true {
            guard let row = try? candidates.step() else { return nil }
            guard row else { return false }
            let chain = enclosingNames(ofSymbolID: candidates.columnInt(0), in: database)
            if QualifiedPath.matches(qualifiers: qualifiers, chain: chain, module: candidates.columnText(1)) {
                return true
            }
        }
    }

    /// The one file at `root` that declares `target`, or `nil` when no file does, or more than one does — an ambiguous name is not this call's to resolve, and resolving it wrong is worse than not resolving it.
    ///
    /// `target` is judged the way `declares(name:)`/`declares(path:)` judge it: undotted, any labeled form of the bare name; dotted, the final component under the qualifiers written before it.
    public static func declaringFile(named target: String, atRoot root: String) -> String? {
        let components = QualifiedPath.components(of: target)
        let qualifiers = components.count > 1 ? Array(components.dropLast()) : []
        guard let last = components.last,
              let database = ReadOnlyIndex.open(atRoot: root),
              let candidates = try? database.prepare(SiblingProbeStatement.candidatesByLastComponentWithPath.sql)
        else {
            return nil
        }
        candidates.bind(1, last)
        var paths: Set<String> = []
        while (try? candidates.step()) == true {
            if !qualifiers.isEmpty {
                let chain = enclosingNames(ofSymbolID: candidates.columnInt(0), in: database)
                guard QualifiedPath.matches(qualifiers: qualifiers, chain: chain, module: candidates.columnText(2)) else { continue }
            }
            paths.insert(candidates.columnText(1))
        }
        return paths.count == 1 ? paths.first : nil
    }

    /// The names enclosing a symbol in another root's index, outermost first — as written, so a dotted extension name stays one element for `QualifiedPath` to flatten.
    private static func enclosingNames(ofSymbolID id: Int64, in database: SQLiteDatabase) -> [String] {
        guard let statement = try? database.prepare(SiblingProbeStatement.enclosingNames.sql) else { return [] }
        var names: [String] = []
        var current: Int64? = id
        var isSelf = true
        // Bounded by the chain itself: `parent_id` points at a row inserted before it, so the walk cannot cycle.
        while let rowID = current {
            statement.reset()
            statement.bind(1, rowID)
            guard (try? statement.step()) == true else { break }
            if !isSelf {
                names.insert(statement.columnText(0), at: 0)
            }
            isSelf = false
            current = statement.columnIsNull(1) ? nil : statement.columnInt(1)
        }
        return names
    }

    /// `true` when `query`, bound to `value`, returns a row from the index at `root`.
    private static func matches(atRoot root: String, _ query: String, _ value: String) -> Bool {
        ReadOnlyIndex.open(atRoot: root).flatMap { matches(in: $0, query, value) } ?? false
    }

    /// `true` when `query`, bound to `value`, returns a row from `database`, or `nil` when `database` could not be read.
    private static func matches(in database: SQLiteDatabase, _ query: String, _ value: String) -> Bool? {
        guard let statement = try? database.prepare(query) else {
            return nil
        }
        statement.bind(1, value)
        return try? statement.step()
    }
}
