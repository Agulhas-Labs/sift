//
// Copyright © Agulhas Labs
//

import Foundation

/// The pure tree diff behind `sift diff`: two parses of one file in, every declaration that was added, removed, changed, or moved out.
///
/// Never touches git, the index store, or disk — `DiffGatherer` gathers both sides first (Docs/Design.md's "parse only the files the range touches, on both sides" rule lives there, not here). Every comparison is of bytes (``SourceText``), and of whole signatures: a signature is cut only when it is printed.
struct DeclarationDiff {
    /// Every declaration change between two parses of one file.
    ///
    /// `nil` on either side reads as "this file does not exist there" — a deleted file's every declaration reads as removed, an added file's every declaration reads as added, through the same recursion that handles a present-on-one-side container. Bodies, when kept, are both sides' lines on each change; a summary drops them, since a large range holds a great many.
    static func changes(old: DiffFileSide?, new: DiffFileSide?, keepBodies: Bool = true) -> [DeclarationChange] {
        changes(old: old, new: new) { _ in keepBodies }
    }

    /// The same, keeping bodies only on the changes `keepsBody` picks — the one declaration a `--member` answer names, rather than every body in the range.
    ///
    /// `hunks`, the line diff of the two sides, lets a reorder be told for what the reader's diff shows: a declaration whose text is intact but whose lines git moved is reported as moved, whichever of two swapped siblings the order comparison happened to pick.
    static func changes(
        old: DiffFileSide?,
        new: DiffFileSide?,
        hunks: [LineDiff.Hunk]? = nil,
        keepingBodiesOf keepsBody: @escaping (DeclarationChange) -> Bool
    ) -> [DeclarationChange] {
        compare(old: old, new: new, hunks: hunks, keepingBodiesOf: keepsBody).changes
    }

    /// The changes, and what the line-diff check needs to finish the answer: where every declaration present on both sides sits on each — what tells a declaration whose unchanged lines a line diff shows displaced from a change nobody named — and, for every type matched on both sides and not already reported, the entry that says where it opens or closes moved, should a hunk be found there.
    static func compare(
        old: DiffFileSide?,
        new: DiffFileSide?,
        hunks: [LineDiff.Hunk]?,
        keepingBodiesOf keepsBody: @escaping (DeclarationChange) -> Bool
    ) -> Comparison {
        let walk = Walk(old: Side(old), new: Side(new), hunks: hunks, aligned: aligned(hunks, oldCount: old?.lines.count ?? 0), keepsBody: keepsBody, paired: PairLog())
        let changes = walk.diffChildren(oldParent: nil, newParent: nil, path: Path())
        return Comparison(changes: changes, pairs: walk.paired.ranges, extents: walk.paired.extents)
    }

    /// For each before-side line (1-based) the after-side line the line diff kept it as, or 0 where it is in a hunk.
    private static func aligned(_ hunks: [LineDiff.Hunk]?, oldCount: Int) -> [Int] {
        guard let hunks else { return [] }
        var image = [Int](repeating: 0, count: oldCount + 2)
        var oldLine = 0
        var newLine = 0
        for hunk in hunks + [LineDiff.Hunk(old: oldCount ..< oldCount, new: 0 ..< 0)] {
            while oldLine < hunk.old.lowerBound, oldLine < oldCount {
                image[oldLine + 1] = newLine + 1
                oldLine += 1
                newLine += 1
            }
            oldLine = hunk.old.upperBound
            newLine = hunk.new.upperBound
        }
        return image
    }
}

extension DeclarationDiff {
    /// What one comparison of a file's two sides found.
    struct Comparison {
        let changes: [DeclarationChange]
        /// Every declaration present on both sides, by its range on each.
        let pairs: [(old: DeclarationRange, new: DeclarationRange)]
        /// For each type matched on both sides and not already reported, the entry saying where it opens or closes moved.
        let extents: [DeclarationChange]
    }
}

private extension DeclarationDiff {
    /// One side's declarations, their children indexed once, and the text each is compared by.
    struct Side {
        let file: DiffFileSide?
        let symbols: [ParsedSymbol]
        let children: [Int?: [Int]]

        init(_ file: DiffFileSide?) {
            self.file = file
            symbols = file?.file.symbols ?? []
            var children: [Int?: [Int]] = [:]
            for (index, symbol) in symbols.enumerated() {
                children[symbol.parentIndex, default: []].append(index)
            }
            self.children = children
        }

        func ownText(_ index: Int) -> String {
            file?.ownText(of: index) ?? ""
        }

        func body(_ index: Int) -> String {
            file?.body(of: symbols[index]) ?? ""
        }

        func range(_ index: Int) -> DeclarationRange {
            DeclarationRange(line: symbols[index].line, endLine: symbols[index].endLine)
        }

        func headerRange(_ index: Int) -> DeclarationRange {
            file?.headerRange(of: index) ?? range(index)
        }

        /// The names and kinds directly under a container — what two same-signature containers are told apart by.
        func memberKeys(of index: Int) -> Set<String> {
            Set((children[index] ?? []).map { "\(symbols[$0].kind.rawValue) \(symbols[$0].name)" })
        }
    }

    /// Where a level of siblings sits: the dotted path `--member` matches, and the heading a reader sees.
    struct Path {
        var dotted = ""
        var display = ""

        /// An extension always says it is one — `P (extension)` — so a protocol's own members and an extension's are never headed alike.
        func appending(_ symbol: ParsedSymbol) -> Path {
            let component = if symbol.kind == .extensionKind {
                Self.extensionComponent(name: symbol.name, qualifier: DeclarationDiff.extensionQualifier(of: symbol))
            } else {
                symbol.name
            }
            return Path(
                dotted: dotted.isEmpty ? symbol.name : "\(dotted).\(symbol.name)",
                display: display.isEmpty ? component : "\(display).\(component)"
            )
        }

        static func extensionComponent(name: String, qualifier: String) -> String {
            guard !qualifier.isEmpty else { return "\(name) (extension)" }
            return "\(name) (extension\(qualifier.hasPrefix(":") ? "" : " ")\(qualifier))"
        }
    }

    /// Siblings of one kind and name — the pairing unit.
    ///
    /// An extension's key carries its whole signature, since two `extension Array` blocks with different `where` clauses are different containers that happen to share a name.
    struct Key: Hashable, Comparable {
        let name: String
        let kind: String
        let signature: String

        static func < (lhs: Key, rhs: Key) -> Bool {
            (lhs.name, lhs.kind, lhs.signature) < (rhs.name, rhs.kind, rhs.signature)
        }
    }

    /// Everything after the extended type's name in an extension's header — its conformances and `where` clause.
    static func extensionQualifier(of symbol: ParsedSymbol) -> String {
        let signature = symbol.signature
        guard let range = signature.range(of: "extension \(symbol.name)") else { return "" }
        return signature[range.upperBound...].trimmingCharacters(in: .whitespaces)
    }

    struct Walk {
        let old: Side
        let new: Side
        let hunks: [LineDiff.Hunk]?
        /// Before-side line → the after-side line the line diff kept it as (0 in a hunk) — the tie-break between declarations with identical text.
        let aligned: [Int]
        let keepsBody: (DeclarationChange) -> Bool
        let paired: PairLog
    }

    /// Every pair the walk makes, at every level, by its ranges on the two sides — and the extent entry each quiet type would take.
    final class PairLog {
        var ranges: [(old: DeclarationRange, new: DeclarationRange)] = []
        var extents: [DeclarationChange] = []
    }

    /// One level of siblings paired: what stood on both sides, and what only one side had.
    struct Matched {
        var pairs: [(old: Int, new: Int)] = []
        var removed: [Int] = []
        var added: [Int] = []
    }
}

private extension DeclarationDiff.Walk {
    typealias Side = DeclarationDiff.Side
    typealias Path = DeclarationDiff.Path
    typealias Matched = DeclarationDiff.Matched

    /// One level of siblings, old against new.
    ///
    /// Paired by (name, kind) — an extension by its whole signature — and within that, by the strongest evidence first: identical text, then an identical signature, then (for a container) the most members in common, then the same `#if` branch, and only then source order. Pairing by position alone is how an extension inserted above two same-named ones turns an untouched member into a removal, and an overload that lost its sibling into a claimed change from one to the other. A type left with exactly one unpaired extension on each side had that extension's header edited: the two pair as one header change, and its members are compared rather than hidden inside a removal and an addition.
    func diffChildren(oldParent: Int?, newParent: Int?, path: Path) -> [DeclarationChange] {
        let level = matchLevel(oldParent: oldParent, newParent: newParent)
        var results: [DeclarationChange] = []
        var reported: Set<Int> = []
        for (oldIndex, newIndex) in level.pairs {
            let oldSymbol = old.symbols[oldIndex]
            let newSymbol = new.symbols[newIndex]
            paired.ranges.append((old.range(oldIndex), new.range(newIndex)))
            let sameCondition = SourceText.same(oldSymbol.ifConfigCondition, newSymbol.ifConfigCondition)
            if oldSymbol.kind.isContainer {
                if !SourceText.same(oldSymbol.signature, newSymbol.signature) || !sameCondition {
                    results.append(change(.changed, old: oldIndex, new: newIndex, path: path))
                    reported.insert(oldIndex)
                } else {
                    paired.extents.append(change(.changed, old: oldIndex, new: newIndex, path: path, extent: true))
                }
                results += diffChildren(oldParent: oldIndex, newParent: newIndex, path: path.appending(newSymbol))
            } else if !SourceText.same(old.ownText(oldIndex), new.ownText(newIndex)) || !sameCondition || oldSymbol.accessLevel != newSymbol.accessLevel {
                results.append(change(.changed, old: oldIndex, new: newIndex, path: path))
                reported.insert(oldIndex)
            }
        }
        results += level.removed.map { change(.removed, old: $0, new: nil, path: path) }
        results += level.added.map { change(.added, old: nil, new: $0, path: path) }
        results += moved(level.pairs.filter { !reported.contains($0.old) }, among: level.pairs, path: path)
        return results
    }

    /// Every sibling at one level paired, key by key, then extensions whose headers changed paired across keys.
    func matchLevel(oldParent: Int?, newParent: Int?) -> Matched {
        let oldGroups = Dictionary(grouping: old.children[oldParent] ?? [], by: { key(old.symbols[$0]) })
        let newGroups = Dictionary(grouping: new.children[newParent] ?? [], by: { key(new.symbols[$0]) })
        var level = Matched()
        for key in Set(oldGroups.keys).union(newGroups.keys).sorted() {
            let matched = match(old: oldGroups[key] ?? [], new: newGroups[key] ?? [])
            level.pairs += matched.pairs
            level.removed += matched.removed
            level.added += matched.added
        }
        let removedExtensions = Dictionary(grouping: level.removed.filter { old.symbols[$0].kind == .extensionKind }, by: { old.symbols[$0].name })
        let addedExtensions = Dictionary(grouping: level.added.filter { new.symbols[$0].kind == .extensionKind }, by: { new.symbols[$0].name })
        for (name, removed) in removedExtensions.sorted(by: { $0.key < $1.key }) {
            guard removed.count == 1, let added = addedExtensions[name], added.count == 1 else { continue }
            level.pairs.append((removed[0], added[0]))
            level.removed.removeAll { $0 == removed[0] }
            level.added.removeAll { $0 == added[0] }
        }
        return level
    }

    func key(_ symbol: ParsedSymbol) -> DeclarationDiff.Key {
        DeclarationDiff.Key(name: symbol.name, kind: symbol.kind.rawValue, signature: symbol.kind == .extensionKind ? symbol.signature : "")
    }

    /// Pairs within one (name, kind) group, strongest evidence first; what is left unpaired on either side is a removal or an addition.
    func match(old oldOnes: [Int], new newOnes: [Int]) -> Matched {
        let isContainer = oldOnes.first.map { old.symbols[$0].kind.isContainer } ?? false
        let sameCondition: (Int, Int) -> Bool = { SourceText.same(old.symbols[$0].ifConfigCondition, new.symbols[$1].ifConfigCondition) }
        let sameSignature: (Int, Int) -> Bool = { SourceText.same(old.symbols[$0].signature, new.symbols[$1].signature) }
        let overlap: (Int, Int) -> Int = { old.memberKeys(of: $0).intersection(new.memberKeys(of: $1)).count }
        // Within a tier, the candidate the line diff kept this declaration's first line as wins a tie: of two
        // identical `var size = 0`, the one whose line did not change is the one that was there before.
        let kept: (Int, Int) -> Int = { oldIndex, newIndex in
            let line = old.symbols[oldIndex].line
            return line < aligned.count && aligned[line] == new.symbols[newIndex].line ? 1 : 0
        }
        let tiers: [(Int, Int) -> Int?] = if isContainer {
            [
                { sameSignature($0, $1) && sameCondition($0, $1) ? 2 * overlap($0, $1) + kept($0, $1) : nil },
                { sameSignature($0, $1) ? 2 * overlap($0, $1) + kept($0, $1) : nil },
                { overlap($0, $1) > 0 ? 2 * overlap($0, $1) + kept($0, $1) : nil },
                { sameCondition($0, $1) ? kept($0, $1) : nil },
                { kept($0, $1) },
            ]
        } else {
            [
                { SourceText.same(old.ownText($0), new.ownText($1)) && sameCondition($0, $1) ? kept($0, $1) : nil },
                { sameSignature($0, $1) && sameCondition($0, $1) ? kept($0, $1) : nil },
                { sameSignature($0, $1) ? kept($0, $1) : nil },
                { sameCondition($0, $1) ? kept($0, $1) : nil },
                { kept($0, $1) },
            ]
        }
        // Symbols are recorded in source order, so an index orders them even where several share a line and column
        // (`case a, b`, `let a = 1, b = 2`).
        var unpairedOld = oldOnes.sorted()
        var unpairedNew = newOnes.sorted()
        var pairs: [(old: Int, new: Int)] = []
        for score in tiers {
            var stillUnpaired: [Int] = []
            for oldIndex in unpairedOld {
                var best: (position: Int, score: Int)?
                for (position, newIndex) in unpairedNew.enumerated() {
                    guard let value = score(oldIndex, newIndex) else { continue }
                    if best == nil || value > (best?.score ?? 0) {
                        best = (position, value)
                    }
                }
                if let best {
                    pairs.append((oldIndex, unpairedNew.remove(at: best.position)))
                } else {
                    stillUnpaired.append(oldIndex)
                }
            }
            unpairedOld = stillUnpaired
        }
        return Matched(pairs: pairs, removed: unpairedOld, added: unpairedNew)
    }

    /// Pairs whose place among their siblings changed while nothing else was said about them — reported once, as moved.
    ///
    /// The order compared is of every pair at this level (`all`), in source order — by symbol index, which tells apart the elements of one `case a, b` or `let a = 1, b = 2` that share a line and column; only the `quiet` ones — not already reported as changed — get an entry of their own. Of two swapped siblings the order comparison names one; the other is named too when its lines are where the line diff shows the move, since that is what the reader's diff will show them.
    func moved(_ quiet: [(old: Int, new: Int)], among all: [(old: Int, new: Int)], path: Path) -> [DeclarationChange] {
        guard all.count > 1 else { return [] }
        let oldOrder = all.map(\.old).sorted()
        let newOrder = all.sorted { $0.new < $1.new }.map(\.old)
        let shifted = Set(newOrder.difference(from: oldOrder).insertions.map { step -> Int in
            switch step {
            case let .insert(_, element, _), let .remove(_, element, _): element
            }
        })
        guard !shifted.isEmpty else { return [] }
        let inHunk: ((old: Int, new: Int)) -> Bool = { pair in
            hunks?.contains { $0.meets(old: old.range(pair.old), new: new.range(pair.new)) } ?? false
        }
        let reordered: ((old: Int, new: Int)) -> Bool = { pair in
            all.contains { ($0.old < pair.old) != ($0.new < pair.new) }
        }
        return quiet.filter { shifted.contains($0.old) || (inHunk($0) && reordered($0)) }
            .sorted { $0.new < $1.new }
            .map { change(.moved, old: $0.old, new: $0.new, path: path) }
    }

    func change(_ kind: DeclarationChange.Kind, old oldIndex: Int?, new newIndex: Int?, path: Path, extent: Bool = false) -> DeclarationChange {
        let oldSymbol = oldIndex.map { old.symbols[$0] }
        let newSymbol = newIndex.map { new.symbols[$0] }
        let symbol = newSymbol ?? oldSymbol
        let isContainer = symbol?.kind.isContainer ?? false
        let wholeContainer = (kind == .added || kind == .removed) && isContainer
        let side = newIndex != nil && kind == .added ? new : old
        let index = kind == .added ? newIndex : oldIndex
        // A container matched on both sides answers only for its own lines — its header and its closing brace; its
        // members answer for themselves.
        let headerOnly = kind == .changed && isContainer
        let accessChanged = kind == .changed && oldSymbol?.accessLevel != newSymbol?.accessLevel
        let summary = DeclarationChange(
            kind: kind,
            containerPath: path.dotted,
            containerDisplay: path.display,
            name: symbol?.name ?? "",
            symbolKind: symbol?.kind ?? .function,
            oldSignature: oldSymbol?.signature,
            newSignature: newSymbol?.signature,
            oldRange: oldIndex.map { old.range($0) },
            newRange: newIndex.map { new.range($0) },
            oldCondition: oldSymbol?.ifConfigCondition,
            newCondition: newSymbol?.ifConfigCondition,
            oldAccess: accessChanged ? oldSymbol?.accessLevel : nil,
            newAccess: accessChanged ? newSymbol?.accessLevel : nil,
            signatureChanged: !SourceText.same(oldSymbol?.signature, newSymbol?.signature),
            textChanged: kind == .changed && !isContainer
                ? !SourceText.same(oldIndex.map { old.ownText($0) }, newIndex.map { new.ownText($0) })
                : false,
            memberCount: wholeContainer ? index.map { descendantCount(of: $0, in: side) } : nil,
            oldSpans: oldIndex.map { headerOnly ? ownLines(of: $0, in: old) : [old.range($0)] } ?? [],
            newSpans: newIndex.map { headerOnly ? ownLines(of: $0, in: new) : [new.range($0)] } ?? [],
            extentChanged: extent,
            movedIntact: kind == .moved && SourceText.same(oldIndex.map { old.body($0) }, newIndex.map { new.body($0) }),
            oldBody: nil,
            newBody: nil,
            nestedFunctions: wholeContainer ? index.map { nestedFunctions(of: $0, in: side) } ?? [] : []
        )
        // A container matched on both sides has no body of its own to show — its members are diffed separately — and
        // a move has nothing to show but where it went.
        guard kind != .moved, !headerOnly, keepsBody(summary) else { return summary }
        return summary.withBodies(old: oldIndex.map { old.body($0) }, new: newIndex.map { new.body($0) })
    }

    /// A container's own lines on one side — its header through its opening brace, and the line of its closing brace — less any line one of its members stands on, which is that member's to answer for.
    func ownLines(of index: Int, in side: Side) -> [DeclarationRange] {
        let header = side.headerRange(index)
        let members = (side.children[index] ?? []).map { side.range($0) }
        let own = (Array(header.line ... header.endLine) + [side.symbols[index].endLine]).filter { line in
            !members.contains { $0.line <= line && line <= $0.endLine }
        }
        return Set(own).sorted().map { DeclarationRange(line: $0, endLine: $0) }
    }

    /// Every declaration nested under a container, direct or not — what a wholly added/removed container's `memberCount` reports instead of listing them.
    func descendantCount(of parent: Int, in side: Side) -> Int {
        (side.children[parent] ?? []).reduce(0) { count, child in
            count + 1 + (side.symbols[child].kind.isContainer ? descendantCount(of: child, in: side) : 0)
        }
    }

    /// Every function nested anywhere under a container — a wholly added/removed container's individual test names, for the one section that needs them.
    func nestedFunctions(of parent: Int, in side: Side) -> [DeclarationChange.NestedFunction] {
        (side.children[parent] ?? []).flatMap { child -> [DeclarationChange.NestedFunction] in
            let symbol = side.symbols[child]
            var found = symbol.kind == .function ? [DeclarationChange.NestedFunction(name: symbol.name, signature: symbol.signature)] : []
            if symbol.kind.isContainer {
                found += nestedFunctions(of: child, in: side)
            }
            return found
        }
    }
}
