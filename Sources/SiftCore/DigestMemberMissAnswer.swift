//
// Copyright © Agulhas Labs
//

import Foundation

/// The answer for `Type.member` when `Type` resolves and holds no such member.
///
/// A miss on a member is a question about that type, so the answer is sized by the question: the type's own members closest to the name, a count for the rest, and a pointer to `where` for every same-named declaration elsewhere. Listing those instead made the answer grow with the repository, not with the miss.
struct DigestMemberMissAnswer {
    let renderer: DigestRenderer

    /// Own members listed before the tail says how many more there are.
    static let nearestCap = 6

    /// The answer, or `nil` when the last qualifier names no type this repository declares — the caller's wrong-path answer says that.
    func answer(baseName: String, qualifiers: [String], module: String?, elsewhere: Int, written: String) throws -> [String]? {
        guard let typeName = qualifiers.last else { return nil }
        // A name that is a *type* elsewhere is a nested-type miss, which the wrong-path answer names better than a member list.
        guard try renderer.store.typeDeclarations(named: baseName).isEmpty else { return nil }
        var owners: [SymbolRow] = []
        for row in try renderer.store.typeDeclarations(named: typeName, inModule: module) {
            let chain = try renderer.enclosingNames(of: row)
            if chain.suffix(qualifiers.count - 1) == qualifiers.dropLast()[...] {
                owners.append(row)
            }
        }
        guard !owners.isEmpty else { return nil }
        var members: [SymbolRow] = []
        for owner in owners {
            try members.append(contentsOf: renderer.store.children(of: owner.id))
            for row in try renderer.store.extensions(ofTypeNamed: typeName) where try renderer.owns(extension: row, primary: owner) {
                try members.append(contentsOf: renderer.store.children(of: row.id))
            }
        }
        let type = qualifiers.joined(separator: ".")
        let ranked = members
            .map { (row: $0, distance: Self.distance(from: baseName, to: QualifiedPath.baseName(of: $0.name))) }
            .sorted { ($0.distance, $0.row.name, $0.row.path, $0.row.line) < ($1.distance, $1.row.name, $1.row.path, $1.row.line) }
            .map(\.row)
        var lines = try renderer.absenceBanner()
        guard !ranked.isEmpty else {
            lines.append("\(DigestMiss.unresolvedPathPrefix)\(written) — \(type) declares no members")
            lines.append(elsewhereLine(baseName: baseName, elsewhere: elsewhere))
            return lines
        }
        lines.append("\(DigestMiss.unresolvedPathPrefix)\(written) — \(type) has no member \(baseName)\(DigestMiss.nearestMembersSuffix)")
        for row in ranked.prefix(Self.nearestCap) {
            lines.append("  \(row.name) — \(row.kind.rawValue) — \(row.path)\(row.rangeDescription)")
        }
        if ranked.count > Self.nearestCap {
            lines.append("  (+\(ranked.count - Self.nearestCap) more — digest \(type) lists them all)")
        }
        lines.append(elsewhereLine(baseName: baseName, elsewhere: elsewhere))
        return lines
    }

    private func elsewhereLine(baseName: String, elsewhere: Int) -> String {
        "\(baseName) is declared \(elsewhere) time\(elsewhere == 1 ? "" : "s") on other types — where \(baseName) lists them"
    }

    /// Edit distance between the two names, case-folded.
    static func distance(from wanted: String, to candidate: String) -> Int {
        let left = Array(wanted.lowercased())
        let right = Array(candidate.lowercased())
        if left.isEmpty {
            return right.count
        }
        if right.isEmpty {
            return left.count
        }
        var previous = Array(0 ... right.count)
        for (rowIndex, leftCharacter) in left.enumerated() {
            var current = [rowIndex + 1]
            for (columnIndex, rightCharacter) in right.enumerated() {
                let substitution = previous[columnIndex] + (leftCharacter == rightCharacter ? 0 : 1)
                current.append(min(substitution, previous[columnIndex + 1] + 1, current[columnIndex] + 1))
            }
            previous = current
        }
        return previous[right.count]
    }
}
