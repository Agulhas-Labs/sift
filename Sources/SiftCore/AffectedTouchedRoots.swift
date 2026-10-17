//
// Copyright © Agulhas Labs
//

import Foundation

/// The declarations a diff touched in each changed file the store answers for, with the declarations of the same file that reach them: what the resolved walk is rooted at in place of every declaration in the file.
///
/// Rooting at the whole file was the over-count: a change to two of one type's private helpers reached every test of every target touching the type. The touched set is read by the after-edit walk's own comparison (``AffectedAfterEditSeeds/of(_:store:)``), so a file it cannot fully account for keeps every declaration and is named with its reason, as it is there. What the same file says about the touched declarations joins them at hop 0, so a test → API → helper chain written in one file stays one hop from its test.
struct AffectedTouchedRoots {
    /// The roots of each narrowed file: the declarations the diff touched in it, and those of the file reaching them through references inside it.
    var roots: [String: [SymbolRow]] = [:]
    /// How many declarations the diff touched in each narrowed file, for its line in the changed-files list.
    var touched: [String: Int] = [:]
    /// The touched declarations themselves, so a touched test is listed as affected itself.
    var touchedRows: [SymbolRow] = []
    /// The comparison the roots were read from: the files it seeded whole or found only comments changed in, and the old names of what it removed.
    var comparison = AffectedAfterEditSeeds()
    /// The files kept whole because the working tree, which the index's ranges describe, differs from the range's end the comparison reads.
    var driftedPastRange: [String] = []

    /// What the answer says of the files it did not narrow and of the old names it seeded, each named with its reason as the after-edit walk names its own.
    func notes() -> [String] {
        var whole = comparison.seededWhole
        if !driftedPastRange.isEmpty {
            whole["the working tree differs from the range's end", default: []] += driftedPastRange
        }
        var lines = whole.keys.sorted().flatMap { ["", "resolved walk — seeded whole: \($0): \(whole[$0, default: []].sorted().joined(separator: ", "))"] }
        if !comparison.commentOnly.isEmpty {
            lines += ["", "resolved walk — only comments changed, so nothing was walked from: \(comparison.commentOnly.sorted().joined(separator: ", "))"]
        }
        let removed = Set(comparison.seededByName.map(\.name)).sorted()
        let what = comparison.signatureChanged.isEmpty ? "removed or renamed" : comparison.removed.isEmpty ? "changed the signature of" : "removed, renamed or changed the signature of"
        if !removed.isEmpty {
            lines += ["", "resolved walk — the declarations the diff \(what) were seeded by their old names (\(removed.joined(separator: ", "))) and followed to the call sites `where` finds by written name, since a call left unedited can now resolve to an overload the diff did not touch. Those tests are marked `name match` below."]
        }
        return lines
    }

    /// The files among `paths` whose working-tree text differs from their side at `rev`.
    static func drifted(_ paths: Set<String>, from rev: String, git: GitContext, repositoryRoot: URL) throws -> Set<String> {
        let sorted = paths.sorted()
        let blobs = try git.blobs(sorted.map { (rev: rev, path: $0) })
        return Set(zip(sorted, blobs).filter { path, blob in blob != (try? Data(contentsOf: repositoryRoot.appendingPathComponent(path))) }.map(\.0))
    }
}

extension AffectedRenderer {
    /// The touched roots of every changed file whose own build is current, compared as the after-edit walk compares a refused one; a file the store refuses, an added one, and every file of a renderer with no working tree to compare keep every declaration.
    func touchedRoots(_ changes: [GitContext.Change], context: SemanticContext, reader: TestSymbolReader, occurrences: OccurrenceFreshness, declaringFiles: OccurrenceFreshness) throws -> AffectedTouchedRoots {
        guard let fileDiffs, callSites != nil else { return AffectedTouchedRoots() }
        var fresh: Set<String> = []
        for change in changes where try store.fileRow(path: change.path) != nil && context.packagesPassingOver(file: change.path) == nil {
            if declaringFiles.kind(ofFile: change.path, citedBy: context.store) == .current {
                fresh.insert(change.path)
            }
        }
        var result = AffectedTouchedRoots()
        let drifted = try driftedPastRange?(fresh) ?? []
        result.driftedPastRange = drifted.sorted()
        // An added file is new throughout, so it counts in full without a comparison.
        let diffs = try fileDiffs(fresh.subtracting(drifted)).filter { $0.status != .added }
        result.comparison = try AffectedAfterEditSeeds.of(diffs, store: store)
        let touchedByFile = Dictionary(grouping: result.comparison.rows.filter { $0.kind != .extensionKind }, by: \.path)
        for path in result.comparison.files.union(result.comparison.commentOnly).sorted() {
            var seen: Set<Int64> = []
            let fileRows = try store.symbols(inFile: path)
            let touched = (touchedByFile[path] ?? []).filter { seen.insert($0.id).inserted }
            // A change reached through its type as well as by its name (an operator, a witness the language calls, an enum case added or removed, a stored property) roots the type too, as the after-edit walk seeds the type's name: the type its own file declares, never a same-named one of another file.
            let types = result.comparison.typeSeeds[path] ?? []
            let throughTypes = fileRows.filter { $0.kind.isTypeDeclaration && types.contains($0.name) && seen.insert($0.id).inserted }
            let dispatched = try dispatchRoots(of: touched, fileRows: fileRows, context: context, reader: reader, occurrences: occurrences).filter { seen.insert($0.id).inserted }
            result.touchedRows += touched
            result.touched[path] = touched.count
            let start = touched + throughTypes + dispatched
            result.roots[path] = try start + sameFileClosure(of: start, in: path, context: context, reader: reader, occurrences: occurrences)
        }
        return result
    }

    /// With no store, the comparison of every changed file the index holds, and the roots it gives: each file is walked to its call sites from the declarations the diff touched, by the comparison the after-edit walk uses.
    ///
    /// An added file, one the index does not hold, and every file of a renderer with no working tree to compare keep every declaration and the written-name walk; a file the working tree has moved on from since the range's end is kept whole and named.
    func noStoreSeeds(_ changes: [GitContext.Change]) throws -> (seeds: AffectedAfterEditSeeds, touched: AffectedTouchedRoots) {
        guard let fileDiffs, callSites != nil else { return (AffectedAfterEditSeeds(), AffectedTouchedRoots()) }
        var held: Set<String> = []
        for change in changes where try store.fileRow(path: change.path) != nil {
            held.insert(change.path)
        }
        let drifted = try driftedPastRange?(held) ?? []
        var seeds = try AffectedAfterEditSeeds.of(fileDiffs(held.subtracting(drifted)).filter { $0.status != .added }, store: store)
        if !drifted.isEmpty {
            seeds.seededWhole["the working tree differs from the range's end", default: []] += drifted.sorted()
        }
        var result = AffectedTouchedRoots()
        let byFile = Dictionary(grouping: seeds.rows.filter { $0.kind != .extensionKind }, by: \.path)
        for path in seeds.files.union(seeds.commentOnly) {
            var seen: Set<Int64> = []
            let rows = (byFile[path] ?? []).filter { seen.insert($0.id).inserted }
            result.roots[path] = rows
            result.touched[path] = rows.count
        }
        return (seeds, result)
    }

    /// For each touched member, the declarations a call reaching it by dynamic dispatch is recorded against, and for one nothing reaches, its type.
    ///
    /// A call through a protocol or a superclass is recorded against the requirement or the base member, never the witness or the override, so the written declarations it implements or overrides are rooted, to a fixed point. A member witnessing a requirement the index holds no written declaration of — a library protocol's, such as a decoding initializer or an `id` — roots the outermost type declaring it in its own file whatever else references it, since the calls through that requirement, a generic's in this module among them, are recorded against a declaration the walk cannot start from. A member that neither its own references nor theirs reach roots its type too, as the after-edit walk falls back to it (``AffectedAfterEditSeeds/fallbacks``).
    private func dispatchRoots(of touched: [SymbolRow], fileRows: [SymbolRow], context: SemanticContext, reader: TestSymbolReader, occurrences: OccurrenceFreshness) throws -> [SymbolRow] {
        var roots: [SymbolRow] = []
        for row in touched where row.parentID != nil && !row.kind.isContainer {
            guard let usr = context.store.usr(for: row) else { continue }
            var known: Set<String> = [usr]
            var pending = [usr]
            var walked = [(row: row, usr: usr)]
            var witnessesUnwritten = false
            while let next = pending.popLast() {
                for base in context.store.implementedUSRs(ofUSR: next) where known.insert(base).inserted {
                    pending.append(base)
                    let before = walked.count
                    for definition in context.store.writtenDefinitions(ofUSR: base) {
                        if let written = try reader.enclosingSymbol(path: context.relativePath(definition.path), line: definition.line), context.store.usr(for: written) == base {
                            walked.append((written, base))
                        }
                    }
                    if walked.count == before {
                        witnessesUnwritten = true
                    }
                }
            }
            roots += walked.dropFirst().map(\.row)
            let reached = try !witnessesUnwritten && walked.contains { candidate in
                try hits(ofUSR: candidate.usr, context: context, reader: reader, occurrences: occurrences).contains { $0.enclosing.id != candidate.row.id }
            }
            if !reached {
                roots += Self.outermostTypes(of: row, in: fileRows)
            }
        }
        return roots
    }

    /// The outermost type declaring `row` in its own file: the type itself, or for a member of an extension, the file's top-level type of the extended name; none at file scope.
    private static func outermostTypes(of row: SymbolRow, in fileRows: [SymbolRow]) -> [SymbolRow] {
        let byID = Dictionary(fileRows.map { ($0.id, $0) }) { first, _ in first }
        var top = row
        while let parent = top.parentID.flatMap({ byID[$0] }) {
            top = parent
        }
        if top.kind.isTypeDeclaration, top.id != row.id {
            return [top]
        }
        guard top.kind == .extensionKind else { return [] }
        let name = String(top.name.prefix { $0 != "." && $0 != "<" })
        return fileRows.filter { $0.parentID == nil && $0.kind.isTypeDeclaration && $0.name == name }
    }

    /// The declarations of `path` that reach `touched` through references whose site lies in it, to a fixed point, so bounded by the file's own declarations.
    ///
    /// A test is left out: one referencing a root is reached at hop 1 by the walk itself, as a direct reference would be.
    private func sameFileClosure(of touched: [SymbolRow], in path: String, context: SemanticContext, reader: TestSymbolReader, occurrences: OccurrenceFreshness) throws -> [SymbolRow] {
        var known = Set(touched.map(\.id))
        var frontier = touched
        var reached: [SymbolRow] = []
        while let row = frontier.popLast() {
            guard row.kind != .extensionKind, row.kind != .operatorKind, let usr = context.store.usr(for: row) else { continue }
            for hit in try hits(ofUSR: usr, context: context, reader: reader, occurrences: occurrences)
                where hit.test == nil && hit.leadsOn && hit.enclosing.path == path && hit.enclosing.kind != .extensionKind && known.insert(hit.enclosing.id).inserted
            {
                reached.append(hit.enclosing)
                frontier.append(hit.enclosing)
            }
        }
        return reached
    }
}
