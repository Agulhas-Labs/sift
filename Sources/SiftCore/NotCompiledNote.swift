//
// Copyright © Agulhas Labs
//

/// The note under a stale header naming the modules a later build left out, where the answer cites rows in a changed file of theirs it does not refuse (Docs/Design.md §2).
///
/// A file whose change predates the newest unit of the store holding its unit was skipped by a later build, so rebuilding what was just built leaves its rows as they are; the note names the module that needs building instead. It is absent after a full build, which leaves no counted file changed before it.
struct NotCompiledNote {
    /// The modules named before the rest are counted.
    static var moduleCap: Int {
        2
    }

    /// The note for `counted`, an answer's stale files by kind, less the `refused` files whose refusals already name their module; `nil` where no changed file among them predates the newest unit of the store in `context` holding its unit.
    static func line(for counted: [String: FileKind], refused: Set<String>, in index: IndexStore, context: SemanticContext) throws -> String? {
        var modules: Set<String> = []
        for (path, kind) in counted where kind == .changed && !refused.contains(path) {
            guard let row = try index.fileRow(path: path), let holder = context.storeHoldingUnit(forFile: path) else { continue }
            if row.mtime <= SemanticContext.buildAnchor(newestUnit: holder.newestUnitDate) {
                modules.insert(row.module)
            }
        }
        guard !modules.isEmpty else { return nil }
        let sorted = modules.sorted()
        let rest = sorted.count > moduleCap ? " +\(sorted.count - moduleCap)" : ""
        let named = sorted.prefix(moduleCap).joined(separator: ", ") + rest
        return "not compiled by the last build: \(named) — build \(sorted.count == 1 ? "it" : "them") for current rows"
    }
}
