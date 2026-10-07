//
// Copyright © Agulhas Labs
//

/// How `where` collapses the store's hits and uses to one row per line, counting the build units that recorded each.
extension WhereRenderer {
    /// Collapses (name, path, line) hits to one entry each, counting the build units that recorded it, preserving first-occurrence order; hits differing in any field — a drifted line included — stay separate.
    ///
    /// **A line's units are the build units that recorded something on it — never its occurrences, and never copies of one column.** Verified empirically against a real store: IndexStoreDB hands back a copy of an occurrence for each unit that recorded it, each carrying that unit's module and write time, which is ``SemanticStore/Hit/unit`` — one file compiled into two targets lists every call in it twice, told apart by target, while two configurations of one target writing identical records into one store come back as one copy. Everything one unit records on a line shares its unit, however many occurrences that is: two calls, `f() + f()`; a write and a read, `count = count + 1`; and the five reads `@Observable`'s expansion records at one column alike. Counting occurrences printed the first `×2 units`, and counting copies of one column printed the last `×3 units`; counting units prints neither. Callers, reads and writes, an enum case's uses, overrides and conformers are all counted by this one rule, and `sift diff` collapses by it too.
    static func collapsedIdentical(_ hits: [SemanticStore.Hit]) -> [(hit: SemanticStore.Hit, units: Int)] {
        collapsedUses(hits.map { SemanticStore.Use(hit: $0, reads: false, writes: false) })
            .map { (hit: $0.hit, units: $0.units) }
    }

    /// One row of a titled block: a hit, how many units recorded it, and — for a property's or subscript's use — the access the store recorded there.
    struct ListedRow {
        let hit: SemanticStore.Hit
        var units: Int
        var access: String?
    }

    /// A property's, subscript's or enum case's uses, one row per line: every occurrence recorded there merged into one, marked `read`, `write`, or `read and write` — a compound assignment, or a line that both reads and writes — and, for a property or subscript, which the caller says, `referenced` where the store recorded only the name, as it does an argument to a memberwise initializer; unmarked otherwise, as an enum case's uses always are.
    ///
    /// Counted in units by ``collapsedIdentical(_:)``'s rule: the build units that recorded something on the line.
    static func collapsedUses(_ uses: [SemanticStore.Use], markingReferences: Bool = false) -> [ListedRow] {
        var lines: [UseLine] = []
        var indexByKey: [Key: Int] = [:]
        for use in uses {
            let key = Key(name: use.hit.name, path: use.hit.path, line: use.hit.line, through: use.hit.through)
            let index: Int
            if let existing = indexByKey[key] {
                index = existing
            } else {
                index = lines.count
                indexByKey[key] = index
                lines.append(UseLine(hit: use.hit))
            }
            lines[index].units.insert(use.hit.unit)
            lines[index].reads = lines[index].reads || use.reads
            lines[index].writes = lines[index].writes || use.writes
            lines[index].unrecorded = lines[index].unrecorded || !use.accessRecorded
            // A merged line carries "referenced, not called" only when none of its sites calls it.
            lines[index].hit.uncalled = lines[index].hit.uncalled && use.hit.uncalled
        }
        return lines.map { line in
            // A use whose access the store does not record truthfully says only that it is one — never the read the store wrote down for a write.
            let access: String? = if line.unrecorded {
                "used"
            } else {
                switch (line.reads, line.writes) {
                case (true, true): "read and write"
                case (true, false): "read"
                case (false, true): "write"
                case (false, false): markingReferences ? "referenced" : nil
                }
            }
            // A use through a wrapper's sibling says which, so `$flag` handed to a Toggle is never read as `flag` itself.
            return ListedRow(hit: line.hit, units: line.units.count, access: access.map { access in line.hit.through.map { "\(access) via \($0)" } ?? access })
        }
    }

    /// The tally `collapsedUses` keeps for one line.
    private struct UseLine {
        var hit: SemanticStore.Hit
        var units: Set<String> = []
        var reads = false
        var writes = false
        /// Whether a use on the line is one whose access the store does not record truthfully (``SemanticStore/Use/accessRecorded``).
        var unrecorded = false
    }

    /// The collapse key for byte-identical semantic hits — and, for a property's use, the wrapper's sibling it went through, so a line that reads `flag` and `$flag` both lists each.
    private struct Key: Hashable {
        let name: String
        let path: String
        let line: Int
        let through: String?
    }
}
