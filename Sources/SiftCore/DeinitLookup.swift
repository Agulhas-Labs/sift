//
// Copyright © Agulhas Labs
//

import Foundation

/// The answer to `Type.deinit`, a declaration the index never stores.
///
/// A deinitializer has no name and no `SymbolKind`, so the name lookup behind `where` and `digest` finds nothing under the type and the path read as a declaration that does not exist. It is resolved here instead, from the source of each type the path names: the type's own lines are parsed and the deinit read out of them, so the answer is as current as the file and the type's indexed range is the only thing taken from the store.
struct DeinitLookup {
    let store: IndexStore
    /// A type's current source lines, as the renderer that asks has them.
    let source: (SymbolRow) -> [String]?

    /// What the source of each type `query` names says of its deinit, or `nil` where it is not a `Type.deinit` or names no indexed type.
    ///
    /// A type with no deinit is told apart from one whose source could not be read: the index never holds a deinit, so "none" is said only of a type whose own lines were read and hold none, and a type that could not be read is named as unchecked.
    func lookup(for query: String) throws -> Lookup? {
        let components = QualifiedPath.components(of: query)
        guard components.count > 1, components.last == "deinit" else { return nil }
        let qualifiers = Array(components.dropLast())
        let types = try store.symbols(named: qualifiers.last ?? "").filter { row in
            try row.kind.isTypeDeclaration && QualifiedPath.matches(
                qualifiers: Array(qualifiers.dropLast()),
                chain: store.parentChain(of: row).map(\.name),
                module: row.module
            )
        }
        guard !types.isEmpty, let deinitQuery = try? StructuralQuery("kind:deinit") else { return nil }
        var lookup = Lookup(cited: types.map(\.path))
        for row in types {
            let qualified = try store.qualifiedName(of: row)
            let checked = Checked(qualifiedName: qualified, path: row.path, rangeDescription: row.rangeDescription)
            guard let lines = source(row) else {
                lookup.unreadable.append(checked)
                continue
            }
            // The slice is parsed as a file of its own, so a deinit nested in an inner type is named `Outer.Inner.deinit` and only this type's own is `Type.deinit`.
            let text = lines.joined(separator: "\n")
            let found = StructuralMatcher.matches(in: text, path: row.path, query: deinitQuery)
                .filter { $0.qualifiedName == "\(row.name).deinit" }
                .map { match in
                    // Two deinits under one type sit in the branches of an `#if`, and their condition is all that tells them apart.
                    Found(qualifiedName: "\(qualified).deinit", path: row.path, line: row.line + match.line - 1, endLine: row.line + match.endLine - 1, condition: IfConfigLabel.label(line: match.line, in: text))
                }
            if found.isEmpty {
                lookup.declaresNone.append(checked)
            }
            lookup.found += found
        }
        return lookup
    }

    /// The lines `where` answers with for `lookup`: the deinits found, one row each up to `cap`, then each type read and found to hold none, and each that could not be read.
    static func whereLines(for lookup: Lookup, cap: Int) -> [String] {
        var found = lookup.found.isEmpty ? [] : ["declarations (\(lookup.found.count)):"] + lookup.found.prefix(cap).map { "  \($0.heading)" }
        if lookup.found.count > cap {
            found.append("  truncated: \(lookup.found.count - cap) more declarations")
        }
        return found + lookup.absenceLines(includingNone: true)
    }

    /// What `digest` answers for the deinitializers `target` named: the source of the one, the exact targets that tell several apart, or, where none was found, which types declare none and which could not be checked.
    static func digestAnswer(for lookup: Lookup, target: String, preamble: [String], under repoRoot: URL) -> String {
        let found = lookup.found
        // A type that could not be read may hold a deinit too, so it is named beside whatever was found; one read and found to hold none is named only where nothing was.
        let preamble = preamble + lookup.absenceLines(includingNone: found.isEmpty)
        guard let first = found.first else { return preamble.joined(separator: "\n") }
        if found.count > 1 {
            // Two types of one qualified name each declare a deinit under the same target, so a repeated one is named by its file range instead.
            let repeated = Dictionary(grouping: found, by: \.qualifiedName).filter { $1.count > 1 }.keys
            let choices = found.map { "  digest \(repeated.contains($0.qualifiedName) ? "\($0.path)\($0.rangeDescription)" : $0.qualifiedName) — deinit — \($0.located)" }
            return (preamble + ["\(target) is ambiguous — \(found.count) declarations; digest one of these exact targets:"] + choices).joined(separator: "\n")
        }
        let body = switch SourceSlicer.slice(path: first.path, line: first.line, endLine: first.endLine, under: repoRoot) {
        case .unreadable: ["\(target) resolves to \(first.path), which could not be read"]
        case .emptyRange: ["\(target) has an empty range at \(first.path)\(first.rangeDescription)"]
        case let .lines(all, _): [first.heading, ""] + all
        }
        return (preamble + body).joined(separator: "\n")
    }
}

extension DeinitLookup {
    /// What the sources of the types a `Type.deinit` path names said: the deinits found, the types read and found to hold none, and the types whose source could not be read.
    struct Lookup {
        /// The paths of every type the path names, which the answer cites.
        let cited: [String]
        var found: [Found] = []
        var declaresNone: [Checked] = []
        var unreadable: [Checked] = []

        /// A line for each type that could not be checked and, where asked, for each read and found to hold none.
        func absenceLines(includingNone: Bool) -> [String] {
            let none = includingNone ? declaresNone.map { "\($0.qualifiedName) declares no deinit — checked in its source, \($0.path)\($0.rangeDescription)" } : []
            return none + unreadable.map { "could not check \($0.qualifiedName) for a deinit: its source could not be read (\($0.path)\($0.rangeDescription))" }
        }
    }

    /// A type the path names, as an absence line names it.
    struct Checked {
        let qualifiedName: String
        let path: String
        let rangeDescription: String
    }

    /// One deinitializer found under a type the path names.
    struct Found {
        /// The type's qualified name followed by `.deinit`.
        let qualifiedName: String
        let path: String
        let line: Int
        let endLine: Int
        /// The `#if` condition it sits under within its type, labelled as `where` labels a declaration's (``IfConfigLabel``), or `nil` where it sits under none.
        var condition: String?

        var rangeDescription: String {
            line == endLine ? ":\(line)" : ":\(line)-\(endLine)"
        }

        /// Its file and lines, then its condition as a declaration line places it.
        var located: String {
            "\(path)\(rangeDescription)" + (condition.map { "  [\($0)]" } ?? "")
        }

        /// The line `where` lists it on, and the header `digest` serves its source under.
        var heading: String {
            "\(qualifiedName) — deinit — \(located)"
        }
    }
}
