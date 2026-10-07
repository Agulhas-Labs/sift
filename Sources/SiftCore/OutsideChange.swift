//
// Copyright © Agulhas Labs
//

/// One category of text outside every declaration that differs between a file's two sides — the imports, the `#if` lines, the comments, the top-level code, a `deinit`, a `#Preview`, or text nothing else claimed.
struct OutsideChange: Sendable {
    typealias Fragment = OutsideDeclarations.Fragment

    let category: OutsideDeclarations.Category
    /// Fragments only the after side has, with their after-side lines.
    let added: [Fragment]
    /// Fragments only the before side had, with their before-side lines.
    let removed: [Fragment]
    /// Named fragments present on both sides whose text or place differs — an import that gained an attribute, a `deinit` whose body changed, an import moved.
    let edited: [(old: Fragment, new: Fragment)]
}

extension OutsideChange {
    /// Every category that differs between two sides, in a fixed order.
    ///
    /// Which fragments changed is read off the line diff, not re-derived: a fragment changed when its lines are in a hunk and the other side of that hunk holds no fragment with the same text (compared as bytes, line terminators aside — so a line-ending conversion changes no comment, and is left for the line diff to name). So the answer names a changed comment at the lines `git diff` shows it at, a moved one as removed here and added there, and never reports text as changed that no hunk touched. Named fragments (an import by its module, a `deinit` by its type, a macro by its name) then pair by name across the file, so an edit reads as one edit rather than a removal and an addition.
    static func between(old: OutsideDeclarations?, new: OutsideDeclarations?, hunks: [LineDiff.Hunk]) -> [OutsideChange] {
        let empty = OutsideDeclarations()
        let before = old ?? empty
        let after = new ?? empty
        var changes: [OutsideChange] = []
        for category in OutsideDeclarations.Category.allCases {
            let (removed, added) = changed(old: before.fragments[category] ?? [], new: after.fragments[category] ?? [], hunks: hunks)
            let change = switch category {
            case .imports, .deinitializers, .macroExpansions:
                byLabel(category, removed: removed, added: added)
            case .conditions, .comments, .topLevelCode, .other:
                OutsideChange(category: category, added: added, removed: removed, edited: [])
            }
            if !change.added.isEmpty || !change.removed.isEmpty || !change.edited.isEmpty {
                changes.append(change)
            }
        }
        return changes
    }

    /// The fragments on each side whose lines a hunk holds and whose text the hunk's other side does not.
    private static func changed(old: [Fragment], new: [Fragment], hunks: [LineDiff.Hunk]) -> (removed: [Fragment], added: [Fragment]) {
        var removed: [Fragment] = []
        var added: [Fragment] = []
        var claimedOld: Set<Int> = []
        var claimedNew: Set<Int> = []
        for hunk in hunks {
            // Where the hunk sits, not everywhere it could slide to: a duplicated comment is one comment added, not two.
            let oldHits = old.indices.filter { !claimedOld.contains($0) && hunk.meets(old: range(of: old[$0]), new: nil, sliding: false) }
            var newHits = new.indices.filter { !claimedNew.contains($0) && hunk.meets(old: nil, new: range(of: new[$0]), sliding: false) }
            claimedOld.formUnion(oldHits)
            claimedNew.formUnion(newHits)
            for oldIndex in oldHits {
                let text = SourceText.bytes(old[oldIndex].text)
                if let same = newHits.firstIndex(where: { SourceText.bytes(new[$0].text) == text }) {
                    newHits.remove(at: same)
                } else {
                    removed.append(old[oldIndex])
                }
            }
            added += newHits.map { new[$0] }
        }
        return (removed.sorted { $0.line < $1.line }, added.sorted { $0.line < $1.line })
    }

    private static func range(of fragment: Fragment) -> DeclarationRange {
        DeclarationRange(line: fragment.line, endLine: max(fragment.line, fragment.endLine))
    }

    private static func byLabel(_ category: OutsideDeclarations.Category, removed old: [Fragment], added new: [Fragment]) -> OutsideChange {
        var added: [Fragment] = []
        var removed: [Fragment] = []
        var edited: [(old: Fragment, new: Fragment)] = []
        let oldByLabel = Dictionary(grouping: old, by: { $0.label ?? "" })
        let newByLabel = Dictionary(grouping: new, by: { $0.label ?? "" })
        for label in Set(oldByLabel.keys).union(newByLabel.keys).sorted() {
            let before = oldByLabel[label] ?? []
            let after = newByLabel[label] ?? []
            let paired = min(before.count, after.count)
            edited += zip(before.prefix(paired), after.prefix(paired)).map { (old: $0, new: $1) }
            removed += before.dropFirst(paired)
            added += after.dropFirst(paired)
        }
        return OutsideChange(category: category, added: added, removed: removed, edited: edited)
    }
}
